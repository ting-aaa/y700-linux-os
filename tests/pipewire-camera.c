/* Finite PipeWire video capture check. Frame data is never read or written. */
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>

struct sensor {
    const char *name;
    const char *node_name;
    const char *camera_path;
};

static const struct sensor sensors[] = {
    { "hi1339", "y700_camera_rear", "/base/soc@0/cci@ac15000/i2c-bus@0/camera@20" },
    { "s5k4h7", "y700_camera_front", "/base/soc@0/cci@ac15000/i2c-bus@1/camera@10" },
    { "sc202cs", "y700_camera_macro", "/base/soc@0/cci@ac16000/i2c-bus@0/camera@36" },
};

struct colour {
    uint32_t format;
    const char *name;
    unsigned bytes_per_two_pixels;
};

static const struct colour colours[] = {
    { SPA_VIDEO_FORMAT_RGBx, "RGBx", 8 }, { SPA_VIDEO_FORMAT_RGBA, "RGBA", 8 },
    { SPA_VIDEO_FORMAT_BGRx, "BGRx", 8 }, { SPA_VIDEO_FORMAT_BGRA, "BGRA", 8 },
    { SPA_VIDEO_FORMAT_RGB, "RGB", 6 }, { SPA_VIDEO_FORMAT_BGR, "BGR", 6 },
    { SPA_VIDEO_FORMAT_YUY2, "YUY2", 4 }, { SPA_VIDEO_FORMAT_UYVY, "UYVY", 4 },
    { SPA_VIDEO_FORMAT_NV12, "NV12", 3 }, { SPA_VIDEO_FORMAT_I420, "I420", 3 },
};

struct probe {
    struct pw_main_loop *main;
    struct pw_core *core;
    struct pw_registry *registry;
    struct pw_stream *stream;
    struct spa_hook stream_listener;
    struct spa_list sources;
    const struct sensor *sensor;
    const char *serial;
    char observer_node[64];
    const struct colour *colour;
    struct spa_rectangle size;
    uint32_t source_id;
    uint32_t link_id;
    unsigned frames, want, rejected;
    uint64_t minimum_frame, bytes;
    int sync, result;
    bool inspecting, finished;
};

struct source {
    struct spa_list link;
    struct pw_node *node;
    struct spa_hook listener;
    const struct sensor *sensor;
    uint32_t id;
    char *serial;
    bool gone;
};

static uint64_t number(const char *text)
{
    char *end;
    if (!*text || strspn(text, "0123456789") != strlen(text))
        return 0;
    errno = 0;
    uint64_t value = strtoull(text, &end, 10);
    return errno || *end ? 0 : value;
}

static void finish(struct probe *probe, bool ok, const char *reason)
{
    if (probe->finished)
        return;
    probe->finished = true;
    probe->result = ok ? 0 : 1;
    if (!ok)
        fprintf(stderr, "CAMERA_FAIL accepted=%u requested=%u rejected=%u reason=%s\n",
                probe->frames, probe->want, probe->rejected, reason);
    pw_main_loop_quit(probe->main);
}

static const struct sensor *board_sensor(const struct spa_dict *props)
{
    const char *class = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS);
    const char *path = spa_dict_lookup(props, "api.libcamera.path");
    const char *name = spa_dict_lookup(props, PW_KEY_NODE_NAME);
    const struct sensor *alias = NULL;

    if (class && strcmp(class, "Video/Source") != 0)
        return NULL;
    for (size_t i = 0; name && i < SPA_N_ELEMENTS(sensors); i++)
        if (strcmp(name, sensors[i].node_name) == 0)
            alias = &sensors[i];
    if (!path)
        return alias;
    for (size_t i = 0; i < SPA_N_ELEMENTS(sensors); i++)
        if (strcmp(path, sensors[i].camera_path) == 0)
            return !alias || alias == &sensors[i] ? &sensors[i] : NULL;
    return NULL;
}

