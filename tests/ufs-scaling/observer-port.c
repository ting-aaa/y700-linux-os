#define _GNU_SOURCE
#include "observer.h"
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <termios.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/syscall.h>

static bool attr(const char *name, const char *value)
{
    int fd = open(name, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return false;
    bool ok = write(fd, value, strlen(value)) == (ssize_t)strlen(value);
    close(fd);
    return ok;
}

static bool gadget(void)
{
    static const char *const mods[] = {"qcom_glink_smem","aux-hpd-bridge","fsa4480","pmic_glink",
                                        "pmic_glink_altmode","typec_ucsi","ucsi_glink"};
    for (size_t i=0; i<sizeof(mods)/sizeof(mods[0]); i++) {
        char filename[128];
        snprintf(filename, sizeof(filename), "/modules/%s.ko", mods[i]);
        int fd = open(filename,O_RDONLY | O_CLOEXEC);
        if (fd < 0) return false;
        int rc = syscall(SYS_finit_module, fd, "", 0);
        close(fd);
        if (rc) return false;
    }
    for (int i=0; i<140 && access("/sys/class/udc/a600000.usb",F_OK); i++) usleep(250000);
    if (mount("configfs","/sys/kernel/config","configfs",MS_NOSUID | MS_NODEV | MS_NOEXEC,NULL) ||
        chdir("/sys/kernel/config/usb_gadget") || mkdir("observation",0700) || chdir("observation")) return false;
    if (!attr("idVendor","0x18d1") || !attr("idProduct","0x4e11") || !attr("bDeviceClass","0xef") ||
        !attr("bDeviceSubClass","2") || !attr("bDeviceProtocol","1") || mkdir("strings/0x409",0700) ||
        !attr("strings/0x409/manufacturer","Y700 Linux") || !attr("strings/0x409/product","UFS observer") ||
        !attr("strings/0x409/serialnumber","Y700_UFS_OBSERVER") || mkdir("configs/c.1",0700) ||
        mkdir("functions/acm.obs",0700) || symlink("../../functions/acm.obs","configs/c.1/acm") ||
        !attr("UDC","a600000.usb") || chdir("/")) return false;
    return true;
}

int observation_port(bool vm)
{
    char name[128] = "/dev/ttyGS0";
    if (vm) {
        DIR *d = opendir("/sys/class/virtio-ports");
        if (!d) return -1;
        bool found = false;
        struct dirent *e;
        while ((e = readdir(d))) {
            char attrname[384], buf[64];
            if (strncmp(e->d_name,"vport",5) || strlen(e->d_name)>48) continue;
            snprintf(attrname,sizeof(attrname),"/sys/class/virtio-ports/%s/name",e->d_name);
            if (contents(attrname,buf,sizeof(buf))>0 && !strcmp(buf,"org.y700.ufs\n")) {
                snprintf(name,sizeof(name),"/dev/%.48s",e->d_name);
                found = true;
                break;
            }
        }
        closedir(d);
        if (!found) return -1;
    } else if (!gadget()) return -1;
    int fd = open(name,O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC);
    if (fd >= 0 && !vm) {
        struct termios settings;
        if (tcgetattr(fd,&settings)) { close(fd); return -1; }
        cfmakeraw(&settings);
        settings.c_cflag |= CLOCAL | CREAD;
        if (tcsetattr(fd,TCSANOW,&settings)) { close(fd); return -1; }
    }
    return fd;
}
