// SPDX-License-Identifier: LGPL-2.1-or-later
// A changing fine stripe on a noisy, equally lit synthetic target.
#include "contrast_scan.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <iostream>
#include <stdexcept>
#include <string_view>
#include <vector>

using Scan = libcamera::ContrastScan;
constexpr unsigned int width = 640, height = 480, stride = width * 4;

static void require(bool condition, const char *message)
{
	if (!condition)
		throw std::runtime_error(message);
}

static std::vector<uint8_t> imageFor(int position, unsigned int phase, unsigned int sample)
{
	std::vector<uint8_t> image(height * stride);
	uint32_t gen = 941 + sample;
	for (unsigned int y = 0; y < height; ++y) {
		for (unsigned int x = 0; x < width; ++x) {
			gen = 1664525 * gen + 1013904223;
			int noise = int((gen >> 16) % 13) - 6;
			unsigned int column = x + 6 - (width / 4) % 6;
			int amplitude = 36 * (400 - std::min(400, std::abs(position - 500))) / 400;
			int detail = column % 3 == phase ? (column % 6 < 3 ? amplitude : -amplitude) : 0;
			image[y * stride + x * 4 + 1] = 156 + noise + detail;
		}
	}
	return image;
}

static double allPixelOracle(const std::vector<uint8_t> &image)
{
	double sum = 0, energy = 0;
	unsigned int n = 0;
	for (unsigned int y = height / 4; y + 1 < height * 3 / 4; y++)
		for (unsigned int x = width / 4; x + 1 < width * 3 / 4; x++) {
			size_t g = y * stride + x * 4 + 1;
			int green = image[g], h = image[g + 4] - green, v = image[g + stride] - green;
			energy += h * h + v * v;
			sum += green;
			++n;
		}
	return std::sqrt(energy / (2 * n)) / std::max(12., sum / n);
}

static unsigned int ppm(double value)
{
	return static_cast<unsigned int>(value * 1000000 + 0.5);
}

