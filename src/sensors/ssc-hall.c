/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <libssc.h>
#include <stdio.h>
#include <unistd.h>

/* Qualcomm sensinghub v2.2.2, apis/proto/sns_hall.proto. */
enum {
    HALL_EVENT = 770,
    HALL_STATE_TAG = 1 << 3,
    HALL_STATUS_TAG = 2 << 3,
    HALL_FAR = 0,
    HALL_NEAR = 1,
    HALL_ACCURACY_HIGH = 3,
};

struct reader {
    GMainLoop *loop;
    SSCSensor *sensor;
    GObject *client;
    guint64 uid_high, uid_low;
    guint deadline_source, report_handler;
    guint required, samples, rejected;
    gboolean discover_only, opened, closing;
    int status;
};

/* The valid enum values fit in one byte. Enforce exactly two required
 * varint fields, in either order, and ignore unreliable samples. */
static gboolean decode_hall(GArray *data, guint8 *state)
{
    if (!data || data->len != 4 || g_array_get_element_size(data) != 1)
        return FALSE;

    const guint8 *payload = (const guint8 *)data->data;
    const guint state_index = payload[0] == HALL_STATE_TAG ? 0 : 2;
    const guint status_index = 2 - state_index;
    if (payload[state_index] != HALL_STATE_TAG || payload[status_index] != HALL_STATUS_TAG ||
        payload[state_index + 1] > HALL_NEAR || payload[status_index + 1] != HALL_ACCURACY_HIGH)
        return FALSE;

    *state = payload[state_index + 1];
    return TRUE;
}

static void finish(struct reader *reader, int status, const char *reason)
{
    reader->status = status;
    if (reason)
        g_printerr("ssc-hall: %s\n", reason);
    g_main_loop_quit(reader->loop);
}

static gboolean close_timeout(gpointer data)
{
    struct reader *reader = data;
    reader->deadline_source = 0;
    finish(reader, 5, "closing the Hall subscription timed out");
    return G_SOURCE_REMOVE;
}

static void closed(GObject *object, GAsyncResult *result, gpointer data)
{
    struct reader *reader = data;
    g_autoptr(GError) error = NULL;
    if (!ssc_sensor_close_finish(SSC_SENSOR(object), result, &error)) {
        finish(reader, 5, error->message);
    } else if (reader->samples == reader->required) {
        finish(reader, 0, NULL);
    } else {
        finish(reader, 4, "fewer valid Hall events than requested");
    }
}

static void close_subscription(struct reader *reader)
{
    reader->closing = TRUE;
    g_clear_handle_id(&reader->deadline_source, g_source_remove);
    reader->deadline_source = g_timeout_add(2500, close_timeout, reader);
    ssc_sensor_close(reader->sensor, NULL, closed, reader);
}

static gboolean deadline(gpointer data)
{
    struct reader *reader = data;
    reader->deadline_source = 0;
    if (reader->opened) {
        close_subscription(reader);
    } else {
        finish(reader, reader->sensor ? 5 : 3,
               reader->sensor ? "opening the Hall subscription timed out" : "Hall discovery timed out");
    }
    return G_SOURCE_REMOVE;
}

static void report(GObject *client, guint id, guint64 high, guint64 low, GArray *payload, gpointer data)
{
    struct reader *reader = data;
    guint8 state;
    (void)client;

    if (reader->closing || reader->samples == reader->required || id != HALL_EVENT ||
        high != reader->uid_high || low != reader->uid_low)
        return;

    if (!decode_hall(payload, &state)) {
        reader->rejected++;
        return;
    }

    g_print("Hall sensor measurement: %s\n", state == HALL_FAR ? "FAR" : "NEAR");
    reader->samples++;
    if (reader->opened && reader->samples == reader->required)
        close_subscription(reader);
}

static void opened(GObject *object, GAsyncResult *result, gpointer data)
{
    struct reader *reader = data;
    g_autoptr(GError) error = NULL;
    if (!ssc_sensor_open_finish(SSC_SENSOR(object), result, &error)) {
        finish(reader, 5, error->message);
        return;
    }

    reader->opened = TRUE;
    if (reader->samples == reader->required)
        close_subscription(reader);
}

