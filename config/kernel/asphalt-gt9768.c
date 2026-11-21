// SPDX-License-Identifier: GPL-2.0-only
/* TB320FC CN350 TXD rear module. Only an explicit control write drives the VCM. */
#include <linux/delay.h>
#include <linux/i2c.h>
#include <linux/iopoll.h>
#include <linux/kref.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/pm_runtime.h>
#include <linux/regulator/consumer.h>
#include <linux/unaligned.h>
#include <media/v4l2-ctrls.h>
#include <media/v4l2-device.h>

struct gt9768 {
	struct i2c_client *client;
	struct device *sensor;
	struct regulator *vaf;
	struct v4l2_ctrl_handler controls;
	struct kref refs;
	unsigned int opened;
	u16 infinity, macro;
	bool online, powered, initialized, sleeping;
};

/* This board has one TXD rear assembly. Keep the subdev header resident while
 * old video_device references drain, including the core's final devnode clear.
 * Its per-binding resources and control handler have independent lifetimes.
 */
static struct v4l2_subdev lens_sd;
static struct gt9768 *slot;
static DEFINE_MUTEX(slot_lock);
static DEFINE_MUTEX(focus_lock);

static int gt_calibration(const u8 data[11], u16 *infinity, u16 *macro)
{
	u16 crc = 0;
	int i, bit;

	for (i = 0; i < 9; i++) {
		crc ^= data[i] << 8;
		for (bit = 0; bit < 8; bit++)
			crc = (crc << 1) ^ ((crc & 0x8000) ? 0x8005 : 0);
	}
	if (crc != get_unaligned_be16(data + 9))
		return -EBADMSG;
	*infinity = get_unaligned_be16(data + 1) >> 6;
	*macro = get_unaligned_be16(data + 3) >> 6;
	return *infinity < *macro ? 0 : -ERANGE;
}

static int gt_read(struct i2c_client *c, u8 *addr, u16 alen, u8 *data, u16 len)
{
	struct i2c_msg msgs[] = {
		{ .addr = c->addr, .len = alen, .buf = addr },
		{ .addr = c->addr, .flags = I2C_M_RD, .len = len, .buf = data },
	};
	int ret = i2c_transfer(c->adapter, msgs, ARRAY_SIZE(msgs));

	return ret == ARRAY_SIZE(msgs) ? 0 : (ret < 0 ? ret : -EIO);
}

static int gt_read_byte(struct i2c_client *c, u8 reg)
{
	u8 value;
	int ret = gt_read(c, &reg, 1, &value, 1);

	return ret ? ret : value;
}

static int gt_send(struct i2c_client *c, const u8 *data, size_t len)
{
	int ret = i2c_master_send(c, data, len);

	return ret == len ? 0 : (ret < 0 ? ret : -EIO);
}

static int gt_power_on(struct gt9768 *g)
{
	int ret;

	if (g->powered)
		return 0;
	/* Use the entire measured sensor sequence, including the LDO5 vote. */
	ret = pm_runtime_resume_and_get(g->sensor);
	if (ret < 0)
		return ret;
	ret = regulator_enable(g->vaf);
	if (ret) {
		pm_runtime_put_sync(g->sensor);
		return ret;
	}
	g->powered = true;
	return 0;
}

static int gt_power_off(struct gt9768 *g)
{
	int ret;

	g->initialized = false;
	if (!g->powered)
		return 0;
	ret = regulator_disable(g->vaf);
	if (ret) {
		dev_err(&g->client->dev, "could not release VAF: %d\n", ret);
		return ret;
	}
	fsleep(1000);
	g->powered = false;
	ret = pm_runtime_put_sync(g->sensor);
	return ret < 0 ? ret : 0;
}

static int gt_identify(struct gt9768 *g, struct i2c_client *eeprom)
{
	u8 addr[] = { 0, 0x27 }, data[11];
	int ret = gt_read_byte(g->client, 0);

	if (ret != 0xe9)
		return ret < 0 ? ret : -ENODEV;
	ret = gt_read(eeprom, addr, sizeof(addr), data, sizeof(data));
	if (ret)
		return ret;
	return gt_calibration(data, &g->infinity, &g->macro);
}

