#define _GNU_SOURCE
#include "observer.h"
#include <ctype.h>
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/fs.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

static bool path(char *dst, const char *name, const char *attr)
{
    if (!*name || strspn(name, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-") != strlen(name)) return false;
    return snprintf(dst, PATH_MAX, "/sys/class/block/%s/%s", name, attr) < PATH_MAX;
}

static int open_block(const char *name, unsigned a, unsigned b, int flags)
{
    char node[128];
    if (snprintf(node, sizeof(node), "/dev/%s", name) >= (int)sizeof(node)) return -1;
    int fd = open(node, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | flags);
    struct stat st;
    if (fd >= 0 && !fstat(fd, &st) && S_ISBLK(st.st_mode) && st.st_rdev == makedev(a, b)) return fd;
    if (fd >= 0) close(fd);
    return -1;
}

static bool dev_numbers(const char *name, unsigned *a, unsigned *b)
{
    char p[PATH_MAX], buf[64];
    return path(p, name, "dev") && contents(p, buf, sizeof(buf)) > 0 && sscanf(buf, "%u:%u", a, b) == 2;
}

// No block device is opened for writing. BLKROSET sets a volatile kernel policy.
bool guard_disks(bool vm, bool check_only)
{
    DIR *dir = opendir("/sys/class/block");
    if (!dir) return false;
    bool ok = true;
    struct dirent *e;
    while ((e = readdir(dir))) {
        const char *name = e->d_name;
        if (name[0] == '.') continue;
        char p[PATH_MAX], resolved[PATH_MAX];
        if (!path(p, name, "") || !realpath(p, resolved)) { ok = false; break; }
        if (strstr(resolved, "/devices/virtual/block/")) continue;
        // Includes UFS LUNs, their partitions and any removable card. An
        // unexpected real device is also protected before checking its identity.
        if (!path(p, name, "ro")) { ok = false; break; }
        if (number(p) == 1) continue;
        unsigned a, b;
        int one = 1;
        if ((vm && check_only) || !dev_numbers(name, &a, &b)) { ok = false; break; }
        int fd = open_block(name, a, b, O_NONBLOCK);
        bool set = fd >= 0 && ioctl(fd, BLKROSET, &one) == 0;
        if (fd >= 0) close(fd);
        if (!set || number(p) != 1) { ok = false; break; }
    }
    closedir(dir);
    return ok;
}

int locate(bool vm, struct target *t)
{
    int found = 0;
    DIR *dir = opendir("/sys/class/block");
    if (!dir) return -1;
    struct dirent *e;
    while ((e = readdir(dir))) {
        char p[PATH_MAX], buf[4096], real[PATH_MAX];
        const char *name = e->d_name;
        if (name[0] == '.' || !path(p, name, "partition") || number(p) != 41) continue;
        if (!path(p, name, "") || !realpath(p, real)) continue;
        if (!(vm ? strstr(real, "/virtio") && strstr(real, "/block/vda/") :
                    strstr(real, "/1d84000.ufshc/") && strstr(real, "/block/"))) continue;
        if (!path(p, name, "uevent") || contents(p, buf, sizeof(buf)) < 1 ||
            !strstr(buf, "\nPARTNAME=boot_b\n") || !strstr(buf, "\nPARTN=41\n")) continue;
        if (++found != 1) break;
        if (!path(p, name, "size") || number(p) != SECTORS) { found = -1; break; }
        *strrchr(real, '/') = 0;
        const char *parent = strrchr(real, '/') + 1;
        if (strlen(name) >= sizeof(t->name) || strlen(parent) >= sizeof(t->parent)) { found = -1; break; }
        strcpy(t->name, name);
        strcpy(t->parent, parent);
        if (!path(p, name, "start") || number(p) <= 0 || !dev_numbers(name, &t->major, &t->minor) ||
            !dev_numbers(parent, &t->parent_major, &t->parent_minor)) { found = -1; break; }
        t->start = number(p);
    }
    closedir(dir);
    return found;
}

static uint32_t get32(const unsigned char *p) { uint32_t n; memcpy(&n, p, 4); return n; }
static uint64_t get64(const unsigned char *p) { uint64_t n; memcpy(&n, p, 8); return n; }

static uint32_t crc32(const unsigned char *p, size_t n)
{
    uint32_t crc = ~0U;
    for (size_t i = 0; i < n; i++) {
        crc ^= p[i];
        for (int j = 0; j < 8; j++) crc = (crc >> 1) ^ (0xedb88320U & -(crc & 1U));
    }
    return ~crc;
}

bool verify_partition(const struct target *t, bool vm)
{
    char expected[64];
    if (vm) strcpy(expected, TEST_GUID);
    else if (contents("/board-guid", expected, sizeof(expected)) <= 0) return false;
    expected[strcspn(expected, "\n")] = 0;
    unsigned char head[4096] __attribute__((aligned(4096)));
    unsigned char entry[4096] __attribute__((aligned(4096)));
    int fd = open_block(t->parent, t->parent_major, t->parent_minor, O_DIRECT);
    if (fd < 0) return false;
    int ro, sector;
    bool ok = false;
    if (ioctl(fd, BLKROGET, &ro) || ro != 1 || ioctl(fd, BLKSSZGET, &sector) ||
        (sector != 512 && sector != 4096) || pread(fd, head, sector, sector) != sector) goto done;
    if (memcmp(head, "EFI PART", 8) || get32(head+8) != 0x10000 || get64(head+24) != 1 ||
        get32(head+12) != 92 || get64(head+72) != 2 || get32(head+80) < 41 ||
        get32(head+80) > 256 || get32(head+84) != 128) goto done;
    uint32_t crc = get32(head+16);
    memset(head+16, 0, 4);
    if (crc32(head, 92) != crc) goto done;
    // The kernel already parsed GPT and published this partition. Read exactly
    // the primary header and the one sector covering entry 41, never whole LUNs.
    unsigned offset = 40 * 128;
    if (pread(fd, entry, sector, 2LL * sector + offset / sector * sector) != sector) goto done;
    unsigned char *e = entry + offset % sector, *g = e + 16;
    char guid[37];
    snprintf(guid,sizeof(guid),"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
             g[3],g[2],g[1],g[0],g[5],g[4],g[7],g[6],g[8],g[9],g[10],g[11],g[12],g[13],g[14],g[15]);
    uint64_t first = get64(e+32), last = get64(e+40), ratio = sector/512;
    if (strcasecmp(guid, expected) || first < get64(head+40) || last > get64(head+48) || last < first ||
        first != t->start / ratio || t->start % ratio || last-first+1 != SECTORS/ratio ||
        memcmp(e+56, "b\0o\0o\0t\0_\0b\0\0", 14)) goto done;
    ok = true;
done:
    close(fd);
    return ok;
}

int open_target(const struct target *t)
{
    int fd = open_block(t->name, t->major, t->minor, O_DIRECT);
    int ro; uint64_t bytes;
    if (fd >= 0 && ioctl(fd, BLKROGET, &ro) == 0 && ro == 1 &&
        ioctl(fd, BLKGETSIZE64, &bytes) == 0 && bytes == (uint64_t)SECTORS*512) return fd;
    if (fd >= 0) close(fd);
    return -1;
}

bool known_read(int fd, bool vm, long long *us)
{
    static unsigned char buf[PREFIX_BYTES] __attribute__((aligned(4096)));
    const char *expected = vm ? "de2f256064a0af797747c2b97505dc0b9f3df0de4f489eac731c23ae9ca9cc31" :
                                "4316fe356d9244f97b0623abc1e6fc820b295738af24fbe0f3a0f82482d07cad";
    int ro;
    if (ioctl(fd, BLKROGET, &ro) || ro != 1) return false;
    long long start = now_us();
    ssize_t n = pread(fd, buf, sizeof(buf), 0);
    *us = now_us()-start;
    char digest[65];
    return n == sizeof(buf) && sha256(buf, sizeof(buf), digest) && !strcmp(digest, expected);
}
