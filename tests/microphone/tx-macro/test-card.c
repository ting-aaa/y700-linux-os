// SPDX-License-Identifier: GPL-2.0-only
/* Virtual card to exercise the real SM8450 TX macro on RAM-backed registers. */
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <sound/control.h>
#include <sound/soc.h>

#define PATH_CTL(dec) (0x400 + 0x80 * (dec))
#define PGA_MUTE BIT(4)

static struct snd_soc_dai_link_component codec = { .dai_name = "tx_macro_tx1" };
static struct snd_soc_dai_link link = {
	.name = "TX macro capture", .stream_name = "TX macro capture",
	.cpus = &snd_soc_dummy_dlc, .num_cpus = 1,
	.platforms = &snd_soc_dummy_dlc, .num_platforms = 1,
	.codecs = &codec, .num_codecs = 1,
};

static int set_route(struct snd_soc_card *card, unsigned int dec, bool on)
{
	struct snd_ctl_elem_value control = {};
	struct snd_kcontrol *kcontrol;
	char name[44];

	snprintf(name, sizeof(name), "TX_AIF1_CAP Mixer DEC%u", dec);
	kcontrol = snd_soc_card_get_kcontrol(card, name);
	if (!kcontrol)
		return -ENOENT;

	control.value.integer.value[0] = on;
	return kcontrol->put(kcontrol, &control);
}

/* Bits set in this mask identify the physical register fields left unmuted. */
static unsigned int unmuted_paths(struct snd_soc_component *component)
{
	unsigned int mask = 0;
	unsigned int i;

	for (i = 0; i < 8; i++)
		if (!(snd_soc_component_read(component, PATH_CTL(i)) & PGA_MUTE))
			mask |= BIT(i);

	return mask;
}

static int check_paths(struct snd_soc_card *card)
{
	struct snd_soc_pcm_runtime *rtd = snd_soc_get_pcm_runtime(card, &link);
	struct snd_soc_dai *dai;
	unsigned int mask = 0, count = 0, unmute, mute, i;
	int duplicate, last;
	unsigned int both_mask, both_count;

	if (!rtd)
		return -ENODEV;
	dai = snd_soc_rtd_to_codec(rtd, 0);

	for (i = 0; i < 8; i++)
		if (snd_soc_component_update_bits(dai->component, PATH_CTL(i),
						  PGA_MUTE, PGA_MUTE) < 0)
			return -EIO;
	if (set_route(card, 2, true) != 1 || set_route(card, 5, true) != 1)
		return -EINVAL;
	duplicate = set_route(card, 2, true);
	if (snd_soc_dai_get_channel_map(dai, &both_count, &both_mask, NULL, NULL) ||
	    snd_soc_dai_digital_mute(dai, 0, SNDRV_PCM_STREAM_CAPTURE))
		return -EINVAL;
	unmute = unmuted_paths(dai->component);
	if (snd_soc_dai_digital_mute(dai, 1, SNDRV_PCM_STREAM_CAPTURE))
		return -EINVAL;
	mute = unmuted_paths(dai->component);
	if (set_route(card, 5, false) != 1)
		return -EINVAL;
	last = set_route(card, 2, false);
	if (snd_soc_dai_get_channel_map(dai, &count, &mask, NULL, NULL))
		return -EINVAL;
	dev_info(card->dev,
		 "TX_STEREO initial=%02x/%u duplicate=%d unmuted=%02x after_mute=%02x last_disable=%d final=%02x/%u\n",
		 both_mask, both_count, duplicate, unmute, mute, last, mask, count);

	/* Reopen, release the other input first, and exercise mono on DEC5. */
	if (set_route(card, 5, true) < 0 || set_route(card, 2, true) < 0 ||
	    set_route(card, 2, false) < 0 ||
	    snd_soc_dai_get_channel_map(dai, &both_count, &both_mask, NULL, NULL) ||
	    snd_soc_dai_digital_mute(dai, 0, SNDRV_PCM_STREAM_CAPTURE))
		return -EINVAL;
	unmute = unmuted_paths(dai->component);
	if (snd_soc_dai_digital_mute(dai, 1, SNDRV_PCM_STREAM_CAPTURE) ||
	    set_route(card, 5, false) < 0 ||
	    snd_soc_dai_get_channel_map(dai, &count, &mask, NULL, NULL))
		return -EINVAL;
	dev_info(card->dev, "TX_REOPEN single=%02x/%u unmuted=%02x final=%02x/%u\n",
		 both_mask, both_count, unmute, mask, count);
	return 0;
}

static struct snd_soc_card test_card = {
	.name = "Y700-TX-test", .owner = THIS_MODULE,
	.dai_link = &link, .num_links = 1,
};

static int test_probe(struct platform_device *pdev)
{
	struct device_node *np __free(device_node) =
		of_find_compatible_node(NULL, NULL, "qcom,sm8450-lpass-tx-macro");
	int ret;

	if (!of_machine_is_compatible("linux,dummy-virt") || !np)
		return -ENODEV;
	codec.of_node = np;
	test_card.dev = &pdev->dev;
	ret = devm_snd_soc_register_card(&pdev->dev, &test_card);
	if (ret)
		return ret;
	if (!test_card.instantiated)
		return -EPROBE_DEFER;
	return check_paths(&test_card);
}

static const struct of_device_id test_ids[] = {
	{ .compatible = "test,y700-tx-macro" }, {}
};
static struct platform_driver test_driver = {
	.probe = test_probe,
	.driver = { .name = "y700-tx-macro-test", .of_match_table = test_ids },
};
module_platform_driver(test_driver);
MODULE_DESCRIPTION("QEMU regression card for LPASS TX capture routes");
MODULE_LICENSE("GPL");
