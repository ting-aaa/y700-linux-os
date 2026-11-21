// SPDX-License-Identifier: LGPL-2.1-or-later
// Exercise the installed release's isolated ARM64 IPA worker using anonymous
// statistics buffers and synthetic delayed sensor controls, without a camera.
#include <libcamera/base/event_dispatcher.h>
#include <libcamera/base/thread.h>
#include <libcamera/base/timer.h>
#include <libcamera/camera_manager.h>
#include <libcamera/control_ids.h>
#include <libcamera/internal/pipeline_handler.h>
#include <libcamera/internal/software_isp/debayer_params.h>
#include <libcamera/internal/software_isp/swisp_stats.h>
#include <libcamera/ipa/soft_ipa_proxy.h>
#include <linux/videodev2.h>
#include <sys/mman.h>
#include <unistd.h>
#include <iostream>
#include "bracket.h"

using namespace libcamera;
using namespace std::chrono_literals;

static void check(bool ok, const char *message)
{
	if (!ok)
		throw std::runtime_error(message);
}

static SharedFD anonymousBuffer(size_t bytes)
{
	UniqueFD fd(memfd_create("synthetic", MFD_CLOEXEC));
	check(fd.isValid() && ftruncate(fd.get(), bytes) == 0, "anonymous_buffer");
	return SharedFD(std::move(fd));
}

struct Observations {
	uint32_t frame = 0;
	int time = -1, lines = -1, code = -1;
	float gain = -1;
	unsigned metadata = 0, proposals = 0, params = 0;
};

static void exercise(PipelineHandler &pipeline, bool supported)
{
	auto selected = pipeline.createIPA<ipa::soft::IPAProxySoft>(0, 0);
	check(dynamic_cast<ipa::soft::IPAProxySoftIsolated *>(selected.get()), "isolated_worker");
	auto &ipa = *selected;
	const Control<int32_t> exposure(V4L2_CID_EXPOSURE, "Exposure", "v4l2", ControlId::Direction::In);
	const Control<int32_t> gain(V4L2_CID_ANALOGUE_GAIN, "Gain", "v4l2", ControlId::Direction::In);
	const ControlIdMap ids{{ exposure.id(), &exposure }, { gain.id(), &gain }};
	ControlInfoMap sensorControls({ { &exposure, ControlInfo(4, 3328, 16) },
					{ &gain, ControlInfo(0, 240, 0) } }, ids);
	IPACameraSensorInfo sensor{};
	sensor.model = "hi1339";
	sensor.bitsPerPixel = 10;
	sensor.pixelRate = 576000000;
	sensor.minLineLength = supported ? 5760 : 5500;
	auto stats = anonymousBuffer(sizeof(SwIspStats));
	auto params = anonymousBuffer(sizeof(DebayerParams));
	ControlInfoMap controlsMap;
	bool ccm = false;
	const IPASettings settings{ "/opt/y700-camera/share/libcamera/ipa/simple/uncalibrated.yaml", "hi1339" };
	check(ipa.init(settings, stats, params, sensor, sensorControls, &controlsMap, &ccm) == 0, "stock_init");
	check(bool(controlsMap.count(controls::ExposureTimeMode.id())) == supported, "mode_gate");
	check(ipa.configure({ sensorControls }) == 0 && ipa.start() == 0, "stock_configure_start");
	Observations seen;
	ipa.metadataReady.connect(&seen, [&](uint32_t frame, const ControlList &actual) {
		seen.frame = frame;
		seen.time = actual.get(controls::ExposureTime).value_or(-1);
		seen.gain = actual.get(controls::AnalogueGain).value_or(-1);
		++seen.metadata;
	});
	ipa.setSensorControls.connect(&seen, [&](const ControlList &next) {
		seen.lines = next.get(exposure).value_or(-1);
		seen.code = next.get(gain).value_or(-1);
		++seen.proposals;
	});
	ipa.setIspParams.connect(&seen, [&]() { ++seen.params; });

	// The first modelled sensor frame reports 16 lines @ 1x. The original
	// AGC holds that proposal on the zero-initialized (invalid) statistics.
	uint32_t frame = 0;
	int lines = 16, code = 0;
	auto one = [&](const bracket::Point *target) {
		ControlList request(controls::controls), delayed(sensorControls);
		if (target) {
			request.set(controls::ExposureTimeMode, controls::ExposureTimeModeManual);
			request.set(controls::AnalogueGainMode, controls::AnalogueGainModeManual);
			request.set(controls::ExposureTime, target->timeUs);
			request.set(controls::AnalogueGain, target->gain);
		} else {
			request.set(controls::ExposureTimeMode, controls::ExposureTimeModeAuto);
			request.set(controls::AnalogueGainMode, controls::AnalogueGainModeAuto);
		}
		delayed.set(exposure, lines);
		delayed.set(gain, code);
		ipa.queueRequest(frame, request);
		ipa.computeParams(frame);
		ipa.processStats(frame, 0, delayed);
		Timer timeout;
		timeout.start(2s);
		while (timeout.isRunning() && (seen.metadata <= frame || seen.proposals <= frame || seen.params <= frame))
			Thread::current()->eventDispatcher()->processEvents();
		check(seen.metadata == frame + 1 && seen.proposals == frame + 1 && seen.params == frame + 1 &&
		      seen.frame == frame, "isolated_ipc_frame");
		if (supported)
			check(seen.time == 10 * lines && seen.gain == 1.f + code / 16.f, "actual_metadata_relabelled");
		++frame;
	};
	if (supported) {
		bracket::Progress progress;
		for (auto &point : bracket::points) {
			for (unsigned n = 0; n < bracket::stableFrames + 1; ++n) {
				one(&point);
				check(seen.lines == point.timeUs / 10 && seen.code == (point.gain - 1) * 16, "manual_control");
				check(progress.observe(seen.time, seen.gain) == (n == bracket::stableFrames), "settling");
				lines = seen.lines;
				code = seen.code;
			}
			progress.advance();
		}
		one(nullptr);
		check(seen.lines == 16 && seen.code == 0, "auto_passthrough");
		bracket::Progress stalled;
		for (unsigned n = 0; n < bracket::limitPerPoint; ++n)
			check(!stalled.observe(n % 4 ? 2000 : 0, 1), "intermittent_metadata_accepted");
	} else {
		one(&bracket::points[2]);
		check(seen.lines == 16 && seen.code == 0, "wrong_mode_override");
	}
	ipa.stop();
	std::cout << "BRACKET_IPA_TEST isolated=1 geometry_match=" << supported << " frames=" << frame
		  << " metadata=" << seen.metadata << " proposals=" << seen.proposals << " params=" << seen.params << std::endl;
}

int main(int argc, char **argv)
try {
	check(argc == 2 && setenv("LIBCAMERA_IPA_MODULE_PATH", argv[1], 1) == 0 &&
	      setenv("LIBCAMERA_IPA_FORCE_ISOLATION", "1", 1) == 0, "module_directory");
	CameraManager manager;
	check(manager.start() == 0, "start_manager");
	const auto *factory = PipelineHandlerFactoryBase::getFactoryByName("simple");
	check(factory, "release_simple_pipeline");
	auto pipeline = factory->create(&manager);
	exercise(*pipeline, true);
	exercise(*pipeline, false);
	pipeline.reset();
	manager.stop();
	return 0;
} catch (const std::exception &e) {
	std::cerr << "BRACKET_IPA_ERROR reason=" << e.what() << std::endl;
	return 1;
}
