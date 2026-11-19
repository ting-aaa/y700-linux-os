/* Collect a bounded set of measurements from one libssc sensor. */
#include <libssc.h>
#include <libssc-sensor-magnetometer.h>

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

struct sensor_spec {
    const char *name;
    const char *data_type;
    const char *unit;
    GType (*type)(void);
    void (*open)(SSCSensor *, GAsyncReadyCallback, gpointer);
    gboolean (*open_finish)(SSCSensor *, GAsyncResult *, GError **);
    void (*close)(SSCSensor *, GAsyncReadyCallback, gpointer);
    gboolean (*close_finish)(SSCSensor *, GAsyncResult *, GError **);
    unsigned dimensions;
    unsigned default_count;
};

/* A typed open is required to attach each sensor's measurement decoder. */
#define SENSOR_ADAPTERS(name, Type)                                            \
    static void name##_open(SSCSensor *s, GAsyncReadyCallback cb, gpointer p)   \
    { ssc_sensor_##name##_open((SSCSensor##Type *)s, NULL, cb, p); }             \
    static gboolean name##_open_finish(SSCSensor *s, GAsyncResult *r, GError **e) \
    { return ssc_sensor_##name##_open_finish((SSCSensor##Type *)s, r, e); }     \
    static void name##_close(SSCSensor *s, GAsyncReadyCallback cb, gpointer p)  \
    { ssc_sensor_##name##_close((SSCSensor##Type *)s, NULL, cb, p); }            \
    static gboolean name##_close_finish(SSCSensor *s, GAsyncResult *r, GError **e) \
    { return ssc_sensor_##name##_close_finish((SSCSensor##Type *)s, r, e); }

SENSOR_ADAPTERS(accelerometer, Accelerometer)
SENSOR_ADAPTERS(gyroscope, Gyroscope)
SENSOR_ADAPTERS(magnetometer, Magnetometer)
SENSOR_ADAPTERS(light, Light)
SENSOR_ADAPTERS(proximity, Proximity)
SENSOR_ADAPTERS(compass, Compass)

#define SENSOR(name, type, unit, axes, count)                                  \
    {#name, type, unit, ssc_sensor_##name##_get_type, name##_open,              \
     name##_open_finish, name##_close, name##_close_finish, axes, count}

static const struct sensor_spec sensors[] = {
    SENSOR(accelerometer, "accel", "m/s^2", 3, 5),
    SENSOR(gyroscope, "gyro", "ssc_gyro_axis", 3, 5),
    SENSOR(magnetometer, "mag", "uT", 3, 5),
    SENSOR(light, "ambient_light", "lux", 1, 1),
    SENSOR(proximity, "proximity", "near_boolean", 1, 1),
    SENSOR(compass, "rotv", "deg", 1, 5),
};

struct probe {
    const struct sensor_spec *spec;
    GMainLoop *loop;
    SSCSensor *sensor;
    gint64 deadline_us;
    guint deadline_source;
    guint close_source;
    unsigned requested;
    unsigned accepted;
    unsigned rejected;
    const char *availability;
    const char *status;
    gboolean subscribed;
    gboolean closing;
    gboolean closed;
    int result;
};

static void finish(struct probe *probe, const char *status, int result)
{
    probe->status = status;
    probe->result = result;
    g_main_loop_quit(probe->loop);
}

static void report_error(const struct probe *probe, const char *phase,
                         const GError *error)
{
    if (error)
        g_printerr("%s %s: %s\n", probe->spec->name, phase, error->message);
}

static gboolean close_timeout(gpointer data)
{
    struct probe *probe = data;
    probe->close_source = 0;
    finish(probe, "close-timeout", 5);
    return G_SOURCE_REMOVE;
}

static void close_ready(GObject *object, GAsyncResult *result, gpointer data)
{
    struct probe *probe = data;
    g_autoptr(GError) error = NULL;

    if (!probe->spec->close_finish(SSC_SENSOR(object), result, &error)) {
        report_error(probe, "close", error);
        finish(probe, "close-error", 5);
        return;
    }
    probe->closed = TRUE;
    if (probe->accepted == probe->requested)
        finish(probe, "ok", 0);
    else
        finish(probe, probe->accepted ? "insufficient-data" : "no-data", 4);
}

static void begin_close(struct probe *probe)
{
    probe->closing = TRUE;
    g_clear_handle_id(&probe->deadline_source, g_source_remove);
    probe->close_source = g_timeout_add(2500, close_timeout, probe);
    probe->spec->close(probe->sensor, close_ready, probe);
}

static gboolean deadline_reached(gpointer data)
{
    struct probe *probe = data;
    probe->deadline_source = 0;
    if (probe->subscribed)
        begin_close(probe);
    else if (!probe->sensor)
        finish(probe, "discovery-timeout", 3);
    else if (probe->accepted)
        finish(probe, "open-timeout", 5);
    else
        finish(probe, "no-data", 4);
    return G_SOURCE_REMOVE;
}

static void measure(struct probe *probe, gfloat x, gfloat y, gfloat z)
{
    const gint64 now = g_get_monotonic_time();
    const char *type = probe->spec->data_type;
    char values[3][G_ASCII_DTOSTR_BUF_SIZE];

    if (probe->closing || probe->accepted == probe->requested || now >= probe->deadline_us)
        return;
    if (!isfinite(x) || !isfinite(y) || !isfinite(z) ||
        (strcmp(type, "ambient_light") == 0 && x < 0) ||
        (strcmp(type, "rotv") == 0 && (x < 0 || x > 360))) {
        probe->rejected++;
        return;
    }

    probe->accepted++;
    g_ascii_formatd(values[0], sizeof values[0], "%.9g", x);
    g_print("SSC_SAMPLE sensor=%s sequence=%u host_monotonic_us=%" G_GINT64_FORMAT
            " unit=%s", probe->spec->name, probe->accepted, now, probe->spec->unit);
    if (probe->spec->dimensions == 3) {
        g_ascii_formatd(values[1], sizeof values[1], "%.9g", y);
        g_ascii_formatd(values[2], sizeof values[2], "%.9g", z);
        g_print(" x=%s y=%s z=%s\n", values[0], values[1], values[2]);
    } else {
        g_print(" value=%s\n", values[0]);
    }

    if (probe->subscribed && probe->accepted == probe->requested)
        begin_close(probe);
}

static void measurement_xyz(GObject *sensor, gfloat x, gfloat y, gfloat z, gpointer data)
{
    (void)sensor;
    measure(data, x, y, z);
}

static void measurement_scalar(GObject *sensor, gfloat value, gpointer data)
{
    (void)sensor;
    measure(data, value, 0, 0);
}

static void measurement_proximity(GObject *sensor, gboolean near, gpointer data)
{
    (void)sensor;
    measure(data, near ? 1 : 0, 0, 0);
}

static void open_ready(GObject *object, GAsyncResult *result, gpointer data)
{
    struct probe *probe = data;
    g_autoptr(GError) error = NULL;

    if (!probe->spec->open_finish(SSC_SENSOR(object), result, &error)) {
        if (g_error_matches(error, ssc_sensor_error_quark(), SSC_SENSOR_ERROR_UNAVAILABLE)) {
            probe->availability = "no";
            finish(probe, "unavailable", 3);
            return;
        }
        report_error(probe, "open", error);
        finish(probe, "open-error", 5);
        return;
    }
    probe->availability = "yes";
    probe->subscribed = TRUE;
    if (probe->accepted == probe->requested)
        begin_close(probe);
}

static void discovery_ready(GObject *object, GAsyncResult *result, gpointer data)
{
    struct probe *probe = data;
    g_autoptr(GError) error = NULL;
    GObject *sensor = g_async_initable_new_finish(G_ASYNC_INITABLE(object), result, &error);

    if (error && !g_error_matches(error, ssc_sensor_error_quark(), SSC_SENSOR_ERROR_UNAVAILABLE)) {
        report_error(probe, "discovery", error);
        finish(probe, "discovery-error", 3);
        return;
    }
    if (!sensor) {
        probe->availability = "no";
        g_print("SSC_DISCOVERY sensor=%s data_type=%s status=unavailable\n",
                probe->spec->name, probe->spec->data_type);
        finish(probe, "unavailable", 3);
        return;
    }

    /* libssc 0.4.4 declares its Boolean getter as a string property.
     * Use successful typed initialization for discovery and open for availability. */
    probe->sensor = SSC_SENSOR(sensor);
    g_print("SSC_DISCOVERY sensor=%s data_type=%s status=found\n",
            probe->spec->name, probe->spec->data_type);
    GCallback measurement = G_CALLBACK(measurement_scalar);
    if (probe->spec->dimensions == 3)
        measurement = G_CALLBACK(measurement_xyz);
    else if (strcmp(probe->spec->data_type, "proximity") == 0)
        measurement = G_CALLBACK(measurement_proximity);
    g_signal_connect(sensor, "measurement", measurement, probe);
    probe->spec->open(probe->sensor, open_ready, probe);
}

static unsigned bounded_number(const char *text, unsigned limit)
{
    if (!*text || strspn(text, "0123456789") != strlen(text))
        return 0;
    errno = 0;
    const guint64 value = g_ascii_strtoull(text, NULL, 10);
    return errno || value > limit ? 0 : (unsigned)value;
}

int main(int argc, char **argv)
{
    struct probe probe = {.availability = "unknown"};
    unsigned seconds = 12;

    if (argc >= 2 && argc <= 4) {
        for (unsigned i = 0; i < G_N_ELEMENTS(sensors); i++) {
            if (strcmp(argv[1], sensors[i].name) == 0)
                probe.spec = &sensors[i];
        }
        if (probe.spec)
            probe.requested = argc >= 3 ? bounded_number(argv[2], 100) : probe.spec->default_count;
        if (argc == 4)
            seconds = bounded_number(argv[3], 120);
    }
    if (!probe.spec || !probe.requested || !seconds) {
        fprintf(stderr, "Usage: %s accelerometer|gyroscope|magnetometer|light|proximity|compass "
                        "[COUNT 1..100] [DEADLINE_SECONDS 1..120]\n", argv[0]);
        return 2;
    }

    setvbuf(stdout, NULL, _IOLBF, 0);
    alarm(seconds + 4); /* Hard bound even if a transport callback blocks GLib. */
    probe.loop = g_main_loop_new(NULL, FALSE);
    probe.deadline_us = g_get_monotonic_time() + (gint64)seconds * G_USEC_PER_SEC;
    probe.deadline_source = g_timeout_add(seconds * 1000, deadline_reached, &probe);
    g_async_initable_new_async(probe.spec->type(), G_PRIORITY_DEFAULT, NULL, discovery_ready,
                              &probe, SSC_SENSOR_DATA_TYPE, probe.spec->data_type, NULL);
    g_main_loop_run(probe.loop);
    g_clear_handle_id(&probe.deadline_source, g_source_remove);
    g_clear_handle_id(&probe.close_source, g_source_remove);
    g_print("SSC_RESULT sensor=%s status=%s discovered=%s available=%s subscribed=%s closed=%s "
            "requested=%u accepted=%u rejected=%u\n", probe.spec->name, probe.status,
            probe.sensor ? "yes" : "no", probe.availability,
            probe.subscribed ? "yes" : "no", probe.closed ? "yes" : "no",
            probe.requested, probe.accepted, probe.rejected);
    g_clear_object(&probe.sensor);
    g_main_loop_unref(probe.loop);
    return probe.result;
}
