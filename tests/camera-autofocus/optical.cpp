// SPDX-License-Identifier: LGPL-2.1-or-later
#include "optical-metric.h"
#include <libcamera/camera.h>
#include <libcamera/camera_manager.h>
#include <libcamera/control_ids.h>
#include <libcamera/formats.h>
#include <libcamera/framebuffer_allocator.h>
#include <linux/dma-buf.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <unistd.h>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <string_view>

using namespace libcamera;
using namespace optical;
using Clock = std::chrono::steady_clock;

static void require(bool ok, const char *message)
{
	if (!ok)
		throw std::runtime_error(message);
}

static bool syncRead(int fd, uint64_t stage)
{
	dma_buf_sync sync{stage | DMA_BUF_SYNC_READ};
	int rc;
	do {
		rc = ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync);
	} while (rc < 0 && (errno == EINTR || errno == EAGAIN));
	return rc == 0;
}

static Sample measureBuffer(const FrameBuffer &buffer, unsigned stride)
{
	const auto &metadata = buffer.metadata();
	require(buffer.planes().size() == 1 && metadata.planes().size() == 1, "unexpected_planes");
	const auto &plane = buffer.planes()[0];
	const size_t used = metadata.planes()[0].bytesused;
	require(plane.offset != FrameBuffer::Plane::kInvalidOffset && used <= plane.length &&
		used >= size_t(stride) * height, "incomplete_rgb_frame");
	// Linux dma-buf mmap offsets must be page aligned, even on a 64 KiB kernel.
	const size_t delta = plane.offset % sysconf(_SC_PAGESIZE);
	const size_t length = delta + used;
	const int fd = plane.fd.get();
	void *map = mmap(nullptr, length, PROT_READ, MAP_SHARED, fd, plane.offset - delta);
	require(map != MAP_FAILED, "map_failed");
	bool synced = syncRead(fd, DMA_BUF_SYNC_START);
	Sample value;
	if (synced) {
		value = measure(static_cast<const uint8_t *>(map) + delta, used, stride);
		synced = syncRead(fd, DMA_BUF_SYNC_END);
	}
	const int unmap = munmap(map, length);
	require(synced && unmap == 0, "dma_read_sync_failed");
	return value;
}

// No libcamera call or frame processing from its completion thread.
struct Completions {
	std::mutex mutex;
	std::condition_variable wake;
	std::deque<Request *> done;
	void push(Request *request)
	{
		std::lock_guard lock(mutex);
		done.push_back(request);
		wake.notify_one();
	}
	Request *next(Clock::time_point deadline)
	{
		std::unique_lock lock(mutex);
		require(wake.wait_until(lock, deadline, [&] { return !done.empty(); }), "frame_timeout");
		auto *request = done.front();
		done.pop_front();
		return request;
	}
};

enum class Action { Preview, TriggerOnce, Finish };
struct Trial {
	Window initial{}, final{};
	Summary before{};
	unsigned frames = 0, scans = 0, terminalFrames = 0, scanDrift = 0;
	int terminal = -1;
	bool baselineReady = false;
	static constexpr unsigned warmup = 24, settle = 3, maxPreview = warmup + 80 * groupSize;
	static constexpr unsigned frameLimit = maxPreview + 280;
	Action observe(int state, const Sample &value)
	{
		require(++frames <= frameLimit, "frame_limit");
		if (!baselineReady) {
			require(state == controls::AfStateIdle, "preview_af_not_idle");
			if (frames <= warmup)
				return Action::Preview;
			const auto sample = (frames - warmup - 1) % groupSize;
			initial[sample] = value;
			if (sample + 1 != groupSize)
				return Action::Preview;
			const Summary window = summarize(initial);
			baselineReady = before.stable && window.stable && sameExposure(before, window) &&
				sceneChange(before.average, window.average) <= .06 &&
				std::abs(before.average.mean - window.average.mean) <= .08 * window.average.mean &&
				std::abs(before.median - window.median) <= std::max(.006, .15 * window.median);
			before = window;
			std::cout << "AF_PREVIEW frames=" << frames << " ready=" << baselineReady
				  << " stable=" << before.stable << " sharpness=" << before.median
				  << " brightness=" << before.average.mean << " clipped=" << before.average.clipped
				  << " spread=" << before.drift << " gain_min=" << before.minGain
				  << " gain_max=" << before.maxGain << " time_min_us=" << before.minExposure
				  << " time_max_us=" << before.maxExposure << std::endl;
			if (!baselineReady) {
				require(frames < maxPreview, "preview_did_not_stabilize_no_trigger");
				return Action::Preview;
			}
			return Action::TriggerOnce;
		}
		if (state == controls::AfStateIdle && !scans && terminal == -1)
			return Action::Preview; // Requests queued before the single trigger.
		if (state == controls::AfStateScanning && terminal == -1) {
			++scans;
			if (value.gain < before.maxGain / 1.02 || value.gain > before.minGain * 1.02 ||
			    value.exposureUs < before.maxExposure / 1.02 || value.exposureUs > before.minExposure * 1.02 ||
			    sceneChange(value, before.average) > .12 ||
			    std::abs(value.mean - before.average.mean) > .20 * before.average.mean)
				++scanDrift;
			return Action::Preview;
		}
		require(state == controls::AfStateFailed || (state == controls::AfStateFocused && scans > 0),
			"af_sequence");
		require(terminal == -1 || terminal == state, "af_terminal_changed");
		if (terminal == -1) {
			terminal = state;
			std::cout << "AF_SCAN scanning_frames=" << scans << " controls=1 state="
				  << (state == controls::AfStateFocused ? "focused" : "failed") << std::endl;
		}
		if (++terminalFrames <= settle)
			return Action::Preview;
		final[terminalFrames - settle - 1] = value;
		return terminalFrames == settle + groupSize ? Action::Finish : Action::Preview;
	}
	const char *report() const
	{
		auto after = summarize(final);
		const bool focused = terminal == controls::AfStateFocused;
		const char *result = focused && scanDrift ? "inconclusive" : verdict(before, after, focused);
		std::cout << "AF_RESULT verdict=" << result << " after_frames=" << groupSize
			  << " frames=" << frames << " post_stable=" << after.stable
			  << " before=" << before.median << " after=" << after.median
			  << " baseline_spread=" << before.drift << " post_spread=" << after.drift
			  << " scene_drift=" << sceneChange(before.average, after.average)
			  << " scan_drift_frames=" << scanDrift << std::endl;
		return result;
	}
};

