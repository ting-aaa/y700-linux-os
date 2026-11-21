/* SPDX-License-Identifier: MIT */
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static void require(int ok, const char *why)
{
	if (!ok) { perror(why); exit(1); }
}
static int read_number(const char *path)
{
	FILE *f = fopen(path, "r");
	int value;
	require(f && fscanf(f, "%d", &value) == 1, path);
	fclose(f);
	return value;
}
static int number(const char *key)
{
	char path[128];
	snprintf(path, sizeof(path), "/sys/module/adapter/parameters/%s", key);
	return read_number(path);
}
static void syswrite(const char *path, const char *value)
{
	int fd = open(path, O_WRONLY);
	require(fd >= 0 && write(fd, value, strlen(value)) == (ssize_t)strlen(value), path);
	close(fd);
}
static int set(int fd, int value)
{
	struct v4l2_control c = { .id = V4L2_CID_FOCUS_ABSOLUTE, .value = value };
	return ioctl(fd, VIDIOC_S_CTRL, &c);
}
int main(int argc, char **argv)
{
	require(argc == 4 || argc == 5, "expected node, I2C device name and VAF use count path");
	const char *node = argv[1], *device = argv[2];
	const char *vaf = argv[3];
	int baseline = read_number(vaf);
	const char *fault = "/sys/module/adapter/parameters/fault";
	if (argc == 5) {
		int fd = open(node, O_RDWR);
		require(fd >= 0 && set(fd, 228) == 0, "supplier test set");
		int before = number("writes");
		syswrite("/sys/bus/i2c/drivers/test-hi1339/unbind", argv[4]);
		require(number("resumes") == number("suspends") && read_number(vaf) == baseline &&
			number("writes") == before, "supplier unbind power");
		require(set(fd, 150) == -1 && errno == ENODEV, "supplier unbind stale fd");
		close(fd);
		puts("LENS_PASS supplier_unbind=consumer_off no_park=1 old_fd_rejected=1");
		return 0;
	}
	int opens = number("resumes");
	int fd = open(node, O_RDWR), second = open(node, O_RDONLY);
	require(fd >= 0 && second >= 0, "open lens");
	struct v4l2_query_ext_ctrl q = { .id = V4L2_CID_FOCUS_ABSOLUTE };
	require(ioctl(fd, VIDIOC_QUERY_EXT_CTRL, &q) == 0, "query control");
	struct v4l2_control readback = { .id = q.id };
	require(ioctl(fd, VIDIOC_G_CTRL, &readback) == 0 && readback.value == 128, "cached control");
	require(q.minimum == 128 && q.maximum == 512 && q.default_value == 128 &&
		q.step == 1 && (q.flags & V4L2_CTRL_FLAG_EXECUTE_ON_WRITE), "factory calibration");
	close(fd);
	close(second);
	usleep(250000);
	require(number("id_count") == 1 && number("af_count") == 1 &&
		opens == number("resumes") && number("writes") == 0 && opens == number("suspends") &&
		read_number(vaf) == baseline,
		"metadata changed power or position");
	puts("LENS_PASS probe=ID+CRC+range open_query_get_close=1 idle_ms=250 writes=0 power_returned=1");
	fd = open(node, O_RDWR);
	second = open(node, O_RDONLY);
	require(fd >= 0 && second >= 0, "reopen for moves");
	require(set(fd, 128) == 0 && number("moves") == 1 && number("last") == 128, "default set");
	require(set(fd, 321) == 0 && number("writes") == 5 && number("last") == 321, "second set");
	close(second);
	require(number("resumes") == number("suspends")+1 && read_number(vaf) == baseline+1,
		"intermediate close lost power");
	close(fd);
	require(number("resumes") == number("suspends") && number("writes") == 5 &&
		read_number(vaf) == baseline, "last close");
	puts("LENS_PASS first_equal_default=1 two_clients=1 init_order=1 VAF_use_count=restored close_writes=0");
	fd = open(node, O_RDWR);
	require(fd >= 0, "reopen");
	syswrite(fault, "3");
	require(set(fd, 260) == -1 && errno == ETIMEDOUT && number("moves") == 2, "busy timeout");
	syswrite(fault, "4");
	require(set(fd, 260) == -1 && errno == EIO && number("moves") == 2, "write fault");
	syswrite(fault, "0");
	require(set(fd, 512) == 0 && number("last") == 512, "retry after failure");
	/* The V4L2 integer core may normalize a request to its advertised limits. */
	int ret = set(fd, 721);
	require(((ret == -1 && errno == ERANGE) || (ret == 0 && number("last") == 512)) &&
		number("bad_dac") == 0,
		"outside factory range");
	int before = number("writes");
	syswrite("/sys/bus/i2c/drivers/asphalt-gt9768/unbind", device);
	require(number("resumes") == number("suspends") && number("writes") == before, "unbinding");
	require(set(fd, 150) == -1 && errno == ENODEV, "stale fd");
	int retry = open("/sys/bus/i2c/drivers/asphalt-gt9768/bind", O_WRONLY);
	require(retry >= 0 && write(retry, device, strlen(device)) == -1 && errno == EBUSY,
		"old subdevice still open during rebind");
	close(retry);
	close(fd);
	puts("LENS_PASS timeout=1 transfer_error=1 recovery=1 limits=1 live_fd_unbind=1");
	return 0;
}
