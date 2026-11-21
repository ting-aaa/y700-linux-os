/* SPDX-License-Identifier: LGPL-2.1-or-later */
#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <string_view>
#include <vector>

namespace libcamera {

class ContrastScan
{
public:
	enum class State { Idle, Scanning, Focused, Failed };
	enum class Trigger { None, Start, Cancel };

	static bool supportsLens(std::string_view id, std::string_view sensor,
				 std::string_view lens, int low, int high);

	static std::optional<double> contrast(const uint8_t *plane, size_t length,
					      unsigned int width, unsigned int height,
					      unsigned int stride, unsigned int pixelBytes);

	void reset(int low, int high);
	void request(std::optional<bool> automatic, Trigger trigger);
	State failedFrame();
	State frame(uint64_t now, uint64_t captured,
		    const std::function<bool(int)> &move,
		    const std::function<std::optional<double>()> &score);

private:
	bool automatic_ = false;
	State state_ = State::Idle;
	enum class Phase { Coarse, Fine, Verify } phase_ = Phase::Coarse;
	int low_ = 0, high_ = 0, position_ = 0, bestPosition_ = 0;
	std::vector<int> positions_;
	size_t index_ = 0;
	uint64_t began_ = 0, moved_ = 0, lastCapture_ = 0;
	double best_ = 0, worst_ = 0, previousScore_ = 0;
	bool haveSample_ = false, needMove_ = false;

	void addRange(int low, int high, int intervals);
};

} /* namespace libcamera */