static uint64_t frame_bytes(struct spa_buffer *buffer)
{
    const struct spa_meta_header *header = spa_buffer_find_meta_data(buffer, SPA_META_Header, sizeof(*header));
    uint64_t bytes = 0;

    if (header && (header->flags & (SPA_META_HEADER_FLAG_CORRUPTED | SPA_META_HEADER_FLAG_GAP |
                                    SPA_META_HEADER_FLAG_HEADER)))
        return 0;
    for (uint32_t i = 0; i < buffer->n_datas; i++) {
        const struct spa_data *data = &buffer->datas[i];
        const struct spa_chunk *chunk = data->chunk;
        if (!chunk || !chunk->size || (chunk->flags & (SPA_CHUNK_FLAG_CORRUPTED | SPA_CHUNK_FLAG_EMPTY)) ||
            chunk->offset >= data->maxsize || chunk->size > data->maxsize - chunk->offset)
            return 0;
        if (data->type == SPA_DATA_MemPtr ? !data->data :
            ((data->type != SPA_DATA_MemFd && data->type != SPA_DATA_DmaBuf) || data->fd < 0))
            return 0;
        bytes += chunk->size;
    }
    return bytes;
}

static void process(void *data)
{
    struct probe *probe = data;
    struct pw_buffer *buffer;

    while (!probe->finished && (buffer = pw_stream_dequeue_buffer(probe->stream))) {
        uint64_t bytes = frame_bytes(buffer->buffer);
        pw_stream_queue_buffer(probe->stream, buffer);
        if (!probe->colour || (probe->link_id == PW_ID_ANY && !probe->observer_node[0]))
            continue;
        if (bytes < probe->minimum_frame) {
            probe->rejected++;
            continue;
        }
        probe->bytes += bytes;
        if (++probe->frames == probe->want) {
            printf("%s sensor=%s serial=%s format=%s size=%ux%u frames=%u bytes=%" PRIu64 " rejected=%u",
                   probe->observer_node[0] ? "CAMERA_SAMPLE" : "CAMERA_OK",
                   probe->sensor->name, probe->serial, probe->colour->name, probe->size.width, probe->size.height,
                   probe->frames, probe->bytes, probe->rejected);
            if (probe->observer_node[0])
                printf(" stream=%s target_node=%u", probe->observer_node, probe->source_id);
            putchar('\n');
            finish(probe, true, NULL);
        }
    }
}

static void format_changed(void *data, uint32_t id, const struct spa_pod *param)
{
    struct probe *probe = data;
    struct spa_video_info_raw info = {0};
    uint32_t type, subtype;

    if (id != SPA_PARAM_Format)
        return;
    if (!param && !probe->colour)
        return;
    if (!param || spa_format_parse(param, &type, &subtype) < 0 ||
        type != SPA_MEDIA_TYPE_video || subtype != SPA_MEDIA_SUBTYPE_raw ||
        spa_format_video_raw_parse(param, &info) < 0 || info.modifier ||
        info.size.width != probe->size.width || info.size.height != probe->size.height) {
        finish(probe, false, "missing or incompatible linear raw video format");
        return;
    }
    if (probe->colour && probe->colour->format != info.format) {
        finish(probe, false, "format changed during capture");
        return;
    }
    for (size_t i = 0; i < SPA_N_ELEMENTS(colours); i++) {
        if (info.format == colours[i].format) {
            probe->colour = &colours[i];
            probe->minimum_frame = (uint64_t)info.size.width * info.size.height * colours[i].bytes_per_two_pixels / 2;
            return;
        }
    }
    finish(probe, false, "unsupported colour format");
}

static void stream_state(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error)
{
    (void)error;
    if (state == PW_STREAM_STATE_ERROR || (state == PW_STREAM_STATE_UNCONNECTED && old != state))
        finish(data, false, "PipeWire stream stopped before the sample completed");
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = stream_state,
    .param_changed = format_changed,
    .process = process,
};

