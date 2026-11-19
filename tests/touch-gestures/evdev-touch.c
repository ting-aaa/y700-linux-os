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

/* Screen coordinates in thousandths. Raw SPI-panel coordinates stay portrait. */
static void contact(int fd, int slot, int id, bool left, int screen_x, int screen_y)
{
    const int x = (left ? screen_y : screen_x) * X_MAX / 1000;
    const int y = (left ? 1000 - screen_x : screen_y) * Y_MAX / 1000;
    event(fd, EV_ABS, ABS_MT_SLOT, slot);
    if (id != 0)
        event(fd, EV_ABS, ABS_MT_TRACKING_ID, id);
    if (id < 0)
        return;
    event(fd, EV_ABS, ABS_MT_POSITION_X, x);
    event(fd, EV_ABS, ABS_MT_POSITION_Y, y);
    event(fd, EV_ABS, ABS_MT_TOUCH_MAJOR, 10 + slot);
    event(fd, EV_ABS, ABS_MT_PRESSURE, 98 + slot);
    if (slot == 0) {
        event(fd, EV_ABS, ABS_X, x);
        event(fd, EV_ABS, ABS_Y, y);
    }
}

static void frame(int fd)
{
    event(fd, EV_SYN, SYN_REPORT, 0);
}

static void gesture(int fd, bool left, bool pinch)
{
    enum { FRAMES = 32 };
    static int tracking_id = 1;
    const int start_y = pinch ? 470 : 730;
    const int start_span = pinch ? 50 : 90;

    event(fd, EV_KEY, BTN_TOUCH, 1);
    contact(fd, 0, tracking_id++, left, 500 - start_span, start_y);
    frame(fd);
    usleep(60000);
    contact(fd, 1, tracking_id++, left, 500 + start_span, start_y);
    frame(fd);
    usleep(60000);

    for (int step = 1; step <= FRAMES; step++) {
        const int span = start_span + (pinch ? 180 * step / FRAMES : 0);
        const int y = start_y - (pinch ? 0 : 410 * step / FRAMES);
        contact(fd, 0, 0, left, 500 - span, y);
        contact(fd, 1, 0, left, 500 + span, y);
        frame(fd);
        usleep(20000);
    }
    contact(fd, 0, -1, left, 0, 0);
    contact(fd, 1, -1, left, 0, 0);
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
        if (!strcmp(line, "portrait scroll\n"))
            gesture(fd, false, false);
        else if (!strcmp(line, "portrait pinch\n"))
            gesture(fd, false, true);
        else if (!strcmp(line, "landscape scroll\n"))
            gesture(fd, true, false);
        else if (!strcmp(line, "landscape pinch\n"))
            gesture(fd, true, true);
        else
            return EXIT_FAILURE;
        puts("DONE");
        fflush(stdout);
    }
    require(ioctl(fd, UI_DEV_DESTROY) == 0, "UI_DEV_DESTROY");
    close(fd);
    return EXIT_SUCCESS;
}
