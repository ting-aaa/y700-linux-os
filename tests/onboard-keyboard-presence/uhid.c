/* Attach a standard keyboard-only or mouse-only HID in the disposable guest. */
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uhid.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Standard HID boot-keyboard input report and three-button relative mouse. */
static const unsigned char keyboard[] = {
    0x05,0x01,0x09,0x06,0xa1,0x01,0x05,0x07,0x19,0xe0,0x29,0xe7,
    0x15,0x00,0x25,0x01,0x75,0x01,0x95,0x08,0x81,0x02,0x95,0x01,
    0x75,0x08,0x81,0x01,0x95,0x06,0x75,0x08,0x15,0x00,0x25,0x65,
    0x05,0x07,0x19,0x00,0x29,0x65,0x81,0x00,0xc0,
};
static const unsigned char mouse[] = {
    0x05,0x01,0x09,0x02,0xa1,0x01,0x09,0x01,0xa1,0x00,0x05,0x09,
    0x19,0x01,0x29,0x03,0x15,0x00,0x25,0x01,0x95,0x03,0x75,0x01,
    0x81,0x02,0x95,0x01,0x75,0x05,0x81,0x01,0x05,0x01,0x09,0x30,
    0x09,0x31,0x09,0x38,0x15,0x81,0x25,0x7f,0x75,0x08,0x95,0x03,
    0x81,0x06,0xc0,0xc0,
};

int main(int argc, char **argv)
{
    char line[4096];
    FILE *cmdline = fopen("/proc/cmdline", "re");
    if (!cmdline || !fgets(line, sizeof(line), cmdline) ||
        !strstr(line, " y700.onboard_fixture=1 ") || argc != 2)
        return EXIT_FAILURE;
    fclose(cmdline);

    struct uhid_event ev = {.type = UHID_CREATE2};
    const unsigned char *descriptor;
    size_t size;
    const char *name;
    if (!strcmp(argv[1], "keyboard")) {
        descriptor = keyboard;
        size = sizeof(keyboard);
        name = "Y700 Fixture Keyboard";
    } else if (!strcmp(argv[1], "mouse")) {
        descriptor = mouse;
        size = sizeof(mouse);
        name = "Y700 Fixture Mouse";
    } else {
        return EXIT_FAILURE;
    }
    memcpy(ev.u.create2.rd_data, descriptor, size);
    ev.u.create2.rd_size = size;
    ev.u.create2.bus = BUS_BLUETOOTH;
    ev.u.create2.vendor = 0xf001;
    ev.u.create2.product = descriptor == keyboard ? 1 : 2;
    snprintf((char *)ev.u.create2.name, sizeof(ev.u.create2.name), "%s", name);
    snprintf((char *)ev.u.create2.phys, sizeof(ev.u.create2.phys), "y700-fixture/%s", argv[1]);
    int fd = open("/dev/uhid", O_RDWR | O_CLOEXEC);
    if (fd < 0 || write(fd, &ev, sizeof(ev)) != sizeof(ev)) {
        perror("UHID_CREATE2");
        return EXIT_FAILURE;
    }
    /* Closing this process's descriptor removes the device from the kernel. */
    for (;;)
        pause();
}
