/* SPDX-License-Identifier: LGPL-2.1-or-later */
// PC fixture for the exact ARM64 CPU ISP. No camera manager start or device lookup.
#include "signal-metric.h"
#include "debayer_cpu.h"
#include <libcamera/formats.h>
#include <sys/mman.h>
#include <unistd.h>
#include <iostream>

using namespace libcamera;
using namespace optical;

static void check(bool condition, const char *reason)
{
	if (!condition)
		throw std::runtime_error(reason);
}

static std::unique_ptr<FrameBuffer> memoryFrame(unsigned size)
{
	UniqueFD fd(memfd_create("synthetic-cfa", MFD_CLOEXEC));
	check(fd.isValid() && ftruncate(fd.get(), size) == 0, "memfd");
	FrameBuffer::Plane plane{ SharedFD(std::move(fd)), 0, size };
	return std::make_unique<FrameBuffer>(std::vector<FrameBuffer::Plane>{ plane });
}

int main()
try {
	const std::array<uint8_t, 5> packed{ 0x00, 0x55, 0xaa, 0xff, 0xe4 };
	for (unsigned lane = 0; lane < 4; ++lane)
		check(raw10(packed.data(), lane) == lane * 341, "CSI2P low bits");
	CameraManager cm;
	auto stats = std::make_unique<SwStatsCpu>(cm);
	check(stats->isValid(), "stats memory");
	DebayerCpu isp(std::move(stats), cm);
	StreamConfiguration raw, rgb;
	raw.size = { rawWidth, rawHeight };
	raw.pixelFormat = formats::SGBRG10_CSI2P;
	raw.stride = rawWidth * 5 / 4 + 20; // nonzero input padding
	rgb.size = { width, height };
	rgb.pixelFormat = formats::ABGR8888;
	rgb.stride = std::get<0>(isp.strideAndFrameSize(rgb.pixelFormat, rgb.size));
	check(isp.configure(raw, { std::cref(rgb) }, false) == 0, "ISP config");
	std::vector<uint8_t> input(raw.stride * rawHeight, 0xec), output(rgb.stride * height);
	auto in = memoryFrame(input.size()), out = memoryFrame(output.size());
	// Distinct values in both green photosites exercise the CFA-to-metadata order.
	// Only the upper bytes are set here. Every fifth byte carries zero low bits.
	for (unsigned y = 0; y < height; ++y) {
		auto *row = input.data() + (cropY + y) * raw.stride + cropX * 5 / 4;
		for (unsigned x = 0; x < width; x += 4) {
			row[0] = row[2] = y % 2 ? 25 : 75;
			row[1] = row[3] = y % 2 ? 50 : 100;
			row[4] = 0;
			row += 5;
		}
	}
	const std::array<unsigned, 4> known{ 100, 200, 300, 400 };
	auto rawSites = measureRaw(input.data(), input.size(), raw.stride, known);
	for (unsigned c = 0; c < known.size(); ++c)
		check(rawSites[c].mean() == known[c] && rawSites[c].dark == rawSites[c].count, "four CFA sites");
	DebayerParams params;
	params.blackLevel = RGB<float>(16 / 255.f);
	params.gamma = .5f;
	check(isp.start() == 0, "ISP start");
	try {
		unsigned sequence = 0;
		auto verify = [&](unsigned red, unsigned green, unsigned blue) {
			const std::array<unsigned, 3> rgb10 = { red, green, blue };
			for (unsigned y = 0; y < height; ++y) {
				// Sensor has Gb B / R Gr rows. Change the crop only. The rest stays bright.
				auto *row = input.data() + (cropY + y) * raw.stride + cropX * 5 / 4;
				const unsigned even = y % 2 ? red : green;
				const unsigned odd = y % 2 ? green : blue;
				for (unsigned x = 0; x < width; x += 4) {
					*row++ = even / 4;
					*row++ = odd / 4;
					*row++ = even / 4;
					*row++ = odd / 4;
					*row++ = ((even & 3) | ((odd & 3) << 2)) * 17;
				}
			}
			const auto cfa = measureRaw(input.data(), input.size(), raw.stride, { 64, 64, 64, 64 });
			const std::array<unsigned, 4> expectedRaw{ red, green, green, blue };
			for (unsigned i = 0; i < cfa.size(); ++i) {
				check(cfa[i].mean() == expectedRaw[i], "CFA order, stride or crop");
				check(cfa[i].dark == (expectedRaw[i] <= 64 ? cfa[i].count : 0), "RAW low threshold");
				check(cfa[i].bright == (expectedRaw[i] >= 1020 ? cfa[i].count : 0), "RAW high threshold");
			}
			check(pwrite(in->planes()[0].fd.get(), input.data(), input.size(), 0) == ssize_t(input.size()), "input");
			isp.process(++sequence, in.get(), out.get(), params);
			check(out->metadata().planes()[0].bytesused == output.size(), "ISP completion");
			check(pread(out->planes()[0].fd.get(), output.data(), output.size(), 0) == ssize_t(output.size()), "output");
			const auto channels = measureRgb(output.data(), output.size(), rgb.stride);
			auto af = measure(output.data(), output.size(), rgb.stride);
			check(af.mean == channels[1].mean() && af.sharpness == 0, "AF green channel");
			check(channels[1].count == 8560 && af.clipped == (channels[1].dark + channels[1].bright) / 8560.,
			      "clipping accounting");
			for (unsigned i = 0; i < rgb10.size(); ++i) {
				double expected = 255 * std::sqrt(std::clamp((int(rgb10[i] / 4) - 16) / 240., 0., 1.));
				check(std::abs(channels[i].mean() - expected) <= 2, "black level, gamma or channel mapping");
			}
			check(output[(height / 2 * rgb.stride) + (width / 2 * 4) + 3] == 255, "opaque alpha");
			std::cout << "ISP_CASE raw=" << red << "," << green << "," << blue << " rgb="
				  << channels[0].mean() << "," << af.mean << "," << channels[2].mean() << "\n";
		};
		verify(0, 63, 64);
		verify(803, 402, 133);
		verify(64, 1023, 67);
		verify(1023, 64, 1023);
	} catch (...) {
		isp.stop();
		throw;
	}
	isp.stop();
	std::cout << "SIGNAL_ISP pass=1 cases=4 camera_access=0\n";
	return 0;
} catch (const std::exception &error) {
	std::cerr << "SIGNAL_ISP error=" << error.what() << "\n";
	return 1;
}
