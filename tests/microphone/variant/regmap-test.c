// SPDX-License-Identifier: GPL-2.0-only
/* Use the real ASoC and regmap error paths with a deterministic register backend. */
#include <linux/bitfield.h>
#include <linux/device.h>
#include <linux/module.h>
#include <linux/regmap.h>
#include <sound/soc.h>

#include "variant.inc"

struct input {
	int value;
	int reads;
};

static int read_register(void *context, unsigned int reg, unsigned int *value)
{
	struct input *input = context;

	input->reads++;
	if (reg != WCD938X_DIGITAL_EFUSE_REG_0)
		return -ERANGE;
	if (input->value < 0)
		return input->value;
	*value = input->value;
	return 0;
}

static const struct regmap_config config = {
	.reg_bits = 16, .val_bits = 8,
	.reg_read = read_register,
};

static int __init test_variant(void)
{
	static const struct { int input, original, checked; } cases[] = {
		{ 0x00, 0, 0 }, { 0xf5, 10, -ENODEV }, { 0xeb, 5, 5 },
		{ -EINVAL, 5, -EINVAL }, { -EPIPE, 0, -EPIPE },
		{ -EIO, 13, -EIO }, { -ETIMEDOUT, 9, -ETIMEDOUT },
	};
	struct snd_soc_component component = {};
	struct input input = {};
	struct regmap *map;
	struct device *dev;
	int ret, i;

	dev = root_device_register("y700-test-wcd-id");
	if (IS_ERR(dev))
		return PTR_ERR(dev);
	map = regmap_init(dev, NULL, &input, &config);
	if (IS_ERR(map)) {
		ret = PTR_ERR(map);
		goto done;
	}
	component.dev = dev;
	component.name = "Y700-memory-codec";
	component.regmap = map;
	mutex_init(&component.io_mutex);
	ret = 0;
	for (i = 0; i < ARRAY_SIZE(cases); i++) {
		int original, checked;

		input.value = cases[i].input;
		original = snd_soc_component_read_field(&component, WCD938X_DIGITAL_EFUSE_REG_0,
							WCD938X_ID_MASK);
		checked = wcd938x_read_variant(map);
		pr_info("WCD_ID_CASE input=%d original=%d checked=%d\n", input.value, original, checked);
		if (original != cases[i].original || checked != cases[i].checked ||
		    input.reads != (i + 1) * 2) {
			ret = -EINVAL;
			break;
		}
	}
	regmap_exit(map);
done:
	root_device_unregister(dev);
	if (!ret)
		pr_info("WCD_ID_MATRIX_PASS cases=%u reads=%d writes=0\n", (unsigned int)ARRAY_SIZE(cases), input.reads);
	return ret;
}
module_init(test_variant);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Memory-backed WCD938x identification regression");
