/* Create RAM-only ALSA user controls on the VM's snd-dummy card. No PCM opens. */
#include <err.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <sound/asound.h>
#include <sound/tlv.h>

static int card;

static void control(const char *prefix, const char *name, int type, int max,
                    const char *choices, size_t length, int count, int digital)
{
    struct snd_ctl_elem_info info = { .type = type, .count = 1 };
    info.id.iface = SNDRV_CTL_ELEM_IFACE_MIXER;
    if (snprintf((char *)info.id.name, sizeof(info.id.name), "%s%s", prefix, name)
            >= (int)sizeof(info.id.name))
        errx(1, "Long control name");
    info.access = SNDRV_CTL_ELEM_ACCESS_READWRITE;
    if (digital)
        info.access |= SNDRV_CTL_ELEM_ACCESS_TLV_WRITE;
    if (type == SNDRV_CTL_ELEM_TYPE_ENUMERATED) {
        info.value.enumerated.items = count;
        info.value.enumerated.names_ptr = (uintptr_t)choices;
        info.value.enumerated.names_length = length;
    } else {
        info.value.integer.max = max;
    }
    if (ioctl(card, SNDRV_CTL_IOCTL_ELEM_ADD, &info) < 0)
        err(1, "Add %s", info.id.name);
    if (digital) {
        struct { unsigned int numid, length, tlv[4]; } db = {
            info.id.numid, 16, { SNDRV_CTL_TLVT_DB_SCALE, 8, (unsigned int)-10225, 25 | 0x10000 }
        };
        if (ioctl(card, SNDRV_CTL_IOCTL_TLV_WRITE, &db) < 0)
            err(1, "Set TLV");
    }
}

#define BOOL(p, n) control(p, n, SNDRV_CTL_ELEM_TYPE_BOOLEAN, 1, NULL, 0, 0, 0)
#define ENUM(p, n, s, c) control(p, n, SNDRV_CTL_ELEM_TYPE_ENUMERATED, 0, s, sizeof(s), c, 0)

int main(void)
{
    struct snd_ctl_card_info identity;
    card = open("/dev/snd/controlC0", O_RDWR);
    if (card < 0 || ioctl(card, SNDRV_CTL_IOCTL_CARD_INFO, &identity) < 0)
        err(1, "Read card identity");
    if (strcmp((char *)identity.driver, "Dummy") || strcmp((char *)identity.id, "Y700Dummy"))
        errx(1, "Requires the private Y700Dummy virtual card");
    BOOL("", "PRIMARY_MI2S_RX Audio Mixer MultiMedia1");
    for (int i = 1; i <= 2; i++) {
        const char *p = i == 1 ? "SPK1 " : "SPK2 ";
        BOOL(p, "AMP Enable Switch");
        BOOL(p, "DSP1 Preload Switch");
        ENUM(p, "Amplifier Mode", "SPK\0RCV", 2);
        ENUM(p, "DSP1 Firmware", "Unselected\0Protection", 2);
        control(p, "Analog PCM Volume", SNDRV_CTL_ELEM_TYPE_INTEGER, 3, NULL, 0, 0, 0);
        control(p, "Digital PCM Volume", SNDRV_CTL_ELEM_TYPE_INTEGER, 457, NULL, 0, 0, 1);
        ENUM(p, "DACPCM Source", "Zero\0ASP_RX1\0ASP_RX2\0DSP_TX1\0DSP_TX2", 5);
        for (int j = 1; j <= 8; j++) {
            char name[24];
            snprintf(name, sizeof(name), "DSP_RX%d Source", j);
            ENUM(p, name, "Zero\0ASP_RX1\0ASP_RX2\0VMON\0IMON\0ERR_VOL\0CLASSH_TGT\0VDD_BATTMON\0VDD_BSTMON\0TEMPMON", 10);
        }
    }
    return close(card) < 0;
}