static bool node_property_is(const struct spa_dict *props, const char *key, uint32_t id)
{
    const char *value = spa_dict_lookup(props, key);
    char expected[12];
    snprintf(expected, sizeof(expected), "%u", id);
    return value && strcmp(value, expected) == 0;
}

static void source_info(void *data, const struct pw_node_info *info)
{
    struct source *source = data;
    if (info->change_mask & PW_NODE_CHANGE_MASK_PROPS && info->props)
        source->sensor = board_sensor(info->props);
}

static const struct pw_node_events node_events = { PW_VERSION_NODE_EVENTS, .info = source_info };

static void global(void *data, uint32_t id, uint32_t permissions, const char *type,
                   uint32_t version, const struct spa_dict *props)
{
    struct probe *probe = data;
    (void)permissions;
    if (!props || probe->finished)
        return;

    if (strcmp(type, PW_TYPE_INTERFACE_Node) == 0) {
        const char *class = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS);
        const char *serial = spa_dict_lookup(props, PW_KEY_OBJECT_SERIAL);
        struct source *source;
        const struct sensor *sensor;
        if (probe->inspecting || !class || strcmp(class, "Video/Source") != 0 || !serial || !number(serial) ||
            (probe->serial && strcmp(serial, probe->serial) != 0))
            return;
        sensor = board_sensor(props);
        /* A permission update can announce a registry global more than once. */
        spa_list_for_each(source, &probe->sources, link) {
            if (source->id != id || source->gone)
                continue;
            if (strcmp(source->serial, serial) == 0) {
                if (!source->sensor)
                    source->sensor = sensor;
                return;
            }
            source->gone = true;
        }
        source = calloc(1, sizeof(*source));
        if (!source || !(source->serial = strdup(serial))) {
            free(source);
            finish(probe, false, "cannot retain video source identity");
            return;
        }
        source->id = id;
        source->sensor = sensor;
        spa_list_append(&probe->sources, &source->link);
        source->node = pw_registry_bind(probe->registry, id, type, SPA_MIN(version, PW_VERSION_NODE), 0);
        if (source->node)
            pw_node_add_listener(source->node, &source->listener, &node_events, source);
    } else if (strcmp(type, PW_TYPE_INTERFACE_Link) == 0 && probe->stream &&
               node_property_is(props, PW_KEY_LINK_INPUT_NODE, pw_stream_get_node_id(probe->stream))) {
        if (!node_property_is(props, PW_KEY_LINK_OUTPUT_NODE, probe->source_id))
            finish(probe, false, "link resolved to a different video source");
        else
            probe->link_id = id;
    }
}

static void global_remove(void *data, uint32_t id)
{
    struct probe *probe = data;
    struct source *source;
    spa_list_for_each(source, &probe->sources, link)
        if (id == source->id)
            source->gone = true;
    if (id == probe->link_id || id == probe->source_id)
        finish(probe, false, "selected video source or link disappeared");
}

static const struct pw_registry_events registry_events = {
    PW_VERSION_REGISTRY_EVENTS,
    .global = global,
    .global_remove = global_remove,
};