static gboolean supports_raw_reports(GObject *client)
{
    if (!client)
        return FALSE;

    /* libssc 0.4.4 keeps the raw client signal internal. Check its type
     * before connecting so an incompatible libssc fails cleanly. */
    GSignalQuery query = {0};
    g_signal_query(g_signal_lookup("report", G_OBJECT_TYPE(client)), &query);
    return query.signal_id && query.return_type == G_TYPE_NONE && query.n_params == 4 &&
           query.param_types[0] == G_TYPE_UINT && query.param_types[1] == G_TYPE_UINT64 &&
           query.param_types[2] == G_TYPE_UINT64 && query.param_types[3] == G_TYPE_ARRAY;
}

static void discovered(GObject *object, GAsyncResult *result, gpointer data)
{
    struct reader *reader = data;
    g_autoptr(GError) error = NULL;
    (void)object;

    reader->sensor = ssc_sensor_new_finish(result, &error);
    if (!reader->sensor) {
        finish(reader, 3, error ? error->message : "Hall sensor unavailable");
        return;
    }
    /* The base opens the advertised stream. In libssc 0.4.4 the
     * stream-type property declares a string but its getter writes an int. */
    g_print("Hall sensor discovered: hall\n");
    if (reader->discover_only) {
        finish(reader, 0, NULL);
        return;
    }

    g_object_get(reader->sensor, SSC_SENSOR_CLIENT, &reader->client,
                 SSC_SENSOR_UID_HIGH, &reader->uid_high, SSC_SENSOR_UID_LOW, &reader->uid_low, NULL);
    if (!supports_raw_reports(reader->client)) {
        finish(reader, 5, "libssc raw report interface differs from the pinned interface");
        return;
    }
    reader->report_handler = g_signal_connect(reader->client, "report", G_CALLBACK(report), reader);
    ssc_sensor_open(reader->sensor, NULL, opened, reader);
}

int main(int argc, char **argv)
{
    struct reader reader = {.status = 5};
    gint count = 2, seconds = 20;
    GOptionEntry options[] = {
        {"discover", 0, 0, G_OPTION_ARG_NONE, &reader.discover_only, "Discover the SSC Hall sensor", NULL},
        {"count", 0, 0, G_OPTION_ARG_INT, &count, "Number of valid Hall events to capture", "COUNT"},
        {"timeout", 0, 0, G_OPTION_ARG_INT, &seconds, "Deadline for discovery and events", "SECONDS"},
        {0},
    };
    g_autoptr(GOptionContext) context = g_option_context_new(NULL);
    g_autoptr(GError) error = NULL;
    g_option_context_add_main_entries(context, options, NULL);
    if (!g_option_context_parse(context, &argc, &argv, &error) || argc != 1 ||
        count < 1 || count > 100 || seconds < 1 || seconds > 120) {
        g_printerr("ssc-hall: %s\n", error ? error->message : "set count to 1–100 and timeout to 1–120 seconds");
        return 2;
    }

    setvbuf(stdout, NULL, _IOLBF, 0);
    alarm(seconds + 4);
    reader.required = count;
    reader.loop = g_main_loop_new(NULL, FALSE);
    reader.deadline_source = g_timeout_add_seconds(seconds, deadline, &reader);
    ssc_sensor_new("hall", NULL, discovered, &reader);
    g_main_loop_run(reader.loop);
    g_clear_handle_id(&reader.deadline_source, g_source_remove);
    if (reader.report_handler)
        g_signal_handler_disconnect(reader.client, reader.report_handler);
    if (!reader.discover_only)
        g_print("Hall result: accepted=%u rejected=%u\n", reader.samples, reader.rejected);
    g_clear_object(&reader.sensor);
    g_clear_object(&reader.client);
    g_main_loop_unref(reader.loop);
    return reader.status;
}
