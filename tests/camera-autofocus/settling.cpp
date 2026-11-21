// SPDX-License-Identifier: LGPL-2.1-or-later
// A queued CAMSS completion may have been exposed before a slow lens ioctl returned.
#include "contrast_scan.h"

#include <iostream>
#include <stdexcept>

using Scan = libcamera::ContrastScan;

int main()
try {
	constexpr uint64_t ms = 1000000, start = 1000 * ms;
	uint64_t now = start;
	unsigned int moves = 0, scores = 0;
	Scan scan;
	Scan::Diagnostic diagnostic{};
	scan.reset(100, 900);
	scan.request(true, Scan::Trigger::Start, &diagnostic);
	auto frame = [&](uint64_t capture, uint64_t delivered, unsigned int expected) {
		now = start + delivered;
#ifdef Y700_SNAPSHOT_CLOCK
		auto clock = now; // Original diagnostic library, for the negative control.
#else
		auto clock = [&] { return now; };
#endif
		auto state = scan.frame(clock, start + capture, [&](int) {
			++moves;
			now += 120 * ms;
			return true;
		}, [&]() -> std::optional<double> {
			++scores;
			return .12;
		}, &diagnostic);
		if (state != Scan::State::Scanning || scores != expected) {
			std::cerr << "capture_ns=" << capture << " delivered_ns=" << delivered
				  << " scored=" << scores << " expected=" << expected << '\n';
			throw std::runtime_error("settling guard");
		}
	};
	frame(0, 0, 0); // Synchronous move returns at +120 ms.
	frame(70 * ms, 122 * ms, 0);
	frame(90 * ms, 124 * ms, 0);
	frame(120 * ms, 132 * ms, 0);
	frame(170 * ms - 1, 171 * ms, 0);
	frame(170 * ms, 172 * ms, 0); // First eligible completion is discarded.
	frame(170 * ms, 173 * ms, 0); // The same exposure cannot be scored twice.
	frame(190 * ms, 191 * ms, 1);
	frame(220 * ms, 221 * ms, 2);
	if (moves != 1 || diagnostic.progress[0].controls != 1 ||
	    diagnostic.progress[0].samples != 2)
		throw std::runtime_error("unexpected phase progress");
	std::cout << "PASS slow_control_ms=120 settle_ms=50 premature_scores=0 "
		     "first_eligible_discarded=1 duplicate_discarded=1 fresh_scores=2\n";
	return 0;
} catch (const std::exception &ex) {
	std::cerr << "FAIL " << ex.what() << '\n';
	return 1;
}
