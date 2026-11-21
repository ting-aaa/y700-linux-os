#define _GNU_SOURCE
#include "observer.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/wait.h>

static char result[ROOM], digest[65];
static int variant;
static bool vm, check_only;

static bool contains_token(const char *data, size_t n, const char *token)
{
    for (size_t i=0; i<n;) {
        size_t len = strnlen(data+i,n-i);
        if (len == n-i) return false;
        if (!strcmp(data+i,token)) return true;
        i += len+1;
    }
    return false;
}

static bool identity(void)
{
    char data[ROOM], notes[2048], sum[65];
    ssize_t n=contents("/proc/device-tree/compatible",data,sizeof(data));
    if (n <= 0) return false;
    vm = contains_token(data,n,"linux,dummy-virt");
    if (!vm && !contains_token(data,n,"lenovo,asphalt")) return false;
    if (contents("/proc/cmdline",data,sizeof(data))<1) return false;
    bool mode=false, resume=false, init=false;
    for (char *arg=strtok(data," \n"); arg; arg=strtok(NULL," \n")) {
        if (!strcmp(arg,"y700.ufs_observe=1")) mode=true;
        else if (!strcmp(arg,"noresume")) resume=true;
        else if (!strcmp(arg,"rdinit=/init")) init=true;
        else if (!strcmp(arg,"y700.ufs_qa_ro=check") && vm) check_only=true;
        else if (!strncmp(arg,"root=",5) || !strncmp(arg,"init=",5) || !strncmp(arg,"resume=",7) ||
                 !strncmp(arg,"rdinit=",7) || !strncmp(arg,"y700.",5)) return false;
    }
    if (!mode || !resume || !init) return false;
    n=contents("/sys/kernel/notes",notes,sizeof(notes));
    if (n<=0 || !sha256(notes,n,sum)) return false;
    if (!strcmp(sum,"c53a42974b4921ac99bd0defadc5ade9a25d4cfd9a2a731dc2ba43d81ddaf063")) variant=0;
    else if (!strcmp(sum,"96f7f8fa58c211d1eee65be0084c4048f4c6244d843e7ae487788ad7356e382a")) variant=1;
    else return false;
    if (vm) return true;
    if (contents("/proc/device-tree/region_country",data,sizeof(data))<=0 || strcmp(data,"PRC")) return false;
    n=contents("/proc/device-tree/soc@0/ufshc@1d84000/clock-names",data,sizeof(data));
    if (n<=0) return false;
    int clocks=0;
    for (ssize_t i=0; i<n; i++) if (!data[i]) clocks++;
    return clocks==8+variant;
}

static bool row(size_t *used, const char *fmt, ...)
{
    va_list ap; va_start(ap,fmt);
    int n=vsnprintf(result+*used,sizeof(result)-*used,fmt,ap);
    va_end(ap);
    if (n<0 || (size_t)n>=sizeof(result)-*used) return false;
    *used+=(size_t)n;
    return true;
}

static bool same_counters(const struct sample *a,const struct sample *b)
{
    return a->errors==b->errors && a->lun_resets==b->lun_resets &&
           a->host_resets==b->host_resets && a->aborts==b->aborts;
}

static long long writes(const struct target *t)
{
    char path[256],data[512];
    snprintf(path,sizeof(path),"/sys/class/block/%s/stat",t->parent);
    if (contents(path,data,sizeof(data))<=0) return -1;
    long long count;
    return sscanf(data,"%*u%*u%*u%*u%lld",&count)==1 ? count : -1;
}

