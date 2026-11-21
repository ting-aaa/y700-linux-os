/* SPDX-License-Identifier: LGPL-2.1-or-later */
#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <stdexcept>

namespace optical {

/* The board fixture fixes the processed stream size and samples only its
 * central half. Keep coarse tile averages in memory for the motion guard. */
constexpr unsigned width = 640, height = 480, groupSize = 8;
struct Sample {
	double sharpness = 0, mean = 0, clipped = 0;
	std::array<double, 16> tiles{};
};

inline Sample measure(const uint8_t *plane, size_t length, unsigned stride)
{
	if (!plane || stride < width * 4 || size_t(stride) * height > length)
		throw std::runtime_error("invalid_rgb_plane");
	Sample result;
	std::array<unsigned, 16> counts{};
	unsigned n = 0;
	for (unsigned y = height / 4; y < height * 3 / 4; y += 3) {
		for (unsigned x = width / 4; x < width * 3 / 4; x += 3) {
			const uint8_t *p = plane + y * size_t(stride) + x * 4 + 1;
			const int green = *p;
			// Absolute four-neighbour Laplacian, independent of the AF search's gradient score.
			result.sharpness += std::abs(4 * green - p[-4] - p[4] - *(p - stride) - p[stride]);
			result.mean += green;
			result.clipped += green <= 5 || green >= 250;
			unsigned tile = ((y - height / 4) / (height / 8)) * 4 +
					(x - width / 4) / (width / 8);
			result.tiles[tile] += green;
			counts[tile]++;
			n++;
		}
	}
	result.mean /= n;
	result.clipped /= n;
	result.sharpness /= n * std::max(result.mean, 12.);
	for (size_t i = 0; i < counts.size(); ++i)
		result.tiles[i] /= counts[i] * std::max(result.mean, 12.);
	return result;
}

using Window = std::array<Sample, groupSize>;

inline double sceneChange(const Sample &a, const Sample &b)
{
	double difference = 0;
	for (size_t i = 0; i < a.tiles.size(); ++i)
		difference += std::abs(a.tiles[i] - b.tiles[i]);
	return difference / a.tiles.size();
}

struct Summary {
	Sample average;
	double median, drift;
	bool stable;
};

inline Summary summarize(const Window &frames)
{
	Summary out{};
	std::array<double, groupSize> scores{};
	for (size_t i = 0; i < frames.size(); ++i) {
		const auto &f = frames[i];
		scores[i] = f.sharpness;
		out.average.mean += f.mean / frames.size();
		out.average.clipped += f.clipped / frames.size();
		for (size_t k = 0; k < f.tiles.size(); ++k)
			out.average.tiles[k] += f.tiles[k] / frames.size();
	}
	std::sort(scores.begin(), scores.end());
	out.median = (scores[3] + scores[4]) / 2;
	out.drift = scores.back() - scores.front();
	out.stable = out.drift <= std::max(0.006, out.median * .20);
	for (const auto &f : frames)
		out.stable &= f.mean >= 20 && f.mean <= 235 && f.clipped <= .15 &&
			      std::abs(f.mean - out.average.mean) <= .08 * out.average.mean &&
			      sceneChange(f, out.average) <= .06;
	return out;
}

inline const char *verdict(const Summary &a, const Summary &b, bool focused)
{
	if (!focused)
		return "af_failed";
	if (!a.stable || !b.stable || std::abs(a.average.mean - b.average.mean) > .12 * a.average.mean ||
	    sceneChange(a.average, b.average) > .08 || b.median < .012)
		return "inconclusive";
	const double threshold = std::max({ .006, .15 * a.median, 2 * a.drift, 2 * b.drift });
	return b.median - a.median > threshold ? "improved" : "no_gain";
}
} /* namespace optical */
