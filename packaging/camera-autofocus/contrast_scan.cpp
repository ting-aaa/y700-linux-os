/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "contrast_scan.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace libcamera {

bool ContrastScan::supportsLens(std::string_view id, std::string_view sensor,
				std::string_view lens, int low, int high)
{
	return id == "/base/soc@0/cci@ac15000/i2c-bus@0/camera@20" &&
	       sensor == "hi1339" && lens == "gt9768" && low >= 0 && high <= 1023 && low < high;
}

/* Green is byte 1 in all six little-endian RGB/BGR formats used here.
 * Sample two-dimensional, one-pixel gradients in the central half of the
 * actual ISP image. Normalizing by mean brightness reduces exposure bias. */
std::optional<double> ContrastScan::contrast(const uint8_t *plane, size_t length,
					    unsigned int width, unsigned int height,
					    unsigned int stride, unsigned int pixelBytes)
{
	if (!plane || width < 16 || height < 16 || (pixelBytes != 3 && pixelBytes != 4) ||
	    uint64_t(width) * pixelBytes > stride || uint64_t(height) * stride > length)
		return {};

	uint64_t energy = 0, light = 0, count = 0;
	const unsigned int dx = std::max(1U, width / 192);
	const unsigned int dy = std::max(1U, height / 144);
	for (unsigned int y = height / 4; y < height - height / 4 - 1; y += dy) {
		for (unsigned int x = width / 4; x < width - width / 4 - 1; x += dx) {
			const uint8_t *g = plane + size_t(y) * stride + size_t(x) * pixelBytes + 1;
			int h = int(g[pixelBytes]) - *g;
			int v = int(g[stride]) - *g;
			energy += h * h + v * v;
			light += *g;
			count++;
		}
	}
	return std::sqrt(double(energy) / (2 * count)) /
	       std::max(12.0, double(light) / count);
}

void ContrastScan::reset(int low, int high)
{
	*this = ContrastScan{};
	low_ = low;
	high_ = high;
}

void ContrastScan::addRange(int low, int high, int intervals)
{
	positions_.clear();
	for (int i = 0; i <= intervals; ++i) {
		int position = low + ((high - low) * i + intervals / 2) / intervals;
		if (positions_.empty() || positions_.back() != position)
			positions_.push_back(position);
	}
	index_ = 0;
}

void ContrastScan::request(std::optional<bool> automatic, Trigger trigger)
{
	if (automatic)
		automatic_ = *automatic;
	if (!automatic_ || (trigger == Trigger::Cancel && state_ == State::Scanning)) {
		state_ = State::Idle;
		return;
	}
	if (trigger != Trigger::Start || state_ == State::Scanning)
		return;
	if (low_ < 0 || high_ > 1023 || high_ <= low_) {
		state_ = State::Failed;
		return;
	}
	addRange(low_, high_, 8);
	state_ = State::Scanning;
	phase_ = Phase::Coarse;
	best_ = -1;
	worst_ = std::numeric_limits<double>::max();
	began_ = 0;
	needMove_ = true;
}

ContrastScan::State ContrastScan::failedFrame()
{
	if (state_ == State::Scanning)
		state_ = State::Failed;
	return state_;
}

ContrastScan::State ContrastScan::frame(uint64_t now, uint64_t captured,
					const std::function<bool(int)> &move,
					const std::function<std::optional<double>()> &score)
{
	if (state_ != State::Scanning)
		return state_;
	if (!began_)
		began_ = now;
	/* An unresponsive or stalled stream can never report a focus lock. */
	if (now - began_ > 45000000000ULL)
		return state_ = State::Failed;

	if (needMove_) {
		position_ = phase_ == Phase::Verify ? bestPosition_ : positions_[index_];
		if (!move(position_))
			return state_ = State::Failed;
		moved_ = now;
		lastCapture_ = 0;
		haveSample_ = false;
		needMove_ = false;
		return state_;
	}
	/* A finished ISP buffer can have been exposed before the preceding move.
	 * The board CAMSS timestamps are CLOCK_MONOTONIC. Reject duplicate/stale
	 * exposures, and allow a complete mechanical settling interval. */
	if (captured < moved_ || captured - moved_ < 50000000 || captured > now ||
	    captured <= lastCapture_)
		return state_;
	/* CAMSS timestamps frame completion. An exposure crossing the settling
	 * interval can therefore finish after it. Discard that first completion. */
	if (!lastCapture_) {
		lastCapture_ = captured;
		return state_;
	}
	lastCapture_ = captured;
	auto value = score();
	if (!value || !std::isfinite(*value))
		return state_ = State::Failed;
	if (!haveSample_) {
		previousScore_ = *value;
		haveSample_ = true;
		return state_;
	}
	double mean = (*value + previousScore_) / 2.0;
	if (phase_ == Phase::Verify)
		return state_ = mean >= best_ * 0.75 ? State::Focused : State::Failed;

	if (mean > best_) {
		best_ = mean;
		bestPosition_ = position_;
	}
	worst_ = std::min(worst_, mean);
	needMove_ = true;
	if (++index_ < positions_.size())
		return state_;
	if (best_ < 0.025 || best_ < worst_ * 1.12)
		return state_ = State::Failed;
	if (phase_ == Phase::Coarse) {
		const int radius = std::max(1, (high_ - low_ + 7) / 8);
		addRange(std::max(low_, bestPosition_ - radius),
			 std::min(high_, bestPosition_ + radius), 8);
		phase_ = Phase::Fine;
	} else {
		phase_ = Phase::Verify;
	}
	return state_;
}

} /* namespace libcamera */
