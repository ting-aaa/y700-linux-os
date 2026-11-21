/* SPDX-License-Identifier: MIT */
#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/rtc.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/signalfd.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <time.h>
#include <unistd.h>

#define RTC_DIR "/sys/class/rtc/rtc1"
#define DT_ROOT "/sys/firmware/devicetree/base"
#ifdef RTC_QA_PL031
#define NODE "/pl031@9010000"
#define DRIVER "rtc-pl031"
#define IRQ_NAME "rtc-pl031"
#define BUS "amba"
#else
#define NODE "/soc@0/spmi@c400000/pmic@0/rtc@6100"
#define DRIVER "rtc-pm8xxx"
#define IRQ_NAME "pm8xxx_rtc_alarm"
#define BUS "platform"
#endif

static int file_bytes(const char *path, char *buf, size_t size)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t n = read(fd, buf, size - 1);
    close(fd);
    if (n < 0 || (size_t)n == size - 1) return -1;
    buf[n] = 0;
    return (int)n;
}

static int same_inode(const char *a, const char *b)
{
    struct stat x, y;
    return !stat(a, &x) && !stat(b, &y) && x.st_dev == y.st_dev && x.st_ino == y.st_ino;
}

static int identity(void)
{
    char buf[192];
    if (file_bytes(DT_ROOT "/aliases/rtc1", buf, sizeof(buf)) != sizeof(NODE)
        || strcmp(buf, NODE) || !same_inode(RTC_DIR "/device/of_node", DT_ROOT NODE)
        || !same_inode(RTC_DIR "/device/driver", "/sys/bus/" BUS "/drivers/" DRIVER))
        return 0;
#ifndef RTC_QA_PL031
    if (file_bytes(DT_ROOT NODE "/compatible", buf, sizeof(buf)) != sizeof("qcom,pmk8350-rtc")
        || strcmp(buf, "qcom,pmk8350-rtc")) return 0;
#endif
    return file_bytes(RTC_DIR "/hctosys", buf, sizeof(buf)) == 2 && !strcmp(buf, "0\n");
}

/* Sum the per-CPU counts only on the unique, non-shared action's line. */
static int irq_count(int *irq, unsigned long long *total)
{
    FILE *f = fopen("/proc/interrupts", "r");
    if (!f) return -1;
    char *line = NULL;
    size_t size = 0;
    int found = 0;
    while (getline(&line, &size, f) > 0) {
        char *action = strstr(line, " " IRQ_NAME "\n");
        if (!action) continue;
        char *end;
        long number = strtol(line, &end, 10);
        if (end == line || *end != ':' || number < 0) break;
        char *p = end + 1;
        unsigned long long sum = 0;
        int cpus = 0;
        for (;;) {
            while (isspace((unsigned char)*p)) p++;
            if (!isdigit((unsigned char)*p)) break;
            unsigned long long value = strtoull(p, &end, 10);
            if (!isspace((unsigned char)*end)) break;
            sum += value;
            cpus++;
            p = end;
        }
        if (!cpus || found) { found = 0; break; }
        *irq = (int)number;
        *total = sum;
        found = 1;
    }
    free(line);
    fclose(f);
    return found ? 0 : -1;
}

static time_t epoch(const struct rtc_time *t)
{
    struct tm tm = {.tm_year=t->tm_year, .tm_mon=t->tm_mon, .tm_mday=t->tm_mday,
                    .tm_hour=t->tm_hour, .tm_min=t->tm_min, .tm_sec=t->tm_sec};
    time_t v = timegm(&tm);
    if (v < 0 || tm.tm_year != t->tm_year || tm.tm_mon != t->tm_mon
        || tm.tm_mday != t->tm_mday || tm.tm_hour != t->tm_hour
        || tm.tm_min != t->tm_min || tm.tm_sec != t->tm_sec) return -1;
    return v;
}

static int64_t millis(clockid_t clock)
{
    struct timespec t;
    if (clock_gettime(clock, &t)) { perror("clock_gettime"); exit(1); }
    return t.tv_sec * INT64_C(1000) + t.tv_nsec / 1000000;
}

static int snapshot(int fd, struct rtc_wkalrm *a)
{
    return ioctl(fd, RTC_WKALM_RD, a) == 0 && epoch(&a->time) >= 0;
}

static int empty_alarm(int fd, struct rtc_wkalrm *a)
{
    char buf[48];
    return snapshot(fd, a) && !a->enabled && !a->pending && epoch(&a->time) == 0
           && file_bytes(RTC_DIR "/wakealarm", buf, sizeof(buf)) == 0;
}

static int restore(int fd, const struct rtc_wkalrm *original, time_t target)
{
    struct rtc_wkalrm current;
    if (!snapshot(fd, &current) || current.pending) return -1;
    if (empty_alarm(fd, &current)) return 0;
    if (!snapshot(fd, &current) || current.pending || epoch(&current.time) != target) {
        fputs("RTC_ALARM_FOREIGN left_untouched=1\n", stderr);
        return -1;
    }
    if (ioctl(fd, RTC_WKALM_SET, original) || !empty_alarm(fd, &current)) return -1;
    return 0;
}

