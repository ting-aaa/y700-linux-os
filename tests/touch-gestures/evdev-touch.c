/* Disposable guest-only replay for the NT36523N's direct Type-B event shape. */
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

enum { X_MAX = 16000, Y_MAX = 25600, SLOTS = 10 };

struct point {
    int x;
    int y;
};

struct gesture {
    struct point start[2];
    struct point end[2];
};

struct trace {
    const char *rotation;
    struct gesture scroll;
    struct gesture pinch;
};

/* Literal native-axis samples. The browser oracle uses separate screen targets. */
static const struct trace traces[] = {
    {"normal",
     {{{5440, 18688}, {7680, 18688}}, {{5440, 8192}, {7680, 8192}}},
     {{{7680, 12032}, {10560, 12032}}, {{4800, 12032}, {13440, 12032}}}},
    {"left",
     {{{11680, 16896}, {11680, 13312}}, {{5120, 16896}, {5120, 13312}}},
     {{{7520, 13312}, {7520, 8704}}, {{7520, 17920}, {7520, 4096}}}},
    {"inverted",
     {{{10560, 6912}, {8320, 6912}}, {{10560, 17408}, {8320, 17408}}},
     {{{8320, 13568}, {5440, 13568}}, {{11200, 13568}, {2560, 13568}}}},
    {"right",
     {{{4320, 8704}, {4320, 12288}}, {{10880, 8704}, {10880, 12288}}},
     {{{8480, 12288}, {8480, 16896}}, {{8480, 7680}, {8480, 21504}}}},
};

static int tracking_id = 1;

static void require(bool condition, const char *operation)
{
    if (!condition) {
        perror(operation);
        exit(EXIT_FAILURE);
    }
}

static void axis(int fd, unsigned short code, int maximum)
{
    struct uinput_abs_setup spec = {.code = code, .absinfo = {.maximum = maximum}};
    require(ioctl(fd, UI_SET_ABSBIT, code) == 0, "UI_SET_ABSBIT");
    require(ioctl(fd, UI_ABS_SETUP, &spec) == 0, "UI_ABS_SETUP");
}

static int touchscreen(void)
{
    int fd = open("/dev/uinput", O_WRONLY | O_CLOEXEC);
    require(fd >= 0, "/dev/uinput");
    struct uinput_setup spec = {
        .id = {.bustype = BUS_SPI}, .name = "NT36523N Capacitive Touchscreen"
    };
    require(ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT) == 0, "INPUT_PROP_DIRECT");
    require(ioctl(fd, UI_SET_EVBIT, EV_KEY) == 0, "EV_KEY");
    require(ioctl(fd, UI_SET_KEYBIT, BTN_TOUCH) == 0, "BTN_TOUCH");
    require(ioctl(fd, UI_SET_EVBIT, EV_ABS) == 0, "EV_ABS");
    axis(fd, ABS_X, X_MAX);
    axis(fd, ABS_Y, Y_MAX);
    axis(fd, ABS_MT_SLOT, SLOTS - 1);
    axis(fd, ABS_MT_TRACKING_ID, 65535);
    axis(fd, ABS_MT_POSITION_X, X_MAX);
    axis(fd, ABS_MT_POSITION_Y, Y_MAX);
    axis(fd, ABS_MT_TOUCH_MAJOR, 255);
    axis(fd, ABS_MT_PRESSURE, 1000);
    require(ioctl(fd, UI_DEV_SETUP, &spec) == 0, "UI_DEV_SETUP");
    require(ioctl(fd, UI_DEV_CREATE) == 0, "UI_DEV_CREATE");
    return fd;
}

static void event(int fd, unsigned short type, unsigned short code, int value)
{
    struct input_event e = {.type = type, .code = code, .value = value};
    require(write(fd, &e, sizeof(e)) == sizeof(e), "write input event");
}

