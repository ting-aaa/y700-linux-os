/* Reuse the board-shaped test device, axis ranges, tracking IDs and tap framing. */
#define main gesture_fixture_main
#include "../touch-gestures/evdev-touch.c"
#undef main

static void slide(int fd, struct point from, struct point to)
{
    event(fd, EV_KEY, BTN_TOUCH, 1);
    contact(fd, 0, tracking_id++, from);
    frame(fd);
    usleep(18000);
    for (int i = 1; i <= 24; i++) {
        struct point p = {from.x + (to.x - from.x) * i / 24,
                          from.y + (to.y - from.y) * i / 24};
        contact(fd, 0, 0, p);
        frame(fd);
        usleep(9000);
    }
    contact(fd, 0, -1, (struct point){0});
    event(fd, EV_KEY, BTN_TOUCH, 0);
    frame(fd);
}

static bool valid(struct point p)
{
    return p.x >= 0 && p.x <= X_MAX && p.y >= 0 && p.y <= Y_MAX;
}

int main(void)
{
    char line[4096], name[32], extra;
    FILE *cmdline = fopen("/proc/cmdline", "re");
    if (!cmdline || !fgets(line, sizeof(line), cmdline) ||
        !strstr(line, " y700.touch_gesture_fixture=1 ") ||
        !strstr(line, " y700.topology_fixture=1 "))
        return EXIT_FAILURE;
    fclose(cmdline);
    int fd = touchscreen();
    require(ioctl(fd, UI_GET_SYSNAME(sizeof(name)), name) >= 0, "UI_GET_SYSNAME");
    printf("READY %s\n", name);
    fflush(stdout);
    while (fgets(line, sizeof(line), stdin)) {
        struct point from, to;
        if (sscanf(line, "slide %d %d %d %d %c", &from.x, &from.y, &to.x, &to.y, &extra) == 4 &&
            valid(from) && valid(to))
            slide(fd, from, to);
        else if (sscanf(line, "tap %d %d %c", &from.x, &from.y, &extra) == 2 && valid(from))
            tap(fd, from);
        else
            return EXIT_FAILURE;
    }
    require(ioctl(fd, UI_DEV_DESTROY) == 0, "UI_DEV_DESTROY");
    close(fd);
    return EXIT_SUCCESS;
}
