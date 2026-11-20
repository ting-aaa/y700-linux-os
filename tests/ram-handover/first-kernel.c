/* PID 1 of the diskless QEMU fixture. Both files passed to the syscall are in RAM. */
#define _GNU_SOURCE
#include <fcntl.h>
#include <linux/kexec.h>
#include <linux/reboot.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

static void fatal(const char *message)
{
    perror(message);
    exit(EXIT_FAILURE);
}

static int checked_command(const char *script)
{
    pid_t child = fork();
    if (child < 0)
        fatal("fork verifier");
    if (child == 0) {
        execl("/bin/busybox", "sh", "-ec", script, (char *)NULL);
        _exit(127);
    }
    int status;
    return waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

int main(void)
{
    if (getpid() != 1)
        return EXIT_FAILURE;
    if (mount("devtmpfs", "/dev", "devtmpfs", 0, NULL) ||
        mount("proc", "/proc", "proc", 0, NULL) ||
        mount("sysfs", "/sys", "sysfs", 0, NULL))
        fatal("mount kernel interfaces");

    const char virt[] = "linux,dummy-virt";
    char board[sizeof(virt) + 1];
    int dt = open("/proc/device-tree/compatible", O_RDONLY);
    if (dt < 0 || read(dt, board, sizeof(board)) != sizeof(virt) ||
        memcmp(board, virt, sizeof(virt))) {
        fputs("RAM handover requires the QEMU virt board\n", stderr);
        return EXIT_FAILURE;
    }
    close(dt);
    int serial = open("/dev/ttyAMA0", O_WRONLY | O_NOCTTY);
    if (serial < 0 || dup2(serial, STDERR_FILENO) < 0 || dup2(serial, STDOUT_FILENO) < 0)
        fatal("open virtual console");
    close(serial);

    if (!checked_command("exec /bin/busybox sha256sum -c /payload.sha256"))
        return EXIT_FAILURE;
    fputs("RAM_QA_KEXEC_INPUTS_VERIFIED\n", stderr);

    FILE *cmdline = fopen("/proc/cmdline", "r");
    char *args = NULL;
    size_t capacity = 0;
    if (!cmdline || getline(&args, &capacity, cmdline) < 1)
        fatal("read boot options");
    fclose(cmdline);
    args[strcspn(args, "\n")] = '\0';
    int kernel = open("/kernel.efi", O_RDONLY);
    int initrd = open("/initrd", O_RDONLY);
    struct stat st;
    if (kernel < 0 || initrd < 0 || fstat(initrd, &st))
        fatal("open RAM inputs");
    fprintf(stderr, "RAM_QA_KEXEC_LOADING initrd_bytes=%lld\n", (long long)st.st_size);
    if (syscall(SYS_kexec_file_load, kernel, initrd, strlen(args) + 1, args, KEXEC_FILE_DEBUG) < 0)
        fatal("kexec_file_load");
    close(initrd);
    close(kernel);
    free(args);
    fputs("RAM_QA_KEXEC_FILE_LOADED\n", stderr);
    char cpu_count[32];
    snprintf(cpu_count, sizeof(cpu_count), "%ld", sysconf(_SC_NPROCESSORS_ONLN));
    if (setenv("CPU_COUNT", cpu_count, 1) ||
        !checked_command("/bin/busybox dmesg -s 1048576 > /first-kernel.log; "
                         "exec /bin/busybox awk -v cpus=\"$CPU_COUNT\" "
                         "-f /check-irq-placement.awk /first-kernel.log")) {
        fputs("RAM_QA_KEXEC_STOPPED_BEFORE_HANDOVER\n", stderr);
        if (syscall(SYS_kexec_file_load, -1, -1, 0, NULL, KEXEC_FILE_UNLOAD) < 0)
            fatal("unload rejected image");
        reboot(LINUX_REBOOT_CMD_POWER_OFF);
        return EXIT_FAILURE;
    }
    fputs("RAM_QA_KEXEC_HANDOVER\n", stderr);
    if (reboot(LINUX_REBOOT_CMD_KEXEC) < 0)
        fatal("reboot into the loaded kernel");
    return EXIT_FAILURE;
}
