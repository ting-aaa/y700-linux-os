#!/bin/bash
# Replay the logged response through the candidate's actual wait and read functions.
set -euo pipefail
src=$(realpath -e "${1:?compiled candidate kernel tree}")/drivers/gpu/drm/msm/adreno
tmp=$(mktemp -d)
trap 'rm -f "$tmp"/{replay.c,replay,driver.inc,protocol.inc}; rmdir "$tmp"' EXIT
sed -n '/^struct a6xx_hfi_queue_header {/,/^#define HFI_H2F_MSG_INIT/p;
        /^#define HFI_H2F_MSG_GX_BW_PERF_VOTE /,/^} __packed;/p' "$src/a6xx_hfi.h" > "$tmp/protocol.inc"
awk '/^static int a6xx_hfi_queue_read\(/ || /^static bool a6xx_hfi_vote_ack_ready\(/ ||
     /^static int a6xx_hfi_wait_for_(msg_interrupt|ack)\(/ { copy=1 }
     copy { print }
     /^}/ { copy=0 }' "$src/a6xx_hfi.c" > "$tmp/driver.inc"
cat > "$tmp/replay.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint32_t u32;
typedef int32_t s32;
typedef uint8_t u8;
typedef int spinlock_t, atomic_t;
#define __packed __attribute__((packed))
#include "protocol.inc"
struct a6xx_gmu { bool legacy; struct a6xx_hfi_queue queues[2]; };
struct a6xx_gpu { struct { bool a730; } base; struct a6xx_gmu gmu; };
#define adreno_is_a730(b) ((b)->a730)
#define container_of(p,t,m) ((t *)((char *)(p) - offsetof(t,m)))
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x,y) ((x)=(y))
#define SZ_4K 4096U
#define CIRC_CNT(w,r,s) (((w)-(r)) & ((s)-1))
#define ALIGN(n,a) (((n)+(a)-1) & ~((a)-1))
#define dma_rmb() ((void)0)
#define dma_mb() ((void)0)
#define BUG_ON(x) assert(!(x))
#define min_t(t,a,b) ((a)<(b)?(a):(b))
#define completion_done(x) true
#define wait_for_completion(x) assert(false)
#define A6XX_GMU_GMU2HOST_INTR_INFO_MSGQ 1U
static u32 irq, clears, fallbacks;
#define gmu_poll_timeout(g,r,v,ready,d,t) ((v)=irq, (ready) ? 0 : -ETIMEDOUT)
#define gmu_write(g,r,v) (clears++)
#define dev_info_ratelimited(...) (fallbacks++)
static const char *const a6xx_hfi_msg_id[256] = {0};
#define DRM_DEV_ERROR(dev,...) do { if (0) fprintf(stderr,__VA_ARGS__); } while (0)
#include "driver.inc"
int main(void)
{
    const u32 seq = 2359, head = 0x41031e, echo = 0x9370041e;
    const int timeout = -ETIMEDOUT;
    struct vector {
        const char *name;
        u32 rd, wr, size, head, echo, error, id, seq;
        bool a730, irq;
        int rc;
        u32 accepted, cleared;
    } cases[] = {
        {"on-device snapshot",16,20,1024,head,echo,0,30,seq,true,false,0,1,0},
        {"firmware error",16,20,1024,head,echo,8,30,seq,true,false,-EINVAL,1,0},
        {"last aligned entry",1020,0,1024,head,echo,0,30,seq,true,false,0,1,0},
        {"normal interrupt",16,20,1024,head,echo,0,30,seq,true,true,0,0,1},
        {"stale sequence",16,20,1024,head,echo,0,30,seq+1,true,false,timeout,0,0},
        {"wrong request",16,20,1024,head,echo,0,33,seq,true,false,timeout,0,0},
        {"other GPU",16,20,1024,head,echo,0,30,seq,false,false,timeout,0,0},
        {"empty",16,16,1024,head,echo,0,30,seq,true,false,timeout,0,0},
        {"partial write",16,18,1024,head,echo,0,30,seq,true,false,timeout,0,0},
        {"bad read index",1024,20,1024,head,echo,0,30,seq,true,false,timeout,0,0},
        {"bad write index",16,1024,1024,head,echo,0,30,seq,true,false,timeout,0,0},
        {"bad ring size",16,20,512,head,echo,0,30,seq,true,false,timeout,0,0},
        {"wrong packet type",16,20,1024,head^0x10000,echo,0,30,seq,true,false,timeout,0,0},
        {"wrong packet size",16,20,1024,head^0x100,echo,0,30,seq,true,false,timeout,0,0},
        {"wrong ACK id",16,20,1024,head^1,echo,0,30,seq,true,false,timeout,0,0},
        {"wrong echo command",16,20,1024,head,echo^1,0,30,seq,true,false,timeout,0,0},
        {"wrong echo length",16,20,1024,head,echo^0x100,0,30,seq,true,false,timeout,0,0},
    };
    for (size_t i=0; i<sizeof(cases)/sizeof(*cases); i++) {
        struct vector t = cases[i];
        struct a6xx_gpu gpu = {.base.a730=t.a730};
        struct a6xx_hfi_queue_header h = {.read_index=t.rd,.write_index=t.wr,.size=t.size};
        u32 ring[1024] = {0};
        struct a6xx_hfi_queue *q = &gpu.gmu.queues[HFI_RESPONSE_QUEUE];
        q->header = &h;
        q->data = ring;
        if (t.rd <= 1020) {
            ring[t.rd] = t.head;
            ring[t.rd+1] = t.echo;
            ring[t.rd+2] = t.error;
        }
        irq=t.irq; clears=0; fallbacks=0;
        int rc = a6xx_hfi_wait_for_ack(&gpu.gmu,t.id,t.seq,NULL,0);
        if (rc != t.rc || clears != t.cleared || fallbacks != t.accepted ||
            h.read_index != ((t.accepted || t.cleared) ? (t.rd+4)%1024 : t.rd) ||
            h.write_index != t.wr) {
            fprintf(stderr,"FAIL %s\n",t.name);
            return 1;
        }
        printf("PASS %s\n",t.name);
    }
    return 0;
}
C
cc -std=c11 -O2 -Wall -Werror -fsanitize=undefined,bounds "$tmp/replay.c" -o "$tmp/replay"
"$tmp/replay"