static void capture(Camera &camera)
{
	auto config = camera.generateConfiguration({StreamRole::Viewfinder});
	require(config && config->size() == 1, "no_viewfinder");
	auto &cfg = config->at(0);
	cfg.size = {width, height};
	cfg.pixelFormat = formats::ABGR8888;
	require(config->validate() != CameraConfiguration::Invalid && cfg.size == Size(width, height) &&
		cfg.pixelFormat == formats::ABGR8888 && camera.configure(config.get()) == 0, "no_cpu_rgb_mode");
	require(cfg.stride >= width * 4 && camera.controls().count(&controls::AfMode) &&
		camera.controls().count(&controls::AfTrigger) && camera.controls().count(&controls::AfState),
		"no_rear_isp_af_controls");
	FrameBufferAllocator allocator(camera.shared_from_this());
	Stream *stream = cfg.stream();
	require(allocator.allocate(stream) > 0, "buffer_allocation");
	std::vector<std::unique_ptr<Request>> requests;
	for (const auto &buffer : allocator.buffers(stream)) {
		auto req = camera.createRequest();
		require(req && req->addBuffer(stream, buffer.get()) == 0, "make_request");
		requests.push_back(std::move(req));
	}
	Completions complete;
	camera.requestCompleted.connect(&complete, &Completions::push);
	int rc = camera.start();
	if (rc < 0)
		camera.requestCompleted.disconnect(&complete);
	require(rc == 0, "start_failed");
	try {
		const auto deadline = Clock::now() + std::chrono::seconds(60);
		for (const auto &req : requests)
			require(camera.queueRequest(req.get()) == 0, "queue_failed");
		Trial trial;
		uint64_t lastTimestamp = 0;
		unsigned attempts = 0;
		for (;;) {
			require(++attempts <= Trial::frameLimit && Clock::now() < deadline, "capture_limit");
			Request *req = complete.next(deadline);
			require(req->status() == Request::RequestComplete, "capture_cancelled");
			const auto &buffer = *req->buffers().at(stream);
			auto status = buffer.metadata().status;
			Action action = Action::Preview;
			if (status != FrameMetadata::FrameStartup || trial.frames) {
				require(status == FrameMetadata::FrameSuccess, "bad_frame");
				require(buffer.metadata().timestamp > lastTimestamp, "stale_frame");
				lastTimestamp = buffer.metadata().timestamp;
				auto state = req->metadata().get(controls::AfState);
				require(state.has_value(), "missing_af_metadata");
				auto value = measureBuffer(buffer, cfg.stride);
				value.exposureUs = req->metadata().get(controls::ExposureTime).value_or(0);
				value.gain = req->metadata().get(controls::AnalogueGain).value_or(0);
				if ((trial.frames + 1) % 24 == 0)
					std::cout << "AF_EXPOSURE frame=" << trial.frames + 1
						  << " time_us=" << value.exposureUs << " analogue_gain=" << value.gain << std::endl;
				action = trial.observe(*state, value);
			}
			if (action == Action::Finish) {
				trial.report();
				break;
			}
			req->reuse(Request::ReuseBuffers);
			if (action == Action::TriggerOnce) {
				req->controls().set(controls::AfMode, controls::AfModeAuto);
				req->controls().set(controls::AfTrigger, controls::AfTriggerStart);
			}
			require(camera.queueRequest(req) == 0, "requeue_failed");
		}
	} catch (...) {
		camera.stop();
		camera.requestCompleted.disconnect(&complete);
		throw;
	}
	rc = camera.stop();
	camera.requestCompleted.disconnect(&complete);
	require(rc == 0, "stop_failed");
}