static void contact(int fd, int slot, int id, struct point point)
{
    event(fd, EV_ABS, ABS_MT_SLOT, slot);
    if (id != 0)
        event(fd, EV_ABS, ABS_MT_TRACKING_ID, id);
    if (id < 0)
        return;
    event(fd, EV_ABS, ABS_MT_POSITION_X, point.x);
    event(fd, EV_ABS, ABS_MT_POSITION_Y, point.y);
    event(fd, EV_ABS, ABS_MT_TOUCH_MAJOR, 10 + slot);
    event(fd, EV_ABS, ABS_MT_PRESSURE, 98 + slot);
    if (slot == 0) {
        event(fd, EV_ABS, ABS_X, point.x);
        event(fd, EV_ABS, ABS_Y, point.y);
    }
}

static void frame(int fd)
{
    event(fd, EV_SYN, SYN_REPORT, 0);
}

static void tap(int fd)
{
    /* One fixed, asymmetric raw contact in every display orientation. */
    event(fd, EV_KEY, BTN_TOUCH, 1);
    contact(fd, 0, tracking_id++, (struct point){3920, 16896});
    frame(fd);
    usleep(90000);
    contact(fd, 0, -1, (struct point){0});
    event(fd, EV_KEY, BTN_TOUCH, 0);
    frame(fd);
}

static void gesture(int fd, const struct gesture *trace)
{
    enum { FRAMES = 32 };

    event(fd, EV_KEY, BTN_TOUCH, 1);
    for (int slot = 0; slot < 2; slot++) {
        contact(fd, slot, tracking_id++, trace->start[slot]);
        frame(fd);
        usleep(60000);
    }

    for (int step = 1; step <= FRAMES; step++) {
        for (int slot = 0; slot < 2; slot++) {
            struct point start = trace->start[slot];
            struct point end = trace->end[slot];
            struct point point = {
                start.x + (end.x - start.x) * step / FRAMES,
                start.y + (end.y - start.y) * step / FRAMES,
            };
            contact(fd, slot, 0, point);
        }
        frame(fd);
        usleep(20000);
    }
    contact(fd, 0, -1, (struct point){0});
    contact(fd, 1, -1, (struct point){0});
    event(fd, EV_KEY, BTN_TOUCH, 0);
    frame(fd);
}

int main(void)
{
    /* Never create an input device unless booted into the disposable fixture. */
    FILE *cmdline = fopen("/proc/cmdline", "re");
    char line[4096];
    if (!cmdline || !fgets(line, sizeof(line), cmdline) ||
        !strstr(line, " y700.touch_gesture_fixture=1 "))
        return EXIT_FAILURE;
    fclose(cmdline);
    int fd = touchscreen();
    char name[32];
    require(ioctl(fd, UI_GET_SYSNAME(sizeof(name)), name) >= 0, "UI_GET_SYSNAME");
    printf("READY %s\n", name);
    fflush(stdout);
    while (fgets(line, sizeof(line), stdin)) {
        char rotation[16], action[16], extra;
        if (sscanf(line, "%15s %15s %c", rotation, action, &extra) != 2)
            return EXIT_FAILURE;
        const struct trace *trace = NULL;
        for (size_t i = 0; i < sizeof(traces) / sizeof(traces[0]); i++) {
            if (!strcmp(rotation, traces[i].rotation)) {
                trace = &traces[i];
                break;
            }
        }
        if (!trace)
            return EXIT_FAILURE;
        if (!strcmp(action, "tap"))
            tap(fd);
        else if (!strcmp(action, "scroll"))
            gesture(fd, &trace->scroll);
        else if (!strcmp(action, "pinch"))
            gesture(fd, &trace->pinch);
        else
            return EXIT_FAILURE;
        puts("DONE");
        fflush(stdout);
    }
    require(ioctl(fd, UI_DEV_DESTROY) == 0, "UI_DEV_DESTROY");
    close(fd);
    return EXIT_SUCCESS;
}
