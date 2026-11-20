/* User controls on the guest's PCM test card only. */
#define main add_speakers
#include "speaker-controls.c"
#undef main

int main(void)
{
    if (add_speakers())
        return 1;
    card = open("/dev/snd/controlC0", O_RDWR);
    if (card < 0)
        err(1, "Open fixture card");
    ENUM("", "TX0 MODE", "ADC_NORMAL\0ADC_LP", 2);
    ENUM("", "TX2 MODE", "ADC_NORMAL\0ADC_LP", 2);
    ENUM("", "ADC3 MUX", "INP3\0INP4", 2);
    ENUM("", "HDR34 MUX", "NO_HDR34\0HDR34", 2);
    control("", "ADC1 Volume", SNDRV_CTL_ELEM_TYPE_INTEGER, 20, NULL, 0, 0, 0);
    control("", "ADC3 Volume", SNDRV_CTL_ELEM_TYPE_INTEGER, 20, NULL, 0, 0, 0);
    control("", "TX_DEC2 Volume", SNDRV_CTL_ELEM_TYPE_INTEGER, 124, NULL, 0, 0, 0);
    control("", "TX_DEC5 Volume", SNDRV_CTL_ELEM_TYPE_INTEGER, 124, NULL, 0, 0, 0);
    BOOL("", "ADC1 Switch");
    BOOL("", "ADC3 Switch");
    BOOL("", "ADC1_MIXER Switch");
    BOOL("", "ADC3_MIXER Switch");
    ENUM("", "TX DEC2 MUX", "ZERO\0SWR_MIC", 2);
    ENUM("", "TX DEC5 MUX", "ZERO\0SWR_MIC", 2);
    ENUM("", "TX SMIC MUX2", "ZERO\0SWR_MIC4", 2);
    ENUM("", "TX SMIC MUX5", "ZERO\0SWR_MIC8", 2);
    BOOL("", "TX_AIF1_CAP Mixer DEC2");
    BOOL("", "TX_AIF1_CAP Mixer DEC5");
    BOOL("", "MultiMedia3 Mixer TX_CODEC_DMA_TX_3");
    return close(card) < 0;
}
