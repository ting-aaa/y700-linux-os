// SPDX-License-Identifier: LGPL-2.1-or-later
#include "contrast_scan.h"

#include <gst/app/gstappsink.h>
#include <gst/video/video.h>

#include <algorithm>
#include <cmath>
#include <iostream>
#include <memory>
#include <stdexcept>

using Scan = libcamera::ContrastScan;
using State = Scan::State;
using Trigger = Scan::Trigger;

static void require(bool ok, const char *description)
{
	if (!ok)
		throw std::runtime_error(description);
}

// An optical test double blurs pixels from a real GStreamer video stream.
// The implementation being checked receives only the plane, never this model's optimum.
static std::vector<uint8_t> defocus(const uint8_t *pixels, int width, int height,
				   int stride, int error)
{
	const double sigma = std::min(6.0, 0.36 + std::abs(error) * 0.035);
	const int radius = std::ceil(2.5 * sigma);
	std::vector<double> weights(radius * 2 + 1);
	double sum = 0;
	for (int i = -radius; i <= radius; ++i)
		sum += weights[i + radius] = std::exp(-(i * i) / (2 * sigma * sigma));
	for (double &weight : weights)
		weight /= sum;
	std::vector<double> horizontal(width * height);
	std::vector<uint8_t> rgb(stride * height);
	for (int y = 0; y < height; ++y) {
		for (int x = 0; x < width; ++x) {
			double green = 0;
			for (int i = -radius; i <= radius; ++i) {
				int xx = std::clamp(x + i, 0, width - 1);
				green += weights[i + radius] * pixels[y * stride + xx * 3 + 1];
			}
			horizontal[y * width + x] = green;
		}
	}
	for (int y = 0; y < height; ++y) {
		for (int x = 0; x < width; ++x) {
			double green = 0;
			for (int i = -radius; i <= radius; ++i) {
				int yy = std::clamp(y + i, 0, height - 1);
				green += weights[i + radius] * horizontal[yy * width + x];
			}
			std::fill_n(&rgb[y * stride + x * 3], 3, std::lround(green));
		}
	}
	return rgb;
}

struct Chart {
	GstElement *pipeline;
	GstAppSink *sink;
	Scan scan;
	int min, max, optimum, position, moves = 0, scores = 0;
	uint64_t clock = 0;
	State state = State::Idle;
	bool rejectMove = false;

	Chart(const char *pattern, int low, int high, int target)
		: min(low), max(high), optimum(target), position(low)
	{
		std::string description = std::string("videotestsrc pattern=") + pattern +
			" ! video/x-raw,format=RGB,width=101,height=72,framerate=30/1"
			" ! appsink name=frames sync=false max-buffers=1";
		GError *error = nullptr;
		pipeline = gst_parse_launch(description.c_str(), &error);
		require(pipeline && !error, error ? error->message : "pipeline");
		sink = GST_APP_SINK(gst_bin_get_by_name(GST_BIN(pipeline), "frames"));
		require(gst_element_set_state(pipeline, GST_STATE_PLAYING) != GST_STATE_CHANGE_FAILURE,
			"start test stream");
		scan.reset(min, max);
	}

	~Chart()
	{
		gst_element_set_state(pipeline, GST_STATE_NULL);
		gst_object_unref(sink);
		gst_object_unref(pipeline);
	}

	State next(bool stale = false)
	{
		std::unique_ptr<GstSample, decltype(&gst_sample_unref)> sample(
			gst_app_sink_try_pull_sample(sink, GST_SECOND * 5), gst_sample_unref);
		require(sample != nullptr, "GStreamer frame timeout");
		GstBuffer *buffer = gst_sample_get_buffer(sample.get());
		require(GST_BUFFER_PTS_IS_VALID(buffer), "frame PTS");
		clock = GST_SECOND + GST_BUFFER_PTS(buffer);
		state = scan.frame(clock, stale ? 1 : clock, [&](int dac) {
			require(min <= dac && dac <= max, "calibrated range");
			++moves;
			position = dac;
			return !rejectMove;
		}, [&]() {
			GstVideoInfo info;
			GstVideoFrame frame{};
			require(gst_video_info_from_caps(&info, gst_sample_get_caps(sample.get())) &&
				gst_video_frame_map(&frame, &info, buffer, GST_MAP_READ), "map RGB frame");
			int stride = GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0);
			int width = GST_VIDEO_FRAME_WIDTH(&frame), height = GST_VIDEO_FRAME_HEIGHT(&frame);
			require(stride > width * 3, "padded real stream");
			auto image = defocus(static_cast<const uint8_t *>(GST_VIDEO_FRAME_PLANE_DATA(&frame, 0)),
					     width, height, stride, position - optimum);
			gst_video_frame_unmap(&frame);
			++scores;
			return Scan::contrast(image.data(), image.size(), width, height, stride, 3);
		});
		return state;
	}
};

