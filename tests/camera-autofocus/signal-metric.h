/* SPDX-License-Identifier: LGPL-2.1-or-later */
#pragma once

#include "optical-metric.h"

namespace optical {

constexpr unsigned rawWidth = 4208, rawHeight = 3120;
// DebayerCpu::configure centres the window on complete RAW10 groups and CFA rows.
constexpr unsigned cropX = ((rawWidth - width) / 2) & ~3u;
constexpr unsigned cropY = ((rawHeight - height) / 2) & ~1u;

inline unsigned raw10(const uint8_t *row, unsigned x)
{
	const uint8_t *group = row + x / 4 * 5;
	unsigned lane = x % 4;
	return (group[lane] << 2) | ((group[4] >> (2 * lane)) & 3);
}

struct SignalChannel {
	unsigned count = 0, dark = 0, bright = 0, sum = 0;
	void add(unsigned value, unsigned low, unsigned high)
	{
		++count;
		sum += value;
		dark += value <= low;
		bright += value >= high;
	}
	double mean() const { return double(sum) / count; }
};

// Four CFA sites in the SensorBlackLevels R, Gr, Gb, B order.
using RawSignal = std::array<SignalChannel, 4>;
using RgbSignal = std::array<SignalChannel, 3>;

inline RawSignal measureRaw(const uint8_t *data, size_t bytes, unsigned stride,
			    const std::array<unsigned, 4> &pedestal)
{
	if (!data || stride < rawWidth / 4 * 5 || size_t(stride) * rawHeight > bytes)
		throw std::runtime_error("incomplete_raw_plane");
	RawSignal channels{};
	// SGBRG rows are Gb B, then R Gr.
	constexpr unsigned site[2][2] = { { 2, 3 }, { 0, 1 } };
	for (unsigned y = height / 4; y < height * 3 / 4; y += 3) {
		const unsigned row = cropY + y;
		for (unsigned x = width / 4; x < width * 3 / 4; x += 3) {
			const unsigned col = cropX + x;
			const auto c = site[row % 2][col % 2];
			channels[c].add(raw10(data + size_t(row) * stride, col), pedestal[c], 1020);
		}
	}
	return channels;
}

inline RgbSignal measureRgb(const uint8_t *data, size_t bytes, unsigned stride)
{
	if (!data || stride < width * 4 || size_t(stride) * height > bytes)
		throw std::runtime_error("incomplete_rgb_plane");
	RgbSignal channels{};
	for (unsigned y = height / 4; y < height * 3 / 4; y += 3) {
		for (unsigned x = width / 4; x < width * 3 / 4; x += 3) {
			const uint8_t *pixel = data + size_t(y) * stride + 4 * x;
			for (unsigned c = 0; c < channels.size(); ++c)
				channels[c].add(pixel[c], 5, 250);
		}
	}
	return channels;
}
}
