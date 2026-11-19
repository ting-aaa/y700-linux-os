#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/module.h>
#include <linux/of.h>

/* Only register the name that the board udev rules match. The virtual sensor
 * data itself travels over QRTR. This fixture implements no FastRPC ioctls. */
static int reject_open(struct inode *inode, struct file *file)
{
    return -ENODEV;
}

static const struct file_operations operations = {
    .owner = THIS_MODULE,
    .open = reject_open,
};

static struct miscdevice fixture = {
    .minor = MISC_DYNAMIC_MINOR,
    .name = "fastrpc-sdsp",
    .fops = &operations,
};

static int __init fixture_init(void)
{
    if (!of_machine_is_compatible("linux,dummy-virt"))
        return -ENODEV;
    return misc_register(&fixture);
}

static void __exit fixture_exit(void)
{
    misc_deregister(&fixture);
}

module_init(fixture_init);
module_exit(fixture_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("QEMU-only SDSP device for Y700 SSC desktop regression tests");
