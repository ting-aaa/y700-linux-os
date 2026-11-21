// SPDX-License-Identifier: GPL-2.0-only
/* Diskless QEMU only. The module supplies the bus and receiver, not a lens. */
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/pm_runtime.h>
#include <media/v4l2-device.h>
#include <media/v4l2-async.h>

static struct i2c_adapter bus;
static struct v4l2_subdev sensor;
static struct media_device media;
static struct v4l2_device video;
static struct v4l2_async_notifier notifier;
static unsigned int id_count, af_count, writes, moves, last, bad_dac, init_step, resumes, suspends;
static int fault;
#define COUNT(n) module_param(n, uint, 0444)
COUNT(id_count); COUNT(af_count); COUNT(writes); COUNT(moves); COUNT(last);
COUNT(bad_dac); COUNT(init_step); COUNT(resumes); COUNT(suspends);
module_param(fault, int, 0644);

static int xfer(struct i2c_adapter *a, struct i2c_msg *m, int n)
{
	/* Two synthetic DAC endpoints 128 and 512; CRC-16/UMTS big endian. */
	static const u8 calibration[] = { 1, 0x20, 0, 0x80, 0, 3, 4, 5, 6, 0x24, 0x60 };
	static const u8 init[][2] = {{ 2, 2 }, { 6, 0x60 }, { 7, 1 }};
	u8 *v = m[0].buf;

	if (resumes <= suspends)
		return -EHOSTDOWN;
	if (n == 2 && !m[0].flags && m[1].flags == I2C_M_RD && m[1].addr == m[0].addr) {
		if (m[0].addr == 0x58 && m[0].len == 2 && !v[0] && v[1] == 0x27 && m[1].len == 11) {
			af_count++;
			memcpy(m[1].buf, calibration, 11);
			if (fault == 1)
				m[1].buf[10] ^= 1;
			if (fault == 5) {
				m[1].buf[1] = 0x80;
				m[1].buf[3] = 0x20;
				m[1].buf[9] = 0x27;
				m[1].buf[10] = 0x36;
			}
			return n;
		}
		if (m[0].addr != 12 || m[0].len != 1 || m[1].len != 1)
			return -EINVAL;
		if (v[0] == 0) {
			id_count++;
			m[1].buf[0] = fault == 2 ? 0 : 0xe9;
			return n;
		}
		if (v[0] == 5) {
			m[1].buf[0] = fault == 3;
			return n;
		}
	}
	if (n == 1 && m[0].addr == 12 && !m[0].flags) {
		writes++;
		if (m[0].len == 2 && init_step < 3 && !memcmp(v, init[init_step], 2)) {
			init_step++;
			return n;
		}
		if (m[0].len == 3 && init_step == 3 && v[0] == 3) {
			if (fault == 4)
				return -EIO;
			last = (v[1] << 8) | v[2];
			if (last < 128 || last > 512) {
				bad_dac++;
				return -ERANGE;
			}
			moves++;
			return n;
		}
	}
	return -EOPNOTSUPP;
}
static u32 functionality(struct i2c_adapter *a) { return I2C_FUNC_I2C; }
static const struct i2c_algorithm algo = { .xfer = xfer, .functionality = functionality };

static int sensor_on(struct device *d) { resumes++; init_step = 0; return 0; }
static int sensor_off(struct device *d) { suspends++; return 0; }
static const struct dev_pm_ops sensor_pm = { SET_RUNTIME_PM_OPS(sensor_off, sensor_on, NULL) };
static const struct v4l2_subdev_ops sd_ops = {};
static int sensor_probe(struct i2c_client *c)
{
	v4l2_i2c_subdev_init(&sensor, c, &sd_ops);
	sensor.entity.function = MEDIA_ENT_F_CAM_SENSOR;
	v4l2_i2c_subdev_set_name(&sensor, c, "fake-hi1339", NULL);
	pm_runtime_enable(&c->dev);
	return v4l2_async_register_subdev_sensor(&sensor);
}
static void sensor_remove(struct i2c_client *c)
{
	v4l2_async_unregister_subdev(&sensor);
	pm_runtime_disable(&c->dev);
}
static const struct of_device_id sensor_ids[] = { { .compatible = "test,hi1339" }, {} };
static struct i2c_driver sensor_driver = {
	.driver = { .name = "test-hi1339", .of_match_table = sensor_ids, .pm = &sensor_pm },
	.probe = sensor_probe, .remove = sensor_remove,
};

static int graph_complete(struct v4l2_async_notifier *n)
{
	return v4l2_device_register_subdev_nodes(&video);
}
static const struct v4l2_async_notifier_operations nf_ops = { .complete = graph_complete };

static int probe(struct platform_device *p)
{
	struct v4l2_async_connection *asc;
	struct device_node *s = of_get_child_by_name(p->dev.of_node, "camera");
	int ret;

	if (!s)
		return -EINVAL;
	media.dev = &p->dev;
	strscpy(media.model, "GT9768 QEMU receiver");
	media_device_init(&media);
	video.mdev = &media;
	ret = v4l2_device_register(&p->dev, &video);
	if (ret)
		return ret;
	ret = media_device_register(&media);
	if (ret)
		return ret;
	v4l2_async_nf_init(&notifier, &video);
	notifier.ops = &nf_ops;
	asc = v4l2_async_nf_add_fwnode(&notifier, of_fwnode_handle(s), struct v4l2_async_connection);
	of_node_put(s);
	if (IS_ERR(asc))
		return PTR_ERR(asc);
	ret = v4l2_async_nf_register(&notifier);
	if (ret)
		return ret;
	bus.owner = THIS_MODULE;
	bus.algo = &algo;
	bus.dev.parent = &p->dev;
	bus.dev.of_node = p->dev.of_node;
	strscpy(bus.name, "RAM-only GT9768");
	return i2c_add_adapter(&bus);
}
static const struct of_device_id ids[] = { { .compatible = "test,gt9768-adapter" }, {} };
static struct platform_driver pdrv = {
	.driver = { .name = "qa-gt9768-bus", .of_match_table = ids }, .probe = probe,
};
static int __init start(void)
{
	int ret = i2c_add_driver(&sensor_driver);

	return ret ? ret : platform_driver_register(&pdrv);
}
module_init(start);
MODULE_DESCRIPTION("Diskless GT9768 camera module test bus");
MODULE_LICENSE("GPL");
