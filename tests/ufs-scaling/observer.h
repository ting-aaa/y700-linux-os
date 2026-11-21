#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

#define CONTROLLER "/sys/bus/platform/devices/1d84000.ufshc"
#define ROOM 4096
#define PREFIX_BYTES 65536
#define SECTORS 196608
#define TEST_GUID "e59fb29e-76c1-4920-986f-56300445d5c8"

struct target {
    char name[64], parent[64];
    unsigned major, minor, parent_major, parent_minor;
    uint64_t start;
};
struct sample {
    long long runtime, link, freq, axi, unipro, ice, active_ms, suspended_ms;
    long long errors, lun_resets, host_resets, aborts, read_us;
};

ssize_t contents(const char *path, char *out, size_t size);
long long number(const char *path);
long long now_us(void);
bool sha256(const void *bytes, size_t size, char hex[65]);
bool guard_disks(bool vm, bool check_only);
int locate(bool vm, struct target *target);
bool verify_partition(const struct target *target, bool vm);
int open_target(const struct target *target);
bool known_read(int fd, bool vm, long long *us);
void snapshot(struct sample *row);
int observation_port(bool vm);
