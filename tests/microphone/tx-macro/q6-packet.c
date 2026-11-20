// SPDX-License-Identifier: GPL-2.0-only
/* Call the real machine and CPU DAI callbacks. Inspect the outgoing APM command
 * in the guest at the send boundary, before any DSP transport would be needed.
 */
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <sound/pcm_params.h>
#include <dt-bindings/soc/qcom,gpr.h>
#include <dt-bindings/sound/qcom,q6dsp-lpass-ports.h>
#include "q6apm.h"
#include "audioreach.h"

static int observe_packet(struct q6apm *apm, const struct gpr_pkt *pkt, u32 rsp);
#define q6apm_send_cmd_sync observe_packet
#include "q6-source.inc"
#undef q6apm_send_cmd_sync

static int observe_packet(struct q6apm *apm, const struct gpr_pkt *pkt, u32 rsp)
{
	const u8 *p = (const u8 *)pkt + GPR_HDR_SIZE + APM_CMD_HDR_SIZE;
	const u8 *end = (const u8 *)pkt + pkt->hdr.pkt_size;
	u32 rate = 0, bits = 0, chans = 0, mask = 0, iface = 0, index = 0;

	if (pkt->hdr.opcode != APM_CMD_SET_CFG)
		return -EINVAL;
	while (end - p >= sizeof(struct apm_module_param_data)) {
		const struct apm_module_param_data *param = (const void *)p;
		size_t length = sizeof(*param) + param->param_size;

		if (param->module_instance_id != 0x6090 || !param->param_size || length > end - p)
			return -EINVAL;
		if (param->param_id == PARAM_ID_HW_EP_MF_CFG) {
			const struct param_id_hw_ep_mf *mf = (const void *)(param + 1);
			if (param->param_size < sizeof(*mf))
				return -EINVAL;
			rate = mf->sample_rate;
			bits = mf->bit_width;
			chans = mf->num_channels;
		} else if (param->param_id == PARAM_ID_CODEC_DMA_INTF_CFG) {
			const struct param_id_codec_dma_intf_cfg *cfg = (const void *)(param + 1);
			if (param->param_size < sizeof(*cfg))
				return -EINVAL;
			mask = cfg->active_channels_mask;
			iface = cfg->lpaif_type;
			index = cfg->intf_index;
		}
		p += length;
	}
	if (p != end || rate != 48000 || bits != 16 || chans != 2 || iface != 1 || index != 4)
		return -EINVAL;
	pr_info("TX3_PACKET rate=%u bits=%u channels=%u lpaif=%u index=%u mask=%02x\n",
		rate, bits, chans, iface, index, mask);
	return 0;
}

static const struct snd_soc_dai_ops dma_ops = { .set_channel_map = q6dma_set_channel_map };
static struct snd_soc_dai_driver driver = { .ops = &dma_ops };
static struct snd_soc_dai cpu = { .driver = &driver, .id = TX_CODEC_DMA_TX_3 };
static struct snd_soc_dai *dais[] = { &cpu };
static struct snd_soc_pcm_runtime rtd = { .dais = dais };
static struct snd_pcm_runtime runtime = { .channels = 2 };
static struct snd_pcm_substream stream = {
	.private_data = &rtd, .runtime = &runtime, .stream = SNDRV_PCM_STREAM_CAPTURE,
};
static struct q6apm_lpass_dai_data data;
static struct snd_pcm_hw_params params;
static struct q6apm_graph graph;
static const struct audioreach_module endpoint = {
	.instance_id = 0x6090, .hw_interface_type = 1, .hw_interface_idx = 4,
	.data_format = 1,
};

static int __init test_init(void)
{
	struct audioreach_module_config *cfg = &data.module_config[TX_CODEC_DMA_TX_3];
	struct device *dev;
	int ret;

	if (!of_machine_is_compatible("linux,dummy-virt"))
		return -ENODEV;
	dev = root_device_register("y700-test-q6-dma");
	if (IS_ERR(dev))
		return PTR_ERR(dev);
	cpu.dev = dev;
	dev_set_drvdata(dev, &data);
	hw_param_interval(&params, SNDRV_PCM_HW_PARAM_CHANNELS)->min = 2;
	hw_param_interval(&params, SNDRV_PCM_HW_PARAM_CHANNELS)->max = 2;
	hw_param_interval(&params, SNDRV_PCM_HW_PARAM_RATE)->min = 48000;
	hw_param_interval(&params, SNDRV_PCM_HW_PARAM_RATE)->max = 48000;
	snd_mask_set_format(hw_param_mask(&params, SNDRV_PCM_HW_PARAM_FORMAT), SNDRV_PCM_FORMAT_S16_LE);
	ret = q6dma_hw_params(&stream, &params, &cpu);
	if (ret)
		goto out;
	if (y700_priv_data.snd_prepare) {
		/* An unrelated board backend must leave the CPU mapping untouched. */
		cpu.id = PRIMARY_MI2S_RX;
		ret = y700_priv_data.snd_prepare(&stream);
		cpu.id = TX_CODEC_DMA_TX_3;
		if (ret)
			goto out;

		runtime.channels = 1;
		ret = y700_priv_data.snd_prepare(&stream);
		runtime.channels = 2;
		if (ret != -EINVAL) {
			ret = -EINVAL;
			goto out;
		}
		/* Simulate leftover state in the last of eight physical slots. */
		cfg->channel_map[7] = PCM_CHANNEL_FR;
		ret = y700_priv_data.snd_prepare(&stream);
		if (ret)
			goto out;
	}
	ret = audioreach_codec_dma_set_media_format(&graph, &endpoint, cfg);
out:
	root_device_unregister(dev);
	return ret;
}
module_init(test_init);
MODULE_DESCRIPTION("QEMU transport-free Y700 TX3 channel-map regression");
MODULE_LICENSE("GPL");
