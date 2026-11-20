/* Guest-only Type-B touchscreen. The private port accepts bounded taps. */
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static void require(int ok, const char *operation)
{
    if (!ok) {
        perror(operation);
        exit(EXIT_FAILURE);
    }
}

static void axis(int fd, unsigned short code, int max)
{
    struct uinput_abs_setup a = {.code = code, .absinfo = {.maximum = max}};
    require(ioctl(fd, UI_SET_ABSBIT, code) == 0, "absolute axis");
    require(ioctl(fd, UI_ABS_SETUP, &a) == 0, "limits");
}

static void event(int fd, unsigned short type, unsigned short code, int value)
{
    struct input_event e = {.type = type, .code = code, .value = value};
    require(write(fd, &e, sizeof(e)) == sizeof(e), "input event");
}

static void tap(int fd, int x, int y)
{
    static int next;
    event(fd, EV_ABS, ABS_MT_SLOT, 0);
    event(fd, EV_ABS, ABS_MT_TRACKING_ID, ++next);
    event(fd, EV_ABS, ABS_MT_POSITION_X, x);
    event(fd, EV_ABS, ABS_MT_POSITION_Y, y);
    event(fd, EV_KEY, BTN_TOUCH, 1);
    event(fd, EV_ABS, ABS_X, x);
    event(fd, EV_ABS, ABS_Y, y);
    event(fd, EV_SYN, SYN_REPORT, 0);
    usleep(140000);
    event(fd, EV_ABS, ABS_MT_TRACKING_ID, -1);
    event(fd, EV_KEY, BTN_TOUCH, 0);
    event(fd, EV_SYN, SYN_REPORT, 0);
    usleep(140000);
}

int main(void)
{
    char line[4096];
    FILE *cmdline = fopen("/proc/cmdline", "re");
    if (!cmdline || !fgets(line, sizeof(line), cmdline) ||
        !strstr(line, " y700.combined_efi=1 "))
        return EXIT_FAILURE;
    fclose(cmdline);
    int fd = open("/dev/uinput", O_WRONLY | O_CLOEXEC);
    require(fd >= 0, "uinput");
    require(ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT) == 0, "direct touch");
    require(ioctl(fd, UI_SET_EVBIT, EV_KEY) == 0, "key events");
    require(ioctl(fd, UI_SET_KEYBIT, BTN_TOUCH) == 0, "touch events");
    require(ioctl(fd, UI_SET_EVBIT, EV_ABS) == 0, "absolute events");
    axis(fd, ABS_X, 1023);
    axis(fd, ABS_Y, 767);
    axis(fd, ABS_MT_SLOT, 1);
    axis(fd, ABS_MT_TRACKING_ID, 65535);
    axis(fd, ABS_MT_POSITION_X, 1023);
    axis(fd, ABS_MT_POSITION_Y, 767);
    struct uinput_setup info = {
        .name = "Y700 QEMU enrollment touchscreen",
        .id = {.bustype = BUS_VIRTUAL, .vendor = 1, .product = 2, .version = 1},
    };
    require(ioctl(fd, UI_DEV_SETUP, &info) == 0, "setup");
    require(ioctl(fd, UI_DEV_CREATE) == 0, "create");
    int port = open("/dev/virtio-ports/org.y700.enroll", O_RDWR | O_CLOEXEC);
    require(port >= 0, "private test channel");
    FILE *in = fdopen(dup(port), "r");
    require(in != NULL, "test input");
    dprintf(port, "READY\n");
    while (fgets(line, sizeof(line), in)) {
        int x, y;
        char extra;
        if (sscanf(line, "tap %d %d %c", &x, &y, &extra) != 2 ||
            x < 0 || x >= 1024 || y < 0 || y >= 768) {
            dprintf(port, "ERROR\n");
            return EXIT_FAILURE;
        }
        tap(fd, x, y);
        dprintf(port, "OK\n");
    }
    ioctl(fd, UI_DEV_DESTROY);
    fclose(in);
    close(port);
    close(fd);
    return 0;
}
