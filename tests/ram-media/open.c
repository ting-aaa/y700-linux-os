#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

/* This program lives only in the miniature PC VM with new file-backed
 * canaries. Linux may grant a writable fd on a BLKROSET-protected disk. */
int main(int argc, char **argv)
{
    if (argc != 2)
        return 2;
    int fd = open(argv[1], O_RDWR | O_CLOEXEC | O_SYNC);
    if (fd < 0) {
        int saved = errno;
        printf("MEDIA_WRITE device=%s open_denied=%d\n", argv[1], saved);
        return (saved == EACCES || saved == EROFS || saved == EPERM) ? 0 : 1;
    }
    int ro = 0;
    if (ioctl(fd, BLKROGET, &ro) < 0 || ro != 1)
        return 2;
    _Alignas(4096) unsigned char canary[4096];
    memset(canary, 0xa5, sizeof(canary));
    errno = 0;
    ssize_t written = pwrite(fd, canary, sizeof(canary), 4096);
    int write_errno = errno;
    int synced = fsync(fd);
    int closed = close(fd);
    printf("MEDIA_WRITE device=%s open_rw=1 blkroget=%d pwrite=%zd errno=%d fsync=%d close=%d\n",
           argv[1], ro, written, write_errno, synced, closed);
    return (written == -1 && (write_errno == EACCES || write_errno == EROFS || write_errno == EPERM)
            && synced == 0 && closed == 0) ? 0 : 1;
}
