/* Compare the two Linux wake-alarm APIs while the system stays awake. */
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

static int wait_for_timerfd(void)
{
    struct itimerspec once = { .it_value.tv_nsec = 100000000 };
    struct pollfd event = { .events = POLLIN };
    uint64_t expirations = 0;
    int result = -1;

    event.fd = timerfd_create(CLOCK_BOOTTIME_ALARM, TFD_CLOEXEC | TFD_NONBLOCK);
    if (event.fd < 0) {
        perror("timerfd_create(CLOCK_BOOTTIME_ALARM)");
        return -1;
    }
    if (timerfd_settime(event.fd, 0, &once, NULL) < 0) {
        perror("timerfd_settime");
    } else if (poll(&event, 1, 3000) != 1 || !(event.revents & POLLIN)) {
        fprintf(stderr, "Alarm timerfd failed to become readable within three seconds\n");
    } else if (read(event.fd, &expirations, sizeof(expirations)) != sizeof(expirations) ||
               expirations != 1) {
        fprintf(stderr, "Expected exactly one timerfd expiration\n");
    } else {
        result = 0;
    }
    close(event.fd);
    return result;
}

int main(int argc, char **argv)
{
    struct timespec now;
    struct sigevent event = { .sigev_notify = SIGEV_NONE };
    timer_t alarm;
    int clock_error, timer_error;

    if (argc != 2 || (strcmp(argv[1], "missing-rtc") && strcmp(argv[1], "ready"))) {
        fprintf(stderr, "Usage: awake-clocks missing-rtc|ready (requires CAP_WAKE_ALARM)\n");
        return 2;
    }
    if (clock_gettime(CLOCK_BOOTTIME, &now) < 0) {
        perror("clock_gettime(CLOCK_BOOTTIME)");
        return 1;
    }
    clock_error = clock_gettime(CLOCK_BOOTTIME_ALARM, &now) < 0 ? errno : 0;
    timer_error = timer_create(CLOCK_BOOTTIME_ALARM, &event, &alarm) < 0 ? errno : 0;
    if (!timer_error && timer_delete(alarm) < 0) {
        perror("timer_delete");
        return 1;
    }
    printf("boottime=ok alarm_clock_errno=%d posix_alarm_timer_errno=%d\n",
           clock_error, timer_error);
    if (wait_for_timerfd() < 0)
        return 1;
    puts("awake_alarm_timerfd_expirations=1");
    if (!strcmp(argv[1], "missing-rtc"))
        return !(clock_error == EINVAL && timer_error == EOPNOTSUPP);
    return !!(clock_error || timer_error);
}