static int gt_set_focus(struct v4l2_ctrl *ctrl)
{
	static const u8 init[][2] = { { 0x02, 0x02 }, { 0x06, 0x60 }, { 0x07, 0x01 } };
	struct gt9768 *g = container_of(ctrl->handler, struct gt9768, controls);
	u8 move[] = { 0x03, ctrl->val >> 8, ctrl->val };
	int i, ret, busy;

	if (!g->online || !g->opened)
		return -ENODEV;
	if (g->sleeping)
		return -EBUSY;
	if (ctrl->id != V4L2_CID_FOCUS_ABSOLUTE ||
	    ctrl->val < g->infinity || ctrl->val > g->macro)
		return -ERANGE;
	ret = gt_power_on(g);
	if (ret)
		return ret;
	if (!g->initialized) {
		for (i = 0; i < ARRAY_SIZE(init); i++) {
			ret = gt_send(g->client, init[i], sizeof(init[i]));
			if (ret)
				goto fail;
			fsleep(100);
		}
		g->initialized = true;
	}
	ret = read_poll_timeout(gt_read_byte, busy, busy <= 0, 200, 5000, false,
				g->client, 0x05);
	if (!ret && busy < 0)
		ret = busy;
	if (ret)
		goto fail;
	ret = gt_send(g->client, move, sizeof(move));
	/* Even an ambiguous transfer completion may have reached the actuator. */
	fsleep(7000);
	if (!ret)
		return 0;
fail:
	gt_power_off(g);
	return ret;
}

static int gt_open(struct v4l2_subdev *sd, struct v4l2_subdev_fh *fh)
{
	int ret = 0;

	mutex_lock(&focus_lock);
	if (slot->online)
		slot->opened++;
	else
		ret = -ENODEV;
	mutex_unlock(&focus_lock);
	return ret;
}

static int gt_close(struct v4l2_subdev *sd, struct v4l2_subdev_fh *fh)
{
	mutex_lock(&focus_lock);
	if (!--slot->opened && slot->online)
		gt_power_off(slot);
	mutex_unlock(&focus_lock);
	return 0;
}

static void gt_free(struct kref *ref)
{
	struct gt9768 *g = container_of(ref, struct gt9768, refs);

	mutex_lock(&slot_lock);
	media_entity_cleanup(&lens_sd.entity);
	v4l2_ctrl_handler_free(&g->controls);
	slot = NULL;
	kfree(g);
	mutex_unlock(&slot_lock);
}

static int gt_registered(struct v4l2_subdev *sd)
{
	kref_get(&slot->refs);
	return 0;
}

static void gt_released(struct v4l2_subdev *sd)
{
	kref_put(&slot->refs, gt_free);
}

static void gt_unregistered(struct v4l2_subdev *sd)
{
	struct media_device *mdev = sd->entity.graph_obj.mdev;
	struct media_link *link, *next;

	if (!mdev)
		return;
	/* An ancillary link is owned by the primary entity alone on 7.3.4.
	 * Removing the lens while its primary remains must retire that link.
	 */
	mutex_lock(&mdev->graph_mutex);
	list_for_each_entry_safe(link, next, &mdev->links, graph_obj.list) {
		if ((link->flags & MEDIA_LNK_FL_LINK_TYPE) != MEDIA_LNK_FL_ANCILLARY_LINK ||
		    link->gobj1 != &sd->entity.graph_obj)
			continue;
		list_del(&link->list);
		media_gobj_destroy(&link->graph_obj);
		kfree(link);
	}
	mutex_unlock(&mdev->graph_mutex);
}

static const struct v4l2_subdev_internal_ops gt_internal = {
	.open = gt_open, .close = gt_close, .registered = gt_registered,
	.unregistered = gt_unregistered, .release = gt_released,
};
static const struct v4l2_subdev_ops gt_subdev_ops = {};
static const struct v4l2_ctrl_ops gt_ctrl_ops = { .s_ctrl = gt_set_focus };

static struct i2c_client *gt_find_sensor(struct i2c_client *client)
{
	struct device_node *bus = of_get_parent(client->dev.of_node);
	struct i2c_client *sensor = NULL;

	for_each_available_child_of_node_scoped(bus, node) {
		struct device_node *lens;

		if (!of_device_is_compatible(node, "hynix,hi1339"))
			continue;
		lens = of_parse_phandle(node, "lens-focus", 0);
		if (lens == client->dev.of_node)
			sensor = of_find_i2c_device_by_node(node);
		of_node_put(lens);
		if (sensor)
			break;
	}
	of_node_put(bus);
	return sensor;
}