static void scanChart(int low, int high, int target)
{
	Chart chart("checkers-8", low, high, target);
	chart.scan.request(true, Trigger::None);
	for (int i = 0; i < 8; ++i)
		require(chart.next() == State::Idle, "ordinary preview");
	require(chart.moves == 0 && chart.scores == 0, "preview has no actuator or frame-analysis access");
	chart.scan.request(true, Trigger::Start);
	require(chart.next() == State::Scanning && chart.moves == 1, "Auto and Start in same request");
	for (int i = 0; i < 5; ++i)
		require(chart.next(true) == State::Scanning, "stale exposures");
	require(chart.moves == 1 && chart.scores == 0, "stale exposures excluded");
	for (int i = 0; i < 180 && chart.state == State::Scanning; ++i)
		chart.next();
	require(chart.state == State::Focused, "chart focus lock");
	require(std::abs(chart.position - target) <= (high - low + 31) / 32, "optical optimum");
	require(chart.moves <= 19 && chart.scores == chart.moves * 2, "bounded two-frame samples");
	int moves = chart.moves;
	chart.scan.request({}, Trigger::Cancel);
	for (int i = 0; i < 8; ++i)
		require(chart.next() == State::Focused, "hold focused metadata on a late cancel");
	require(chart.moves == moves, "no repeated moves");
	std::cout << "PASS real RGB chart synthetic range=" << low << ".." << high
		  << " optical optimum=" << target << " selected=" << chart.position
		  << " moves=" << moves << " scored real frames=" << chart.scores << '\n';
}

int main(int argc, char **argv)
try {
	gst_init(&argc, &argv);
	const char *id = "/base/soc@0/cci@ac15000/i2c-bus@0/camera@20";
	require(Scan::supportsLens(id, "hi1339", "gt9768", 100, 700) &&
		!Scan::supportsLens("another/camera@20", "hi1339", "gt9768", 100, 700) &&
		!Scan::supportsLens(id, "ov08a10", "gt9768", 100, 700) &&
		!Scan::supportsLens(id, "hi1339", "", 100, 700) &&
		!Scan::supportsLens(id, "hi1339", "gt9768", 0, 1024) &&
		!Scan::supportsLens(id, "hi1339", "gt9768", 500, 500), "matched lens graph and calibrated range");
	scanChart(131, 837, 487);
	scanChart(254, 729, 622);
	Chart chart("black", 100, 700, 400);
	chart.scan.request(true, Trigger::Start);
	for (int i = 0; i < 100; ++i)
		if (chart.next() != State::Scanning)
			break;
	require(chart.state == State::Failed && chart.moves == 9, "uniform scene rejected");
	for (auto cancel : {true, false}) {
		chart.scan.request(true, Trigger::Start);
		require(chart.next() == State::Scanning, "restart scan");
		int moves = chart.moves;
		chart.scan.request(cancel, cancel ? Trigger::Cancel : Trigger::None);
		for (int i = 0; i < 12; ++i)
			require(chart.next() == State::Idle, "cancel/manual suppresses late frames");
		require(chart.moves == moves, "cancel has no late moves");
	}
	chart.scan.request(true, Trigger::Start);
	require(chart.next() == State::Scanning, "start before stop");
	int before = chart.moves;
	chart.scan.reset(100, 700);
	chart.scan.request({}, Trigger::Start);
	require(chart.next() == State::Idle && chart.moves == before, "restart defaults to Manual");
	chart.rejectMove = true;
	chart.scan.request(true, Trigger::Start);
	require(chart.next() == State::Failed, "actuator failure");
	chart.scan.reset(700, 700);
	chart.scan.request(true, Trigger::Start);
	require(chart.next() == State::Failed && chart.moves == before + 1, "reject invalid range");
	chart.rejectMove = false;
	chart.scan.reset(100, 700);
	chart.scan.request(true, Trigger::Start);
	require(chart.scan.failedFrame() == State::Failed && chart.next() == State::Failed &&
		chart.moves == before + 1, "lost trigger frame reports persistent failure without movement");
	chart.scan.request(true, Trigger::Start);
	require(chart.next() == State::Scanning && chart.scan.failedFrame() == State::Failed &&
		chart.next() == State::Failed, "bad frame interrupts an active scan");
	chart.scan.request(true, Trigger::Start);
	chart.scan.request({}, Trigger::Cancel);
	require(chart.scan.failedFrame() == State::Idle, "cancel wins on a bad frame");
	chart.scan.reset(100, 700);
	chart.scan.request(true, Trigger::Start);
	require(chart.next() == State::Scanning, "begin deadline case");
	auto unexpected = [](auto...) -> bool { throw std::runtime_error("late callback"); };
	require(chart.scan.frame(chart.clock + 46 * GST_SECOND, 0, unexpected, unexpected) == State::Failed,
		"stalled timestamp timeout");
	std::vector<uint8_t> rgb(32 * 32 * 4);
	require(!Scan::contrast(rgb.data(), rgb.size() - 1, 32, 32, 128, 4) &&
		!Scan::contrast(rgb.data(), rgb.size(), 32, 32, 40, 4) &&
		Scan::contrast(rgb.data(), rgb.size(), 32, 32, 128, 4).value() == 0, "safe RGBA plane bounds");
	std::cout << "PASS lens graph gating, flat scene, manual, explicit cancel, stop/restart, failed move, lost trigger frame, range, stale frames, bounded timeout and plane bounds\n";
	return 0;
} catch (const std::exception &e) {
	std::cerr << "FAIL " << e.what() << '\n';
	return 1;
}