static void discovery_done(void *data, uint32_t id, int seq)
{
    struct probe *probe = data;
    uint8_t storage[512];
    struct spa_pod_builder builder = SPA_POD_BUILDER_INIT(storage, sizeof(storage));
    const struct spa_pod *format;
    struct source *source;
    bool listed = false;

    if (id != PW_ID_CORE || seq != probe->sync || probe->finished)
        return;
    if (!probe->inspecting) {
        probe->inspecting = true;
        probe->sync = pw_core_sync(probe->core, PW_ID_CORE, seq);
        if (probe->sync < 0)
            finish(probe, false, "cannot inspect video source properties");
        return;
    }
    spa_list_for_each(source, &probe->sources, link) {
        if (source->gone || !source->sensor)
            continue;
        if (!probe->sensor) {
            printf("sensor=%s serial=%s node=%u\n", source->sensor->name, source->serial, source->id);
            listed = true;
        } else if (source->sensor == probe->sensor) {
            probe->source_id = source->id;
        }
    }
    if (!probe->sensor) {
        finish(probe, listed, "no board video sources found");
        return;
    }
    if (probe->source_id == PW_ID_ANY) {
        finish(probe, false, "serial and sensor identity do not match an available video source");
        return;
    }
    probe->stream = pw_stream_new(probe->core, "Y700 camera frame counter",
            pw_properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY, "Capture",
                PW_KEY_MEDIA_ROLE, "Camera", PW_KEY_TARGET_OBJECT, probe->serial,
                PW_KEY_NODE_NAME, probe->observer_node[0] ? probe->observer_node : "y700-camera-probe",
                PW_KEY_NODE_DONT_RECONNECT, "true", "node.dont-fallback", "true", NULL));
    if (!probe->stream) {
        finish(probe, false, "could not create capture stream");
        return;
    }
    pw_stream_add_listener(probe->stream, &probe->stream_listener, &stream_events, probe);
    format = spa_pod_builder_add_object(&builder, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
        SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
        SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
        SPA_FORMAT_VIDEO_format, SPA_POD_CHOICE_ENUM_Id(11, SPA_VIDEO_FORMAT_RGBx, SPA_VIDEO_FORMAT_RGBx,
            SPA_VIDEO_FORMAT_RGBA, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRA, SPA_VIDEO_FORMAT_RGB,
            SPA_VIDEO_FORMAT_BGR, SPA_VIDEO_FORMAT_YUY2, SPA_VIDEO_FORMAT_UYVY,
            SPA_VIDEO_FORMAT_NV12, SPA_VIDEO_FORMAT_I420),
        SPA_FORMAT_VIDEO_size, SPA_POD_Rectangle(&probe->size));
    if (!format || pw_stream_connect(probe->stream, PW_DIRECTION_INPUT, PW_ID_ANY,
                PW_STREAM_FLAG_AUTOCONNECT, &format, 1) < 0)
        finish(probe, false, "could not connect capture stream");
}

static void core_error(void *data, uint32_t id, int seq, int res, const char *message)
{
    (void)seq;
    (void)message;
    if (id == PW_ID_CORE && res < 0)
        finish(data, false, "PipeWire connection error");
}

static const struct pw_core_events core_events = {
    PW_VERSION_CORE_EVENTS,
    .done = discovery_done,
    .error = core_error,
};

static void timeout(void *data, uint64_t expirations)
{
    struct probe *probe = data;
    (void)expirations;
    finish(probe, false, probe->link_id == PW_ID_ANY && !probe->observer_node[0] ?
            "timed out before the selected link could be verified" :
            "timed out before the requested valid frames arrived");
}

