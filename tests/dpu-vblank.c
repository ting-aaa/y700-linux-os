/* Read-only scanout probe for the tablet's DSI panel on CRTC 0. */
#include <drm/drm.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    if (argc != 2)
        return 2;
    int fd = open(argv[1], O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        perror("open DRM card");
        return 1;
    }
    uint32_t previous_seq = 0;
    int64_t previous_us = 0;
    for (unsigned int i = 0; i < 16; i++) {
        union drm_wait_vblank event = { .request = {
            .type = _DRM_VBLANK_RELATIVE, .sequence = 1
        }};
        if (ioctl(fd, DRM_IOCTL_WAIT_VBLANK, &event) < 0) {
            perror("wait for CRTC 0 vblank");
            return 1;
        }
        uint32_t seq = event.reply.sequence;
        int64_t us = (int64_t)event.reply.tval_sec * 1000000 + event.reply.tval_usec;
        printf("%u %lld\n", seq, (long long)us);
        if (i && (!(uint32_t)(seq - previous_seq) || us <= previous_us)) {
            fputs("scanout sequence or timestamp did not advance\n", stderr);
            return 1;
        }
        previous_seq = seq;
        previous_us = us;
    }
    return close(fd) != 0;
}
