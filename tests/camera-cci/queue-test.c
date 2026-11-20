/* Exercise the pinned driver's transfer functions against a fake CCI MMIO map. */
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef int irqreturn_t;
#define BIT(n) (1U << (n))
#define IRQ_NONE 0
#define IRQ_HANDLED 1
#define unlikely(x) (x)
#define msecs_to_jiffies(ms) (ms)
#define jiffies_to_usecs(jiffies) ((jiffies) * 1000)
#define dev_err(...) ((void)0)

#include "cci-defs.h"
#include "i2c-flags.h"

struct completion { unsigned int count; };
struct i2c_adapter { void *data; };
struct i2c_msg { u16 addr, flags, len; u8 *buf; };
struct cci_data {
	unsigned int queue_size[NUM_QUEUES];
	struct { unsigned int max_read_len; } quirks;
};
struct cci_master {
	u16 master;
	int status;
	struct completion irq_complete;
	struct cci *cci;
};
struct cci {
	void *dev, *base;
	struct cci_data *data;
	bool combined_read;
	struct cci_master master[NUM_MASTERS];
};

struct command_queue {
	unsigned int count;
	u32 words[64];
};

static struct {
	u32 registers[0xd00 / 4];
	struct command_queue queue[2][2];
	struct command_queue executed[3];
	u32 starts[3], fifo[4];
	unsigned int transfers, fifo_level, fifo_index, queue_resets, timeout_resets;
	unsigned int unlock_delay, unlock_waits, gets, puts;
	unsigned int nack_transfer;
	bool short_fifo, stuck_unlock;
	int pm_error;
} mmio;
static struct cci cci;
static struct cci_data limits;
static struct i2c_adapter adapter;

static irqreturn_t cci_isr(int irq, void *dev);

static void init(int master, bool enabled)
{
	memset(&mmio, 0, sizeof(mmio));
	limits = (struct cci_data){ .queue_size = { 64, 16 }, .quirks.max_read_len = 12 };
	cci = (struct cci){ .dev = &mmio, .base = mmio.registers, .data = &limits,
			    .combined_read = enabled };
	for (int i = 0; i < 2; i++) {
		cci.master[i].master = i;
		cci.master[i].cci = &cci;
	}
	adapter.data = &cci.master[master];
}

static void complete(struct completion *c) { c->count++; }
static void reinit_completion(struct completion *c) { c->count = 0; }

static int wait_for_completion_timeout(struct completion *c, unsigned long timeout)
{
	assert(timeout > 0);
	while (mmio.registers[0xc0c / 4])
		assert(cci_isr(0, &cci) == IRQ_HANDLED);
	if (!c->count)
		return 0;
	c->count--;
	return 1;
}

static int cci_reset(struct cci *unused)
{
	assert(unused == &cci);
	mmio.timeout_resets++;
	memset(mmio.queue, 0, sizeof(mmio.queue));
	return 0;
}

static void execute_queue(u32 start)
{
	assert(start == 1 || start == 2 || start == 4 || start == 8);
	unsigned int bit = __builtin_ctz(start);
	unsigned int m = bit / 2, q = bit % 2;
	struct command_queue *commands = &mmio.queue[m][q];
	u32 *irq = &mmio.registers[0xc0c / 4];

	assert(mmio.transfers < 3 && commands->count);
	assert(mmio.registers[(0x300 + 0x200 * m + 0x100 * q) / 4] == commands->count);
	mmio.executed[mmio.transfers] = *commands;
	mmio.starts[mmio.transfers++] = start;
	if (mmio.transfers == mmio.nack_transfer) {
		*irq |= BIT(27 + bit);
		return;
	}

	for (unsigned int i = 0; i < commands->count; i++) {
		unsigned int opcode = commands->words[i] & 0xf;
		unsigned int len = (commands->words[i] >> 4) & 0xff;

		if (opcode == 9) {
			i += (len & 0xf) / 4;
		} else if (opcode == 10) {
			assert(len <= 12);
			*irq |= BIT(12 * m);
			mmio.fifo_level = mmio.short_fifo ? 0 : (len / 4 + 1);
			mmio.fifo_index = 0;
			memset(mmio.fifo, 0, sizeof(mmio.fifo));
			mmio.fifo[0] = 0xab;
			for (unsigned int b = 1; b <= len; b++)
				mmio.fifo[b / 4] |= (0x7f + b) << (8 * (b % 4));
		} else if (opcode == 8) {
			*irq |= BIT(12 * m + 4 + 4 * q);
		}
	}
	commands->count = commands->words[commands->count - 1] == 7 ? 1 : 0;
}

