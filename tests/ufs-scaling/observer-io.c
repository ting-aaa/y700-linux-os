#define _GNU_SOURCE
#include "observer.h"
#include <fcntl.h>
#include <linux/if_alg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>

ssize_t contents(const char *path, char *out, size_t size)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    size_t used = 0;
    while (used < size - 1) {
        ssize_t n = read(fd, out + used, size - 1 - used);
        if (!n) break;
        if (n < 0) { close(fd); return -1; }
        used += n;
    }
    char extra;
    ssize_t overflow = used == size - 1 ? read(fd, &extra, 1) : 0;
    close(fd);
    out[used] = 0;
    return overflow == 0 ? (ssize_t)used : -1;
}

long long number(const char *path)
{
    char buf[64], *end;
    if (contents(path, buf, sizeof(buf)) <= 0) return -1;
    errno = 0;
    long long v = strtoll(buf, &end, 10);
    return errno || v < 0 || end == buf || (*end && strcmp(end, "\n")) ? -1 : v;
}

long long now_us(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000000LL + t.tv_nsec / 1000;
}

bool sha256(const void *bytes, size_t size, char hex[65])
{
    struct sockaddr_alg alg = { .salg_family = AF_ALG, .salg_type = "hash", .salg_name = "sha256" };
    int s = socket(AF_ALG, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    if (s < 0) return false;
    int fd = bind(s, (void *)&alg, sizeof(alg)) == 0 ? accept(s, NULL, NULL) : -1;
    close(s);
    if (fd < 0) return false;
    unsigned char digest[32];
    bool ok = send(fd, bytes, size, 0) == (ssize_t)size && read(fd, digest, 32) == 32;
    close(fd);
    if (ok) for (int i = 0; i < 32; i++) sprintf(hex + 2*i, "%02x", digest[i]);
    return ok;
}

static int state(const char *path, const char *const names[], size_t count)
{
    char value[64];
    if (contents(path, value, sizeof(value)) <= 0) return -1;
    value[strcspn(value, "\n")] = 0;
    for (size_t i = 0; i < count; i++) if (!strcmp(value, names[i])) return (int)i;
    return -1;
}

void snapshot(struct sample *v)
{
    static const char *const pm[] = {"active", "suspended", "suspending", "resuming", "unsupported"};
    static const char *const link[] = {"OFF", "ACTIVE", "HIBERN8", "BROKEN", "UNKNOWN"};
    v->runtime = state(CONTROLLER "/power/runtime_status", pm, 5);
    v->link = state(CONTROLLER "/power_info/link_state", link, 5);
    v->active_ms = number(CONTROLLER "/power/runtime_active_time");
    v->suspended_ms = number(CONTROLLER "/power/runtime_suspended_time");
    v->freq = number("/sys/class/devfreq/1d84000.ufshc/cur_freq");
    v->axi = number("/sys/kernel/debug/clk/gcc_ufs_phy_axi_clk/clk_rate");
    v->unipro = number("/sys/kernel/debug/clk/gcc_ufs_phy_unipro_core_clk/clk_rate");
    v->ice = number("/sys/kernel/debug/clk/gcc_ufs_phy_ice_core_clk/clk_rate");
    v->read_us = v->errors = v->lun_resets = v->host_resets = v->aborts = -1;
    char buf[ROOM];
    if (contents("/sys/kernel/debug/ufshcd/1d84000.ufshc/stats", buf, sizeof(buf)) <= 0) return;
    long long sum = 0, value;
    int rows = 0;
    for (char *line = strtok(buf, "\n"); line; line = strtok(NULL, "\n")) {
        char *colon = strrchr(line, ':');
        if (!colon || sscanf(colon + 1, "%lld", &value) != 1 || value < 0) return;
        *colon = 0;
        if (!strcmp(line, "Logical Unit Resets")) v->lun_resets = value;
        else if (!strcmp(line, "Host Resets")) v->host_resets = value;
        else if (!strcmp(line, "SCSI command aborts")) v->aborts = value;
        else { sum += value; rows++; }
    }
    if (rows == 10) v->errors = sum;
}
