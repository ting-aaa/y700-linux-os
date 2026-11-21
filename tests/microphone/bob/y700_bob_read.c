// SPDX-License-Identifier: GPL-2.0-only
/* One uncached read of the APPS resource setting. This does not measure VOUT. */
#include <linux/bitfield.h>
#include <linux/device.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <soc/qcom/cmd-db.h>
#include <soc/qcom/rpmh.h>
#include <soc/qcom/tcs.h>

#define APPS_PMIC "/soc@0/rsc@17a00000/regulators-1"

static unsigned int apps_mv;
static const struct kernel_param_ops sample_ops = { .get = param_get_uint };
module_param_cb(apps_mv, &sample_ops, &apps_mv, 0444);
MODULE_PARM_DESC(apps_mv, "APPS bobc1 voltage resource readback, millivolts");

static bool property_is(const struct device_node *np, const char *key,
			const char *expected)
{
	const char *value;

	return !of_property_read_string(np, key, &value) && !strcmp(value, expected);
}

static int __init bob_observe_init(void)
{
	struct device_node *pmic, *bob;
	struct platform_device *pdev = NULL;
	struct device *dev, *rsc;
	struct tcs_cmd cmd = {};
	int ret = -ENODEV;

	if (!of_machine_is_compatible("lenovo,asphalt") ||
	    !of_machine_is_compatible("qcom,sm8475") ||
	    !property_is(of_root, "region_country", "PRC"))
		return -ENODEV;

	pmic = of_find_node_by_path(APPS_PMIC);
	if (!pmic)
		return -ENODEV;
	bob = of_get_child_by_name(pmic, "bob");
	if (bob && of_device_is_available(bob) && of_device_is_available(pmic) &&
	    of_device_is_compatible(pmic, "qcom,pm8350c-rpmh-regulators") &&
	    property_is(pmic, "qcom,pmic-id", "c"))
		pdev = of_find_device_by_node(pmic);
	of_node_put(bob);
	of_node_put(pmic);
	if (!pdev)
		return -ENODEV;
	dev = &pdev->dev;
	rsc = dev->parent;
	if (!rsc || !of_device_is_compatible(rsc->of_node, "qcom,rpmh-rsc") ||
	    !property_is(rsc->of_node, "label", "apps_rsc"))
		goto put;

	ret = -EBUSY;
	if (!device_trylock(rsc))
		goto put;
	if (!device_trylock(dev))
		goto unlock_parent;

	ret = -ENODEV;
	if (!rsc->driver || strcmp(rsc->driver->name, "rpmh") ||
	    !dev_get_drvdata(rsc) || !dev->driver ||
	    strcmp(dev->driver->name, "qcom-rpmh-regulator") ||
	    !device_is_bound(dev) || !device_is_bound(rsc))
		goto unlock;

	cmd.addr = cmd_db_read_addr("bobc1");
	if (cmd.addr != 0x40300 || cmd_db_read_slave_id("bobc1") != CMD_DB_HW_VRM)
		goto unlock;
	/* The provider's VOLTAGE offset is zero; other offsets are never read. */
	ret = rpmh_read(dev, &cmd);
	if (!ret)
		apps_mv = FIELD_GET(GENMASK(12, 0), cmd.data);
unlock:
	device_unlock(dev);
unlock_parent:
	device_unlock(rsc);
put:
	put_device(dev);
	return ret;
}

static void __exit bob_observe_exit(void)
{
}

module_init(bob_observe_init);
module_exit(bob_observe_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("TB320FC PRC bobc1 APPS voltage readback");