static int gt_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct i2c_client *sensor, *eeprom;
	struct regulator *vaf;
	struct v4l2_ctrl *focus;
	struct gt9768 *g;
	int ret, off;

	if (client->addr != 0x0c)
		return -ENODEV;
	sensor = gt_find_sensor(client);
	if (!sensor)
		return -EPROBE_DEFER;
	if (sensor->adapter != client->adapter || sensor->addr != 0x20) {
		put_device(&sensor->dev);
		return -EINVAL;
	}
	/* Supplier removal can wait on this consumer's probe. Never wait on the
	 * supplier lock in the opposite order. The sensor's V4L2 child notifier
	 * only records the pending lens; it does not wait inside sensor probe.
	 */
	if (!device_trylock(&sensor->dev)) {
		put_device(&sensor->dev);
		return -EPROBE_DEFER;
	}
	if (!device_is_bound(&sensor->dev))
		ret = -EPROBE_DEFER;
	else if (!device_link_add(dev, &sensor->dev, DL_FLAG_AUTOREMOVE_CONSUMER))
		ret = -EINVAL;
	else
		ret = 0;
	device_unlock(&sensor->dev);
	put_device(&sensor->dev);
	if (ret)
		return ret;
	/* The managed link holds the bound supplier through consumer removal. */
	vaf = devm_regulator_get(dev, "vaf");
	if (IS_ERR(vaf))
		return dev_err_probe(dev, PTR_ERR(vaf), "VAF\n");
	ret = regulator_set_load(vaf, 70000);
	if (ret)
		return ret;
	mutex_lock(&slot_lock);
	if (slot || READ_ONCE(lens_sd.devnode)) {
		mutex_unlock(&slot_lock);
		return -EBUSY;
	}
	g = kzalloc(sizeof(*g), GFP_KERNEL);
	if (!g) {
		mutex_unlock(&slot_lock);
		return -ENOMEM;
	}
	memset(&lens_sd, 0, sizeof(lens_sd));
	slot = g;
	kref_init(&g->refs);
	mutex_unlock(&slot_lock);
	g->client = client;
	g->sensor = &sensor->dev;
	g->vaf = vaf;
	v4l2_i2c_subdev_init(&lens_sd, client, &gt_subdev_ops);
	v4l2_i2c_subdev_set_name(&lens_sd, client, "gt9768", NULL);
	lens_sd.internal_ops = &gt_internal;
	lens_sd.flags |= V4L2_SUBDEV_FL_HAS_DEVNODE;
	lens_sd.entity.function = MEDIA_ENT_F_LENS;
	v4l2_ctrl_handler_init(&g->controls, 1);
	g->controls.lock = &focus_lock;
	ret = media_entity_pads_init(&lens_sd.entity, 0, NULL);
	if (ret)
		goto fail;
	/* Reserve the exact EEPROM only during the read. Never force a bound client. */
	eeprom = i2c_new_dummy_device(client->adapter, 0x58);
	if (IS_ERR(eeprom)) {
		ret = PTR_ERR(eeprom);
		goto fail;
	}
	ret = gt_power_on(g);
	if (!ret) {
		ret = gt_identify(g, eeprom);
		off = gt_power_off(g);
		if (!ret)
			ret = off;
	}
	i2c_unregister_device(eeprom);
	if (ret)
		goto fail;
	focus = v4l2_ctrl_new_std(&g->controls, &gt_ctrl_ops, V4L2_CID_FOCUS_ABSOLUTE,
				  g->infinity, g->macro, 1, g->infinity);
	if (g->controls.error) {
		ret = g->controls.error;
		goto fail;
	}
	focus->flags |= V4L2_CTRL_FLAG_EXECUTE_ON_WRITE;
	lens_sd.ctrl_handler = &g->controls;
	g->online = true;
	ret = v4l2_async_register_subdev(&lens_sd);
	if (!ret)
		return 0;
fail:
	mutex_lock(&focus_lock);
	g->online = false;
	gt_power_off(g);
	mutex_unlock(&focus_lock);
	kref_put(&g->refs, gt_free);
	return dev_err_probe(dev, ret, "rear lens registration failed\n");
}

static void gt_remove(struct i2c_client *client)
{
	struct gt9768 *g = slot;

	mutex_lock(&focus_lock);
	g->online = false;
	gt_power_off(g);
	mutex_unlock(&focus_lock);
	v4l2_async_unregister_subdev(&lens_sd);
	kref_put(&g->refs, gt_free);
}

static int gt_suspend(struct device *dev)
{
	int ret;

	mutex_lock(&focus_lock);
	ret = gt_power_off(slot);
	slot->sleeping = !ret;
	mutex_unlock(&focus_lock);
	return ret;
}

static int gt_resume(struct device *dev)
{
	mutex_lock(&focus_lock);
	slot->sleeping = false;
	mutex_unlock(&focus_lock);
	return 0;
}

static DEFINE_SIMPLE_DEV_PM_OPS(gt_pm, gt_suspend, gt_resume);

static const struct of_device_id gt_ids[] = {
	{ .compatible = "lenovo,tb320fc-gt9768" }, {}
};
MODULE_DEVICE_TABLE(of, gt_ids);
static struct i2c_driver gt_driver = {
	.driver = { .name = "asphalt-gt9768", .of_match_table = gt_ids, .pm = pm_sleep_ptr(&gt_pm) },
	.probe = gt_probe, .remove = gt_remove,
};
module_i2c_driver(gt_driver);
MODULE_DESCRIPTION("Lenovo TB320FC calibrated rear GT9768 lens");
MODULE_LICENSE("GPL");
