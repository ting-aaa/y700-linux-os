/* SPDX-License-Identifier: LGPL-2.1-or-later */
// Private HI1339 diagnostic adapter for the exact release soft IPA.
#include <libcamera/control_ids.h>
#include <libcamera/ipa/ipa_module_info.h>
#include <libcamera/ipa/soft_ipa_interface.h>
#include <linux/videodev2.h>
#include <dlfcn.h>
#include <memory>
#include <optional>
#include "bracket.h"

namespace libcamera {
using ipa::soft::IPASoftInterface;

class BracketIpa final : public IPASoftInterface
{
	static bool hasRange(const ControlInfoMap &controls)
	{
		if (!controls.count(V4L2_CID_EXPOSURE) || !controls.count(V4L2_CID_ANALOGUE_GAIN))
			return false;
		const auto &time = controls.at(V4L2_CID_EXPOSURE);
		const auto &gain = controls.at(V4L2_CID_ANALOGUE_GAIN);
		return time.min().get<int32_t>() <= 200 && time.max().get<int32_t>() >= 3200 &&
		       gain.min().get<int32_t>() == 0 && gain.max().get<int32_t>() >= 112;
	}
public:
	explicit BracketIpa(void *handle, IPASoftInterface *stock) : handle_(handle), stock_(stock)
	{
		stock_->metadataReady.connect(this, [this](uint32_t frame, const ControlList &actual) {
			metadataReady.emit(frame, actual);
		});
		stock_->setIspParams.connect(this, [this]() { setIspParams.emit(); });
		stock_->setSensorControls.connect(this, [this](const ControlList &automatic) {
			if (!active_) {
				setSensorControls.emit(automatic);
				return;
			}
			ControlList next = automatic;
			// Pinned HI1339: 10 us per line, analogue gain = 1 + code / 16.
			next.set(V4L2_CID_EXPOSURE, active_->timeUs / 10);
			next.set(V4L2_CID_ANALOGUE_GAIN, static_cast<int32_t>((active_->gain - 1) * 16));
			setSensorControls.emit(next);
		});
	}
	~BracketIpa() override
	{
		stock_.reset();
		dlclose(handle_);
	}
	int32_t init(const IPASettings &settings, const SharedFD &stats, const SharedFD &params,
		     const IPACameraSensorInfo &sensor, const ControlInfoMap &sensorControls,
		     ControlInfoMap *publicControls, bool *ccm) override
	{
		const int rc = stock_->init(settings, stats, params, sensor, sensorControls, publicControls, ccm);
		enabled_ = !rc && settings.sensorModel == "hi1339" && sensor.bitsPerPixel == 10 &&
			   sensor.pixelRate == 576000000 && sensor.minLineLength == 5760 && hasRange(sensorControls);
		if (!enabled_)
			return rc;
		ControlInfoMap::Map map(publicControls->begin(), publicControls->end());
		map[&controls::ExposureTimeMode] = ControlInfo(controls::ExposureTimeModeValues, controls::ExposureTimeModeAuto);
		map[&controls::AnalogueGainMode] = ControlInfo(controls::AnalogueGainModeValues, controls::AnalogueGainModeAuto);
		const std::array<ControlValue, 2> times{ 2000, 32000 }, gains{ 1.f, 8.f };
		map[&controls::ExposureTime] = ControlInfo(times, 2000);
		map[&controls::AnalogueGain] = ControlInfo(gains, 1.f);
		*publicControls = ControlInfoMap(std::move(map), controls::controls);
		return 0;
	}
	int32_t configure(const ipa::soft::IPAConfigInfo &config) override
	{
		if (enabled_ && !hasRange(config.sensorControls))
			return -ERANGE;
		return stock_->configure(config);
	}
	int32_t start() override { pending_.fill(std::nullopt); return stock_->start(); }
	void stop() override { stock_->stop(); pending_.fill(std::nullopt); }
	void computeParams(uint32_t frame) override { stock_->computeParams(frame); }
	void queueRequest(uint32_t frame, const ControlList &request) override
	{
		auto &slot = pending_[frame % pending_.size()];
		slot.reset();
		if (enabled_ && request.get(controls::ExposureTimeMode) == controls::ExposureTimeModeManual &&
		    request.get(controls::AnalogueGainMode) == controls::AnalogueGainModeManual) {
			const auto time = request.get(controls::ExposureTime);
			const auto gain = request.get(controls::AnalogueGain);
			if ((time == 2000 || time == 32000) && (gain == 1.f || gain == 8.f))
				slot = Pending{ frame, { *time, *gain } };
		}
		stock_->queueRequest(frame, request);
	}
	void processStats(uint32_t frame, uint32_t id, const ControlList &sensor) override
	{
		auto &slot = pending_[frame % pending_.size()];
		active_ = slot && slot->frame == frame ? &slot->point : nullptr;
		stock_->processStats(frame, id, sensor);
		if (active_)
			slot.reset();
		active_ = nullptr;
	}
private:
	void *handle_;
	std::unique_ptr<IPASoftInterface> stock_;
	bool enabled_ = false;
	// Match the release IPA's 16 in-flight frame contexts, including sequence wrap.
	struct Pending { uint32_t frame; bracket::Point point; };
	std::array<std::optional<Pending>, 16> pending_;
	const bracket::Point *active_ = nullptr;
};

extern "C" {
const IPAModuleInfo ipaModuleInfo = { IPA_MODULE_API_VERSION, 0, "simple", "simple" };
IPAInterface *ipaCreate()
{
	void *h = dlopen("/opt/y700-camera/lib/libcamera/ipa/ipa_soft_simple.so", RTLD_LOCAL | RTLD_NOW);
	if (!h)
		return nullptr;
	auto create = reinterpret_cast<IPAInterface *(*)()>(dlsym(h, "ipaCreate"));
	auto *stock = create ? static_cast<IPASoftInterface *>(create()) : nullptr;
	if (!stock) {
		dlclose(h);
		return nullptr;
	}
	return new BracketIpa(h, stock);
}
}
}