static bool measure(void)
{
    struct target t={0};
    struct sample s[4];
    long long delay;
    unsigned guard=0, match=0, reads=0, phases=0, error=1;
    int fd=-1;
    long long low=number("/sys/class/devfreq/1d84000.ufshc/min_freq");
    long long high=number("/sys/class/devfreq/1d84000.ufshc/max_freq");
    long long avail_min=-1,avail_max=-1;
    char available[256];
    if (contents("/sys/class/devfreq/1d84000.ufshc/available_frequencies",available,sizeof(available))>0) {
        for (char *tok=strtok(available," \n"); tok; tok=strtok(NULL," \n")) {
            char *end; long long v=strtoll(tok,&end,10);
            if (v<=0 || *end) { avail_min=avail_max=-1; break; }
            if (avail_min<0 || v<avail_min) avail_min=v;
            if (v>avail_max) avail_max=v;
        }
    }
    if (!guard_disks(vm,check_only)) goto done;
    guard=1; error=2;
    int found=0;
    for (int i=0; i<45 && (found=locate(vm,&t))==0; i++) usleep(200000);
    if (found!=1) goto done;
    error=3;
    if (!verify_partition(&t,vm)) goto done;
    match=1; error=4;
    fd=open_target(&t);
    if (fd<0 || !guard_disks(vm,check_only)) goto done;
    long long baseline=writes(&t);
    snapshot(&s[phases++]); error=5;
    if (!known_read(fd,vm,&delay)) goto done;
    reads++; snapshot(&s[phases++]); s[1].read_us=delay;
    sleep(vm ? 1 : 12);
    snapshot(&s[phases++]); error=6;
    if (!known_read(fd,vm,&delay)) goto done;
    reads++; snapshot(&s[phases++]); s[3].read_us=delay;
    error=7;
    if (baseline<0 || writes(&t)!=baseline || !same_counters(s,&s[3]) || !guard_disks(vm,check_only)) goto done;
    error=0;
done:
    if (fd>=0) close(fd);
    size_t used=0;
    if (!row(&used,"UFS1 META %d %d %u %u %u %u\n",variant,vm,guard,match,reads,error) ||
        !row(&used,"UFS1 RANGE %lld %lld %lld %lld\n",low,high,avail_min,avail_max)) return false;
    for (unsigned i=0; i<phases; i++) {
        struct sample *p=&s[i];
        if (!row(&used,"UFS1 PHASE %u %lld %lld %lld %lld %lld %lld %lld %lld %lld %lld %lld %lld %lld\n",
                 i,p->runtime,p->link,p->freq,p->axi,p->unipro,p->ice,p->active_ms,p->suspended_ms,
                 p->errors,p->lun_resets,p->host_resets,p->aborts,p->read_us)) return false;
    }
    return sha256(result,used,digest);
}

static int run(void)
{
    if (mount("devtmpfs","/dev","devtmpfs",MS_NOSUID,NULL) ||
        mount("proc","/proc","proc",MS_RDONLY|MS_NOSUID|MS_NODEV|MS_NOEXEC,NULL) ||
        mount("sysfs","/sys","sysfs",MS_RDONLY|MS_NOSUID|MS_NODEV|MS_NOEXEC,NULL) || !identity()) return 1;
    (void)guard_disks(vm,check_only);
    pid_t guard=fork();
    if (guard<0) return 1;
    if (!guard) {
        for (;;) { guard_disks(vm,check_only); usleep(250000); }
    }
    (void)mount("debugfs","/sys/kernel/debug","debugfs",MS_RDONLY|MS_NOSUID|MS_NODEV|MS_NOEXEC,NULL);
    int fd=observation_port(vm);
    if (fd<0) return -fd;
    char line[100],read_cmd[24],result_cmd[24];
    snprintf(read_cmd,sizeof(read_cmd),"UFS1 READ %d",variant);
    snprintf(result_cmd,sizeof(result_cmd),"UFS1 RESULT %d",variant);
    size_t used=0;
    bool discard=false, completed=false;
    long long end=now_us()+105000000;
    while (now_us()<end) {
        struct pollfd pollfd={fd,POLLIN,0};
        if (poll(&pollfd,1,250)<=0) continue;
        char ch;
        if (read(fd,&ch,1)!=1) { usleep(50000); continue; }
        if (ch!='\n') {
            if (ch=='\r') continue;
            if (ch<' ' || ch>'~' || used==sizeof(line)-1) discard=true;
            else if (!discard) line[used++]=ch;
            continue;
        }
        line[used]=0; used=0;
        if (discard) { discard=false; continue; }
        if (!strcmp(line,"UFS1 STATUS") || (!completed && !strcmp(line,result_cmd))) {
            dprintf(fd,"UFS1 READY %d %d\n",variant,vm);
        } else if (!strcmp(line,read_cmd) || (completed && !strcmp(line,result_cmd))) {
            if (!completed && !measure()) return 3;
            completed=true;
            dprintf(fd,"UFS1 BEGIN\n%sUFS1 END %s\n",result,digest);
        } else if (completed && !strncmp(line,"UFS1 ACK ",9) && !strcmp(line+9,digest)) {
            dprintf(fd,"UFS1 RETURN\n");
            usleep(500000);
            return 0;
        }
    }
    return 4;
}

int main(void)
{
    if (getpid()!=1) return 1;
    pid_t child=fork();
    if (!child) _exit(run());
    long long end=now_us()+155000000;
    int status=0, cause=155;
    while (child>0 && now_us()<end) {
        if (waitpid(child,&status,WNOHANG)==child) {
            cause=WIFEXITED(status) ? WEXITSTATUS(status) : 6;
            break;
        }
        usleep(100000);
    }
    int console=open("/dev/console",O_WRONLY|O_NONBLOCK);
    if (console>=0) dprintf(console,"UFS1 SUPERVISOR %d\n",cause);
    int kmsg=open("/dev/kmsg",O_WRONLY|O_NONBLOCK);
    if (kmsg>=0) dprintf(kmsg,"<5>UFS1 EARLY_EXIT %d\n",cause);
    reboot(RB_AUTOBOOT);
    for (;;) pause();
}