static int measure(int fd, int signals)
{
    struct rtc_time now;
    struct rtc_wkalrm saved, alarm = {.enabled=1}, current;
    unsigned long long count, after;
    int irq, last_irq;
    if (irq_count(&irq, &count) || ioctl(fd, RTC_RD_TIME, &now)) return 1;
    const time_t start = epoch(&now);
    if (start < 0 || start > UINT32_MAX - 4) return 1;
    time_t target = start + 4;
    struct tm tm;
    if (!gmtime_r(&target, &tm)) return 1;
    alarm.time = (struct rtc_time){.tm_year=tm.tm_year, .tm_mon=tm.tm_mon,
        .tm_mday=tm.tm_mday, .tm_hour=tm.tm_hour, .tm_min=tm.tm_min, .tm_sec=tm.tm_sec};
    struct pollfd p[] = {{.fd=fd, .events=POLLIN}, {.fd=signals, .events=POLLIN}};
    int64_t mono = millis(CLOCK_MONOTONIC), boot = millis(CLOCK_BOOTTIME);
    int64_t offset = millis(CLOCK_REALTIME) - start * INT64_C(1000);
    if (!empty_alarm(fd, &saved) || poll(p, 2, 0) != 0) {
        fputs("RTC_ALARM_REFUSED existing_alarm_or_event=1\n", stderr);
        return 1;
    }
    int passed = 0;
    if (ioctl(fd, RTC_WKALM_SET, &alarm)) { perror("RTC_WKALM_SET"); goto done; }
    if (!snapshot(fd, &current) || !current.enabled || epoch(&current.time) != target)
        goto done;
    printf("RTC_ALARM_ARMED irq=%d delay_s=4 system_minus_rtc_ms=%" PRId64 "\n", irq, offset);
    if (fflush(stdout)) goto done;
    if (poll(p, 2, 10000) != 1 || p[0].revents != POLLIN || p[1].revents) goto done;
    unsigned long event;
    if (read(fd, &event, sizeof(event)) != sizeof(event)
        || event != (1UL << 8 | RTC_IRQF | RTC_AF)) goto done;
    if (irq_count(&last_irq, &after) || last_irq != irq || after != count + 1
        || ioctl(fd, RTC_RD_TIME, &now) || !snapshot(fd, &current)
        || current.enabled || current.pending || epoch(&current.time) != target) goto done;
    time_t end = epoch(&now);
    int64_t elapsed = millis(CLOCK_MONOTONIC) - mono;
    int64_t boottime = millis(CLOCK_BOOTTIME) - boot;
    int64_t final_offset = millis(CLOCK_REALTIME) - end * INT64_C(1000);
    printf("RTC_ALARM_EVENT irq_delta=%llu irqf=1 af=1 count=1 elapsed_ms=%" PRId64
           " rtc_elapsed_s=%" PRId64 " system_minus_rtc_ms=%" PRId64
           " offset_change_ms=%" PRId64 "\n",
           after-count, elapsed, (int64_t)(end-start), final_offset, final_offset-offset);
    passed = end >= target && end <= target+2 && elapsed >= 2500 && elapsed <= 7000
             && llabs(boottime-elapsed) < 100 && llabs(final_offset-offset) < 2000;
done:
    if (restore(fd, &saved, target)) {
        fputs("RTC_ALARM_CLEANUP_UNCONFIRMED\n", stderr);
        return 1;
    }
    printf("RTC_ALARM_CLEANUP original_disabled_time_restored=1 result=%s\n", passed ? "pass" : "incomplete");
    return !passed;
}

int main(int argc, char **argv)
{
    int arm = argc == 2 && !strcmp(argv[1], "--awake-alarm");
    if (!(argc == 1 || arm)) { fputs("Usage: awake-alarm [--awake-alarm]\n", stderr); return 2; }
    if (!identity()) { fputs("RTC_REFUSED rtc1_identity_or_hctosys\n", stderr); return 1; }
    char buf[64], tail;
    long long seconds;
    if (file_bytes(RTC_DIR "/since_epoch", buf, sizeof(buf)) <= 0
        || sscanf(buf, "%lld %c", &seconds, &tail) != 1 || seconds < 0 || seconds > UINT32_MAX) return 1;
    int enabled = file_bytes(RTC_DIR "/wakealarm", buf, sizeof(buf));
    if (enabled < 0) return 1;
    printf("RTC_STATE driver=%s rtc=rtc1 hctosys=0 wakealarm_enabled=%d system_minus_rtc_ms=%" PRId64 "\n",
           DRIVER, !!enabled, millis(CLOCK_REALTIME)-(int64_t)seconds*1000);
    if (!arm) return 0;
    if (enabled) { fputs("RTC_ALARM_REFUSED enabled=1\n", stderr); return 1; }

    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGINT); sigaddset(&mask, SIGHUP); sigaddset(&mask, SIGQUIT); sigaddset(&mask, SIGTERM);
    sigaddset(&mask, SIGPIPE);
    if (sigprocmask(SIG_BLOCK, &mask, NULL)) return 1;
    int signals = signalfd(-1, &mask, SFD_CLOEXEC | SFD_NONBLOCK);
    if (signals < 0) return 1;
    int fd = open("/dev/rtc1", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) { perror("RTC_ALARM_REFUSED open rtc1"); return 1; }
    struct stat st;
    unsigned int maj, min;
    if (fstat(fd, &st) || !S_ISCHR(st.st_mode)
        || file_bytes(RTC_DIR "/dev", buf, sizeof(buf)) <= 0
        || sscanf(buf, "%u:%u %c", &maj, &min, &tail) != 2
        || st.st_rdev != makedev(maj, min) || !identity()) return 1;
    int result = measure(fd, signals);
    close(fd);
    close(signals);
    return result;
}
