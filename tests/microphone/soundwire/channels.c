// SPDX-License-Identifier: GPL-2.0-only
/* Run the loaded WCD driver against a fresh, memory-only SoundWire bus. */
#include <linux/module.h>
#include <linux/of.h>
#include <linux/soundwire/sdw.h>
#include <sound/pcm_params.h>
#include <sound/soc.h>
#include "wcd938x.h"

static struct sdw_bus bus;
static struct sdw_dpn_prop port_props[] = { { .num = 1 }, { .num = 2 } };
static struct sdw_slave codec = {
	.bus = &bus,
	.prop = {
		.source_ports = BIT(1) | BIT(2),
		.src_dpn_prop = port_props,
		.sink_ports = BIT(1) | BIT(2),
		.sink_dpn_prop = port_props,
	},
};
static bool original;
module_param(original, bool, 0444);

static int run_case(bool capture, unsigned int first, unsigned int second)
{
	struct snd_pcm_hw_params params = {};
	struct snd_interval *rate = hw_param_interval(&params, SNDRV_PCM_HW_PARAM_RATE);
	struct wcd938x_sdw_priv wcd = {
		.sdev = &codec,
		.is_tx = capture,
		.port_config = { { .num = 1, .ch_mask = first }, { .num = 2, .ch_mask = second } },
	};
	unsigned int active = hweight32(first) + hweight32(second);
	unsigned int count, ports = !!first + !!second;
	int ret;

	rate->min = rate->max = 48000;
	wcd.sruntime = sdw_alloc_stream("Y700 WCD channel count", SDW_STREAM_PCM);
	if (!wcd.sruntime)
		return -ENOMEM;

	ret = wcd938x_sdw_hw_params(&wcd, NULL, &params, NULL);
	if (!ret) {
		count = wcd.sruntime->params.ch_count;
		pr_info("WCD_SDW channels=%u first=%u second=%u rate=%u ports=%d capture=%d original=%d\n",
			count, first, second, wcd.sruntime->params.rate, wcd.active_ports, capture, original);
		if (count != active + original || wcd.sconfig.ch_count != count ||
		    wcd.active_ports != ports || wcd.sruntime->params.rate != 48000 ||
		    wcd.sconfig.direction != (capture ? SDW_DATA_DIR_TX : SDW_DATA_DIR_RX))
			ret = -EINVAL;
	}
	wcd938x_sdw_free(&wcd, NULL, NULL);
	sdw_stream_remove_master(&bus, wcd.sruntime);
	sdw_release_stream(wcd.sruntime);
	if (bus.stream_refcount || !list_empty(&bus.m_rt_list))
		return -EINVAL;
	return ret;
}

static int __init check_channels(void)
{
	int ret;

	if (!of_machine_is_compatible("linux,dummy-virt"))
		return -ENODEV;
	mutex_init(&bus.bus_lock);
	INIT_LIST_HEAD(&bus.m_rt_list);
	/* ADC1 + ADC3 are the two data-port bit-zero channels on this board. */
	ret = run_case(true, 1, 1);
	if (!ret)
		ret = run_case(true, 0, 1);
	if (!ret)
		ret = run_case(true, 1, 0);
	if (!ret)
		ret = run_case(true, 0, 0);
	if (!ret)
		ret = run_case(false, 3, 0);
	return ret;
}

static void __exit finish(void) { }
module_init(check_channels);
module_exit(finish);
MODULE_DESCRIPTION("Check WCD938x stream channel accounting on a virtual bus");
MODULE_LICENSE("GPL");
