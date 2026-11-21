/* SPDX-License-Identifier: LGPL-2.1-or-later */
#pragma once

#include <array>
#include <cstdint>

namespace bracket {
struct Point {
	int32_t timeUs;
	float gain;
};
constexpr std::array<Point, 4> points{{ {2000, 1}, {32000, 1}, {32000, 8}, {2000, 1} }};
constexpr unsigned stableFrames = 4, limitPerPoint = 32;

struct Progress {
	unsigned index = 0, frames = 0, matches = 0;
	bool observe(int32_t timeUs, float gain)
	{
		const auto &p = points.at(index);
		++frames;
		matches = timeUs == p.timeUs && gain == p.gain ? matches + 1 : 0;
		return matches == stableFrames;
	}
	void advance() { ++index; frames = 0; matches = 0; }
};
}