static void run(unsigned int phase, bool omitReference, bool printRows, bool fixedImage = false)
{
	Scan scan;
	Scan::Diagnostic diag{};
	scan.reset(100, 900);
	scan.request(true, Scan::Trigger::Start, &diag);
	Scan::State state = Scan::State::Scanning;
	uint64_t now = 1000000000;
	int moves = 0, samples = 0, first = 0, position = 0;
	unsigned int rows = 0;
	double lowestReference = 1e6, highestReference = -1;
	std::array<double, 2> raw{}, full{};
	for (int frame = 0; frame < 200 && state == Scan::State::Scanning; frame++) {
		now += 33333333;
		state = scan.frame([&] { return now; }, now, [&](int target) {
			position = target;
			++moves;
			first = samples;
			return true;
		}, [&]() {
			int i = samples++ - first;
			require(i == 0 || i == 1, "two distinct samples per position");
			auto image = imageFor(fixedImage ? 100 : position, phase, i);
			auto score = Scan::contrast(image.data(), image.size(), width, height, stride, 4);
			raw[i] = score.value();
			full[i] = allPixelOracle(image);
#ifndef Y700_PRE_PAIR_TRACE
			auto ref = Scan::referenceContrast(image.data(), image.size(), width, height, stride, 4);
			require(std::abs(ref.value() - full[i]) < 1e-12, "dense reference matches independent oracle");
			if (!omitReference || i == 0)
				diag.referenceSample = ref;
#endif
			if (i == 1 && moves <= 9) {
				double mean = (full[0] + full[1]) / 2;
				lowestReference = std::min(lowestReference, mean);
				highestReference = std::max(highestReference, mean);
			}
			return score;
		}, &diag);
#ifndef Y700_PRE_PAIR_TRACE
		if (auto &p = diag.pair; p.phase) {
			++rows;
			std::string_view wanted = moves <= 9 ? "coarse" : moves <= 18 ? "fine" : "verify";
			require(p.phase == wanted && p.point == (rows - 1) % 9 + 1 &&
				p.mean == (raw[0] + raw[1]) / 2 && p.delta == std::abs(raw[1] - raw[0]) &&
				p.referenceMean == (full[0] + full[1]) / 2 &&
				p.referenceDelta == std::abs(full[1] - full[0]), "row uses this phase and frame pair");
			if (printRows)
				std::printf("AF_DIAG phase=%s point=%u mean_ppm=%u pair_delta_ppm=%u "
					    "ref_mean_ppm=%u ref_pair_delta_ppm=%u\n", p.phase, p.point,
					    ppm(p.mean), ppm(p.delta), ppm(p.referenceMean), ppm(p.referenceDelta));
			p = {};
		}
#endif
	}
#ifdef Y700_FULL_GRID_DECISION
	bool blind = fixedImage;
#else
	bool blind = fixedImage || phase == 2;
#endif
	require(moves == (blind ? 9 : 19) && samples == 2 * moves && diag.reason &&
		std::string_view(diag.reason) == (blind ? "flat-contrast" : "focused"), "terminal decision");
	require(blind ? state == Scan::State::Failed : state == Scan::State::Focused, "terminal state");
	require(fixedImage ? highestReference == lowestReference : highestReference > lowestReference * 2,
		"dense reference detects only changing detail");
#ifndef Y700_PRE_PAIR_TRACE
	require(rows == (omitReference ? 0U : unsigned(moves)), "missing reference never emitted as zero");
#else
	(void)rows;
#endif
	if (printRows) {
		const auto &[coarse, fine, verify] = diag.progress;
		std::printf("AF_DIAG phase=%s reason=%s input=none lens_api_status=0 controls=%u/%u/%u "
			    "samples=%u/%u/%u timestamp_rejects=%u/%u/%u\n", diag.phase, diag.reason,
			    coarse.controls, fine.controls, verify.controls, coarse.samples, fine.samples,
			    verify.samples, coarse.timestampRejects, fine.timestampRejects, verify.timestampRejects);
	}
	std::printf("PASS synthetic phase=%u omit_reference=%u fixed_image=%u decision=%s moves=%d scores=%d "
		    "dense_min_ppm=%u dense_max_ppm=%u\n", phase, unsigned(omitReference), unsigned(fixedImage),
		    diag.reason, moves, samples, ppm(lowestReference), ppm(highestReference));
}

int main()
try {
	for (unsigned int phase = 0; phase < 3; phase++)
		run(phase, false, phase == 2);
	run(2, true, false);
	run(0, false, false, true);
#ifndef Y700_PRE_PAIR_TRACE
	auto pixels = imageFor(500, 0, 0);
	require(!Scan::referenceContrast(pixels.data(), pixels.size() - 1, width, height, stride, 4) &&
		!Scan::referenceContrast(pixels.data(), pixels.size(), width + 1, height, stride, 4) &&
		!Scan::referenceContrast(pixels.data(), pixels.size(), width, height + 1, stride, 4),
		"reference dimensions and length bound");
	for (bool dense : { false, true }) {
		auto score = dense ? &Scan::referenceContrast : &Scan::contrast;
		using Clock = std::chrono::steady_clock;
		auto start = Clock::now();
		double sum = 0;
		constexpr unsigned int count = 128;
		for (unsigned int n = 0; n < count; ++n)
			sum += score(pixels.data(), pixels.size(), width, height, stride, 4).value();
		auto us = std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - start);
		require(sum > 0, "benchmark consumed score");
		std::printf("TIMING grid=%s iterations=%u mean_us=%lld\n", dense ? "full" : "sparse",
			    count, static_cast<long long>(us.count() / count));
	}
#endif
	return 0;
} catch (const std::exception &e) {
	std::cerr << "FAIL " << e.what() << '\n';
	return 1;
}
