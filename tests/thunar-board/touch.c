/* Client for the Xorg inputtest driver's private socket on a 2560x1600 display. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include "xf86-input-inputtest-protocol.h"

/* X Input Extension version 2 event types. */
enum { touch_begin = 18, touch_end = 20 };

static void check(int good, const char *what)
{
    if (!good) {
        perror(what);
        exit(1);
    }
}

static void packet(int fd, void *data, size_t size)
{
    check(send(fd, data, size, MSG_NOSIGNAL) == (ssize_t)size, "send");
}

int main(void)
{
    struct sockaddr_un address = {.sun_family = AF_UNIX, .sun_path = "/run/y700-xi.sock"};
    alarm(6);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    check(fd >= 0 && connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0, "connect");
    xf86ITEventClientVersion hello = {{sizeof(hello), XF86IT_EVENT_CLIENT_VERSION}, 1, 1};
    xf86ITResponseServerVersion version;
    packet(fd, &hello, sizeof(hello));
    check(recv(fd, &version, sizeof(version), MSG_WAITALL) == sizeof(version) && version.header.type == XF86IT_RESPONSE_SERVER_VERSION && version.major == 1 && version.minor >= 1, "version");
    alarm(0);
    char line[128], action[16], extra;
    unsigned id = 0;
    int x, y;
    while (fgets(line, sizeof(line), stdin)) {
        if (sscanf(line, "%15s %d %d %c", action, &x, &y, &extra) != 3 ||
            (strcmp(action, "hold") && strcmp(action, "tap")) ||
            x < 0 || x >= 2560 || y < 0 || y >= 1600) return 2;
        alarm(6);
        xf86ITEventTouch t = {.header = {sizeof(t), XF86IT_EVENT_TOUCH}, .touchid = ++id, .touch_type = touch_begin};
        t.valuators.mask[0] = 3;
        t.valuators.valuators[0] = (x + .5) * 65535 / 2560;
        t.valuators.valuators[1] = (y + .5) * 65535 / 1600;
        packet(fd, &t, sizeof(t));
        usleep(!strcmp(action, "hold") ? 1100000 : 95000);
        t.touch_type = touch_end;
        packet(fd, &t, sizeof(t));
        xf86ITEventWaitForSync sync = {{sizeof(sync), XF86IT_EVENT_WAIT_FOR_SYNC}};
        xf86ITResponseSyncFinished done;
        packet(fd, &sync, sizeof(sync));
        check(recv(fd, &done, sizeof(done), MSG_WAITALL) == sizeof(done) && done.header.type == XF86IT_RESPONSE_SYNC_FINISHED, "sync");
        alarm(0);
        puts("OK");
        fflush(stdout);
    }
    close(fd);
    return 0;
}