static void writel(u32 value, void *address)
{
	uintptr_t offset = (char *)address - (char *)cci.base;
	u32 *irq = &mmio.registers[0xc0c / 4];

	for (unsigned int m = 0; m < 2; m++) {
		for (unsigned int q = 0; q < 2; q++) {
			if (offset == 0x310 + 0x200 * m + 0x100 * q) {
				struct command_queue *commands = &mmio.queue[m][q];

				assert(commands->count < limits.queue_size[q]);
				commands->words[commands->count++] = value;
				return;
			}
		}
	}
	switch (offset) {
	case 0x008:
		execute_queue(value);
		break;
	case 0x034:
		assert(value == 1 || value == 2);
		*irq |= BIT(25 + (value == 2));
		break;
	case 0x004:
		assert(value == 0x3f1 || value == 0x3f001);
		memset(mmio.queue[value == 0x3f001], 0, sizeof(mmio.queue[0]));
		mmio.queue_resets++;
		*irq |= BIT(24);
		break;
	case 0xc08:
		*irq &= ~value;
		break;
	default:
		mmio.registers[offset / 4] = value;
	}
}

static u32 readl(void *address)
{
	uintptr_t offset = (char *)address - (char *)cci.base;

	for (unsigned int m = 0; m < 2; m++) {
		for (unsigned int q = 0; q < 2; q++) {
			if (offset == 0x304 + 0x200 * m + 0x100 * q)
				return mmio.queue[m][q].count;
		}
		if (offset == 0x11c + 0x100 * m)
			return mmio.fifo_level;
		if (offset == 0x118 + 0x100 * m) {
			assert(mmio.fifo_index < mmio.fifo_level);
			return mmio.fifo[mmio.fifo_index++];
		}
	}
	return mmio.registers[offset / 4];
}

static void finish_unlock(void *address)
{
	uintptr_t offset = (char *)address - (char *)cci.base;
	unsigned int m = (offset - 0x404) / 0x200;

	assert((offset == 0x404 || offset == 0x604) && mmio.queue[m][1].count == 1);
	mmio.unlock_waits++;
	if (!mmio.stuck_unlock && mmio.unlock_waits > mmio.unlock_delay)
		mmio.queue[m][1].count = 0;
}

#define readl_poll_timeout(addr, val, condition, delay, timeout) ({ \
	int poll_ret = -ETIMEDOUT; \
	assert((delay) > 0 && (timeout) >= (delay)); \
	for (unsigned int attempt = 0; attempt < 6; attempt++) { \
		finish_unlock(addr); \
		(val) = readl(addr); \
		if (condition) { \
			poll_ret = 0; \
			break; \
		} \
	} \
	poll_ret; \
})

static void *i2c_get_adapdata(struct i2c_adapter *a) { return a->data; }
static int pm_runtime_get_sync(void *dev) { assert(dev == &mmio); mmio.gets++; return mmio.pm_error; }
static void pm_runtime_put_autosuspend(void *dev) { assert(dev == &mmio); mmio.puts++; }

#include "cci-functions.h"

static void check_queue(unsigned int n, u32 start, const u32 *words, unsigned int count)
{
	assert(n < mmio.transfers && mmio.starts[n] == start);
	assert(mmio.executed[n].count == count);
	assert(!memcmp(mmio.executed[n].words, words, count * sizeof(*words)));
}

static void check_combined(u16 addr, u8 *prefix, u16 plen, u16 len,
			   u32 parameter, u32 no_stop, u32 read)
{
	u8 buf[13];
	struct i2c_msg messages[] = {
		{ addr, I2C_M_DMA_SAFE, plen, prefix },
		{ addr, I2C_M_RD | I2C_M_DMA_SAFE, len, buf },
	};
	init(0, true);
	memset(buf, 0xff, sizeof(buf));
	mmio.unlock_delay = 2;
	assert(cci_xfer(&adapter, messages, 2) == 2);
	assert(mmio.transfers == 1 && mmio.unlock_waits == 3);
	assert(mmio.queue[0][1].count == 0 && mmio.gets == 1 && mmio.puts == 1);
	check_queue(0, 2, (u32[]){ parameter, 6, no_stop, read, 7 }, 5);
	assert(mmio.fifo_index == len / 4U + 1U);
	for (unsigned int i = 0; i < len; i++)
		assert(buf[i] == 0x80 + i);
	assert(buf[len] == 0xff);
}