static Sample chart(int fine, int lighting = 0, bool shift = false)
{
	const unsigned stride = width * 4 + 64;
	std::vector<uint8_t> rgb(stride * height);
	for (unsigned y = 0; y < height; ++y) {
		for (unsigned x = 0; x < width; ++x) {
			const int coarse = x < width / 2 ? -30 : 30;
			const int edge = ((x / 4 + y / 4) % 2 ? fine : -fine);
			rgb[y * stride + x * 4 + 1] = 128 + lighting + (shift ? -coarse : coarse) + edge;
		}
	}
	Sample result = measure(rgb.data(), rgb.size(), stride);
	result.exposureUs = 12000;
	result.gain = 3;
	return result;
}

static void selfTest()
{
	auto simulate = [](Sample initial, Sample final, int state, const char *expected) {
		Trial trial;
		unsigned starts = 0;
		for (unsigned i = 0; i < Trial::warmup + 2 * groupSize; ++i)
			starts += trial.observe(controls::AfStateIdle, initial) == Action::TriggerOnce;
		require(starts == 1, "selftest_trigger_count");
		for (int i = 0; i < 5; ++i)
			require(trial.observe(controls::AfStateScanning, initial) == Action::Preview, "selftest_scan");
		for (unsigned i = 1; i <= Trial::settle + groupSize; ++i)
			require((trial.observe(state, final) == Action::Finish) == (i == Trial::settle + groupSize),
				"selftest_final_group");
		require(std::string_view(trial.report()) == expected, "selftest_verdict");
	};
	Sample soft = chart(7), sharp = chart(23);
	simulate(soft, sharp, controls::AfStateFocused, "improved");
	simulate(sharp, sharp, controls::AfStateFocused, "no_gain");
	simulate(soft, chart(23, 40), controls::AfStateFocused, "inconclusive");
	simulate(soft, chart(23, 0, true), controls::AfStateFocused, "inconclusive");
	std::vector<uint8_t> flat(width * height * 4, 128);
	Sample uniform = measure(flat.data(), flat.size(), width * 4);
	uniform.exposureUs = soft.exposureUs;
	uniform.gain = soft.gain;
	simulate(uniform, uniform, controls::AfStateFocused, "inconclusive");
	simulate(uniform, uniform, controls::AfStateFailed, "af_failed");
	Window unstable;
	for (unsigned i = 0; i < groupSize; ++i) unstable[i] = i % 2 ? soft : sharp;
	require(!summarize(unstable).stable, "selftest_unstable_preview");
	Trial adjusting;
	for (unsigned i = 0; i < Trial::warmup + 3 * groupSize; ++i)
		require(adjusting.observe(controls::AfStateIdle, i % 2 ? soft : sharp) == Action::Preview,
			"selftest_triggered_unstable");
	for (unsigned i = 0; i < 2 * groupSize; ++i)
		require((adjusting.observe(controls::AfStateIdle, soft) == Action::TriggerOnce) ==
			(i + 1 == 2 * groupSize), "selftest_wait_for_stability");
	Trial gaining;
	Sample dim = soft;
	for (unsigned i = 0; i < Trial::warmup + 4 * groupSize; ++i) {
		dim.gain = 4 + i * .0625;
		require(gaining.observe(controls::AfStateIdle, dim) == Action::Preview, "selftest_triggered_during_gain_ramp");
	}
	for (unsigned i = 0; i < 2 * groupSize; ++i)
		require((gaining.observe(controls::AfStateIdle, dim) == Action::TriggerOnce) ==
			(i + 1 == 2 * groupSize), "selftest_settled_gain");
	Window missing;
	missing.fill(soft);
	missing.back().gain = 0;
	require(!summarize(missing).stable, "selftest_missing_gain");
	Sample otherGain = sharp;
	otherGain.gain *= 1.5;
	simulate(soft, otherGain, controls::AfStateFocused, "inconclusive");
	std::cout << "AF_RESULT self_test=pass synthetic=1 camera_access=0" << std::endl;
}

int main(int argc, char **argv)
try {
	std::cout << std::fixed << std::setprecision(4);
	require(argc == 2, "specify_self_test_or_rear_af");
	const std::string_view mode = argv[1];
	if (mode == "--self-test") {
		selfTest();
		return 0;
	}
	require(mode == "--rear-af", "unknown_mode");
	const rlimit noCore{0, 0};
	require(setrlimit(RLIMIT_CORE, &noCore) == 0, "core_dump_limit");
	require(setenv("LIBCAMERA_SOFTISP_MODE", "cpu", 1) == 0, "cpu_isp_environment");
	CameraManager manager;
	require(manager.start() == 0, "camera_manager");
	auto camera = manager.get("/base/soc@0/cci@ac15000/i2c-bus@0/camera@20");
	require(camera != nullptr, "no_rear_hi1339");
	require(camera->acquire() == 0, "rear_busy_or_access_denied");
	try {
		capture(*camera);
	} catch (...) {
		camera->release();
		throw;
	}
	require(camera->release() == 0, "release_failed");
	camera.reset();
	manager.stop();
	return 0;
} catch (const std::runtime_error &error) {
	std::cerr << "AF_ERROR reason=" << error.what() << std::endl;
	return 1;
}