int main(int argc, char **argv)
{
    struct probe probe = {
        .size = {640, 480}, .source_id = PW_ID_ANY, .link_id = PW_ID_ANY, .result = 1,
    };
    struct pw_context *context;
    struct pw_loop *loop;
    struct spa_source *timer;
    struct spa_hook core_listener, registry_listener;
    struct source *source, *next;
    const char *descriptor = getenv("Y700_CAMERA_PORTAL_FD");
    int fd = -1;
    uint64_t seconds = 15;

    if (argc > 1 && strcmp(argv[1], "--fd") == 0) {
        if (argc < 3 || (descriptor && strcmp(descriptor, argv[2]) != 0)) {
            fputs("CAMERA_FAIL reason=missing or conflicting portal descriptor\n", stderr);
            return 2;
        }
        descriptor = argv[2];
        argc -= 2;
        argv += 2;
    }
    if (descriptor) {
        uint64_t value = number(descriptor);
        struct sockaddr_storage peer;
        socklen_t size = sizeof(peer);
        socklen_t option_size = sizeof(int);
        int socket_type;
        if (value < 3 || value > INT_MAX || getpeername((int)value, (struct sockaddr *)&peer, &size) < 0 ||
            peer.ss_family != AF_UNIX || getsockopt((int)value, SOL_SOCKET, SO_TYPE, &socket_type, &option_size) < 0 ||
            socket_type != SOCK_STREAM) {
            fputs("CAMERA_FAIL reason=portal descriptor is not a connected Unix stream socket\n", stderr);
            return 2;
        }
        fd = (int)value;
    }
    if (argc > 1 && strcmp(argv[1], "--observer") == 0) {
        const char *token = argc > 2 ? argv[2] : "";
        const char *characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_";
        if (fd < 0 || argc != 7 || !*token || strlen(token) > 32 || strspn(token, characters) != strlen(token)) {
            fputs("CAMERA_FAIL reason=observer mode requires a portal descriptor, a safe token and capture arguments\n",
                  stderr);
            return 2;
        }
        snprintf(probe.observer_node, sizeof(probe.observer_node), "y700.camera.probe.%s", token);
        argc -= 2;
        argv += 2;
    }
    if (argc != 2 || strcmp(argv[1], "--list") != 0) {
        uint64_t frames = argc == 5 ? number(argv[3]) : 0;
        seconds = argc == 5 ? number(argv[4]) : 0;
        if (argc == 5) {
            for (size_t i = 0; i < SPA_N_ELEMENTS(sensors); i++)
                if (strcmp(argv[1], sensors[i].name) == 0)
                    probe.sensor = &sensors[i];
        }
        if (!probe.sensor || !number(argv[2]) || !frames || frames > 600 || !seconds || seconds > 120) {
            fputs("Usage: pw-camera-probe [--fd FD] (--list | [--observer TOKEN] SENSOR SERIAL FRAMES SECONDS)\n"
                  "Sensors: hi1339, s5k4h7, sc202cs. Captures linear 640x480 raw colour.\n", stderr);
            return 2;
        }
        probe.serial = argv[2];
        probe.want = frames;
    }

    spa_list_init(&probe.sources);
    pw_init(NULL, NULL);
    probe.main = pw_main_loop_new(NULL);
    if (!probe.main) {
        fputs("CAMERA_FAIL reason=cannot create PipeWire loop\n", stderr);
        pw_deinit();
        return 1;
    }
    loop = pw_main_loop_get_loop(probe.main);
    context = pw_context_new(loop, NULL, 0);
    if (context)
        probe.core = fd < 0 ? pw_context_connect(context, NULL, 0) : pw_context_connect_fd(context, fd, NULL, 0);
    probe.registry = probe.core ? pw_core_get_registry(probe.core, PW_VERSION_REGISTRY, 0) : NULL;
    timer = pw_loop_add_timer(loop, timeout, &probe);
    struct timespec deadline = { .tv_sec = seconds };
    if (probe.registry && timer && pw_loop_update_timer(loop, timer, &deadline, NULL, false) >= 0) {
        pw_core_add_listener(probe.core, &core_listener, &core_events, &probe);
        pw_registry_add_listener(probe.registry, &registry_listener, &registry_events, &probe);
        probe.sync = pw_core_sync(probe.core, PW_ID_CORE, 0);
        if (probe.sync >= 0)
            pw_main_loop_run(probe.main);
    }
    if (!probe.finished)
        fputs("CAMERA_FAIL reason=cannot initialize PipeWire discovery\n", stderr);
    if (timer)
        pw_loop_destroy_source(loop, timer);
    if (probe.stream)
        pw_stream_destroy(probe.stream);
    spa_list_for_each_safe(source, next, &probe.sources, link) {
        if (source->node)
            pw_proxy_destroy((struct pw_proxy *)source->node);
        spa_list_remove(&source->link);
        free(source->serial);
        free(source);
    }
    if (probe.registry)
        pw_proxy_destroy((struct pw_proxy *)probe.registry);
    if (probe.core)
        pw_core_disconnect(probe.core);
    if (context)
        pw_context_destroy(context);
    pw_main_loop_destroy(probe.main);
    pw_deinit();
    return probe.result;
}