int main(void)
{
	u8 prefix[] = { 0x07, 0x16, 0x34 }, result[12];
	struct i2c_msg messages[] = {
		{ 0x20, 0, 2, prefix }, { 0x20, I2C_M_RD, 2, result },
	};

	check_combined(0x0c, (u8[]){ 0x00 }, 1, 1, 0xc1, 0x1b, 0x1a);
	check_combined(0x58, (u8[]){ 0x00, 0x27 }, 2, 11, 0x581, 0x27002b, 0xba);
	check_combined(0x20, prefix, 2, 12, 0x201, 0x16072b, 0xca);

	init(0, true);
	mmio.nack_transfer = 1;
	assert(cci_xfer(&adapter, messages, 2) == -ENXIO);
	assert(mmio.transfers == 1 && mmio.starts[0] == 2 && mmio.queue_resets == 1);
	assert(!mmio.fifo_index && !mmio.unlock_waits && mmio.puts == 1);
	assert(cci_xfer(&adapter, messages, 2) == 2);

	init(0, true);
	mmio.stuck_unlock = true;
	assert(cci_xfer(&adapter, messages, 2) == -ETIMEDOUT);
	assert(mmio.timeout_resets == 1 && !mmio.fifo_index && mmio.puts == 1);

	init(0, true);
	mmio.short_fifo = true;
	assert(cci_xfer(&adapter, messages, 2) == -EIO);
	assert(mmio.transfers == 1 && !mmio.fifo_index && mmio.puts == 1);

	init(0, true);
	mmio.pm_error = -EIO;
	assert(cci_xfer(&adapter, messages, 2) == -EIO);
	assert(!mmio.transfers && mmio.gets == 1 && mmio.puts == 1);

	init(0, false);
	assert(cci_xfer(&adapter, messages, 2) == 2);
	check_queue(0, 1, (u32[]){ 0x201, 0x160729, 0x108 }, 3);
	check_queue(1, 2, (u32[]){ 0x201, 0x2a }, 2);

	init(1, true);
	assert(cci_xfer(&adapter, messages, 2) == 2);
	check_queue(0, 4, (u32[]){ 0x201, 0x160729, 0x108 }, 3);
	check_queue(1, 8, (u32[]){ 0x201, 0x2a }, 2);

	init(0, true);
	assert(cci_xfer(&adapter, messages, 1) == 1);
	check_queue(0, 1, (u32[]){ 0x201, 0x160729, 0x108 }, 3);
	assert(cci_xfer(&adapter, messages + 1, 1) == 1);
	check_queue(1, 2, (u32[]){ 0x201, 0x2a }, 2);

	init(0, true);
	messages[0].flags = I2C_M_STOP;
	mmio.nack_transfer = 1;
	assert(cci_xfer(&adapter, messages, 2) == -ENXIO);
	assert(mmio.transfers == 1 && mmio.starts[0] == 1 && mmio.queue_resets == 1);
	init(0, true);
	mmio.nack_transfer = 2;
	assert(cci_xfer(&adapter, messages, 2) == -ENXIO);
	assert(mmio.transfers == 2 && mmio.starts[0] == 1 && mmio.starts[1] == 2);
	assert(mmio.queue_resets == 1 && !mmio.fifo_index && mmio.puts == 1);
	messages[0].flags = 0;
	messages[0].len = 3;
	assert(!cci_is_combined_read(&cci.master[0], messages, 2));
	messages[0].len = 0;
	assert(!cci_is_combined_read(&cci.master[0], messages, 2));
	messages[0].len = 2;
	messages[1].len = 13;
	assert(!cci_is_combined_read(&cci.master[0], messages, 2));
	messages[1].len = 2;
	messages[1].flags |= I2C_M_RECV_LEN;
	assert(!cci_is_combined_read(&cci.master[0], messages, 2));
	messages[1].flags = I2C_M_RD;
	messages[1].addr = 0x58;
	assert(!cci_is_combined_read(&cci.master[0], messages, 2));
	messages[1].addr = 0x20;
	assert(!cci_is_combined_read(&cci.master[0], messages, 3));
	limits.queue_size[1] = 4;
	assert(!cci_is_combined_read(&cci.master[0], messages, 2));

	puts("PASS: CCI queue encoding, read FIFO, NACK/recovery, timeout and fallback paths");
	return 0;
}
