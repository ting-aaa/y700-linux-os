/* SPDX-License-Identifier: MIT */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <inttypes.h>
#include <linux/media.h>
#include <linux/videodev2.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

static void fail(const char *why)
{
    fprintf(stderr, "LENS_CHECK_INCOMPLETE %s\n", why);
    exit(1);
}

static void *table(unsigned count, size_t stride)
{
    if (count > 16384) fail("unexpected media topology size");
    void *p = calloc(count ? count : 1, stride);
    if (!p) fail("out of memory");
    return p;
}

static int open_media(const char *node)
{
    const char prefix[] = "/dev/media";
    if (strncmp(node, prefix, sizeof(prefix)-1)) fail("expected /dev/mediaN");
    const char *n = node + sizeof(prefix)-1;
    if (!*n || strspn(n, "0123456789") != strlen(n) || strlen(n) > 10) fail("expected /dev/mediaN");
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "/sys/bus/media/devices/media%s/dev", n);
    FILE *f = fopen(path, "r");
    unsigned maj, min;
    if (!f || fscanf(f, "%u:%u", &maj, &min) != 2) fail("media-class device unavailable");
    fclose(f);
    dev_t expected = makedev(maj, min);
    struct stat st;
    if (lstat(node, &st) || !S_ISCHR(st.st_mode) || st.st_rdev != expected)
        fail("media-class device mismatch");
    int fd = open(node, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0 || fstat(fd, &st) || !S_ISCHR(st.st_mode) || st.st_rdev != expected)
        fail("cannot open media-class device");
    return fd;
}

static void query_range(const char *node, dev_t expected)
{
    struct stat st;
    if (lstat(node, &st) || !S_ISCHR(st.st_mode) || st.st_rdev != expected)
        fail("provided node does not match the linked lens interface");
    int fd = open(node, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0 || fstat(fd, &st) || !S_ISCHR(st.st_mode) || st.st_rdev != expected)
        fail("cannot open the linked lens interface");
    struct v4l2_query_ext_ctrl q = { .id = V4L2_CID_FOCUS_ABSOLUTE };
    if (ioctl(fd, VIDIOC_QUERY_EXT_CTRL, &q) < 0) fail("FOCUS_ABSOLUTE query failed");
    close(fd);
    if (q.type != V4L2_CTRL_TYPE_INTEGER || (q.flags & V4L2_CTRL_FLAG_DISABLED)
        || q.minimum >= q.maximum || !q.step || q.default_value < q.minimum
        || q.default_value > q.maximum) fail("invalid FOCUS_ABSOLUTE metadata");
    printf("FOCUS_ABSOLUTE min=%lld max=%lld step=%llu default=%lld flags=0x%x\n",
           (long long)q.minimum, (long long)q.maximum, (unsigned long long)q.step,
           (long long)q.default_value, q.flags);
}

int main(int argc, char **argv)
{
    if (argc != 3 && !(argc == 5 && !strcmp(argv[3], "--query-range"))) {
        fputs("Usage: lens-graph MEDIA_NODE EXACT_SENSOR [--query-range LENS_SUBDEV_NODE]\n", stderr);
        return 2;
    }
    int fd = open_media(argv[1]);
    struct media_v2_topology t = { 0 };
    if (ioctl(fd, MEDIA_IOC_G_TOPOLOGY, &t) < 0) fail("cannot read topology sizes");
    uint64_t version = t.topology_version;
    struct media_v2_entity *entities = table(t.num_entities, sizeof(*entities));
    struct media_v2_interface *interfaces = table(t.num_interfaces, sizeof(*interfaces));
    struct media_v2_link *links = table(t.num_links, sizeof(*links));
    t.ptr_entities = (uintptr_t)entities;
    t.ptr_interfaces = (uintptr_t)interfaces;
    t.ptr_links = (uintptr_t)links;
    if (ioctl(fd, MEDIA_IOC_G_TOPOLOGY, &t) < 0 || t.topology_version != version)
        fail("topology changed or could not be read");
    struct media_v2_entity *sensor = NULL, *lens = NULL;
    unsigned lens_count = 0;
    for (unsigned i = 0; i < t.num_entities; i++) {
        if (strnlen(entities[i].name, sizeof(entities[i].name)) == sizeof(entities[i].name))
            fail("unterminated entity name");
        if (entities[i].function == MEDIA_ENT_F_LENS) lens_count++;
        if (entities[i].function == MEDIA_ENT_F_CAM_SENSOR && !strcmp(entities[i].name, argv[2])) {
            if (sensor) fail("ambiguous sensor");
            sensor = &entities[i];
        }
    }
    if (!sensor) fail("sensor not found");
    if (!lens_count) fail("media graph contains no lens entity");
    for (unsigned i = 0; i < t.num_links; i++) {
        if (links[i].source_id != sensor->id || !(links[i].flags & MEDIA_LNK_FL_ENABLED)
            || (links[i].flags & MEDIA_LNK_FL_LINK_TYPE) != MEDIA_LNK_FL_ANCILLARY_LINK) continue;
        for (unsigned j = 0; j < t.num_entities; j++) {
            if (entities[j].id == links[i].sink_id && entities[j].function == MEDIA_ENT_F_LENS) {
                if (lens) fail("ambiguous sensor-to-lens link");
                lens = &entities[j];
            }
        }
    }
    if (!lens) fail("sensor has no enabled ancillary link to a lens");
    struct media_v2_interface *intf = NULL;
    for (unsigned i = 0; i < t.num_links; i++) {
        if (links[i].sink_id != lens->id || !(links[i].flags & MEDIA_LNK_FL_ENABLED)
            || (links[i].flags & MEDIA_LNK_FL_LINK_TYPE) != MEDIA_LNK_FL_INTERFACE_LINK) continue;
        for (unsigned j = 0; j < t.num_interfaces; j++) {
            if (interfaces[j].id == links[i].source_id && interfaces[j].intf_type == MEDIA_INTF_T_V4L_SUBDEV) {
                if (intf) fail("ambiguous lens interface");
                intf = &interfaces[j];
            }
        }
    }
    if (!intf) fail("lens lacks an enabled V4L2 subdevice interface");
    printf("LENS_GRAPH sensor=\"%s\" lens=\"%s\" interface=%u:%u\n",
           sensor->name, lens->name, intf->devnode.major, intf->devnode.minor);
    if (argc == 5)
        query_range(argv[4], makedev(intf->devnode.major, intf->devnode.minor));
    close(fd);
    free(entities); free(interfaces); free(links);
    return 0;
}
