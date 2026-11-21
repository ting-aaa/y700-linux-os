/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "focus_button.h"

#include <algorithm>
#include <libcamera/control_ids.h>
#include <QLocale>
#include <QStatusBar>

using namespace libcamera;

static bool offers(const ControlInfoMap &map, const Control<int32_t> &id, int value)
{
	const auto it = map.find(&id);
	if (it == map.end())
		return false;
	const auto &info = it->second;
	const auto &values = info.values();
	if (values.empty())
		return info.min().get<int32_t>() <= value && value <= info.max().get<int32_t>();
	return std::any_of(values.begin(), values.end(), [value](const ControlValue &v) {
		return v.get<int32_t>() == value;
	});
}

FocusButton::FocusButton(QStatusBar *status)
	: QPushButton(status), status_(status), chinese_(QLocale().language() == QLocale::Chinese)
{
	setObjectName("focusButton");
	setMinimumSize(96, 48);
	stop();
	connect(this, &QPushButton::clicked, this, [this]() {
		switch (stage_) {
		case Stage::Idle:
			setStage(Stage::SendStart);
			break;
		case Stage::SendStart:
			setStage(Stage::Idle);
			break;
		case Stage::Starting:
		case Stage::Scanning:
			setStage(Stage::SendCancel);
			break;
		default:
			break;
		}
	});
}

void FocusButton::setStage(Stage stage)
{
	stage_ = stage;
	const bool cancelling = stage == Stage::SendCancel || stage == Stage::Cancelling;
	setEnabled(!cancelling);
	if (stage == Stage::Idle)
		setText(chinese_ ? QStringLiteral("对焦") : QStringLiteral("Focus"));
	else if (cancelling)
		setText(chinese_ ? QStringLiteral("正在取消…") : QStringLiteral("Cancelling…"));
	else
		setText(chinese_ ? QStringLiteral("取消对焦") : QStringLiteral("Cancel focus"));
}

void FocusButton::start(const ControlInfoMap &map)
{
	setStage(Stage::Idle);
	setVisible(offers(map, controls::AfMode, controls::AfModeAuto) &&
		   offers(map, controls::AfTrigger, controls::AfTriggerStart) &&
		   offers(map, controls::AfTrigger, controls::AfTriggerCancel));
}

void FocusButton::stop()
{
	setStage(Stage::Idle);
	hide();
}

void FocusButton::prepare(ControlList &list)
{
	if (stage_ == Stage::SendStart) {
		list.set(controls::AfMode, controls::AfModeAuto);
		list.set(controls::AfTrigger, controls::AfTriggerStart);
		setStage(Stage::Starting);
	} else if (stage_ == Stage::SendCancel) {
		list.set(controls::AfTrigger, controls::AfTriggerCancel);
		setStage(Stage::Cancelling);
	}
}

void FocusButton::finish(const QString &message)
{
	setStage(Stage::Idle);
	status_->showMessage(message, 3000);
}

void FocusButton::completed(const ControlList &sent, const ControlList &metadata)
{
	const auto trigger = sent.get(controls::AfTrigger);
	if (stage_ == Stage::Cancelling && trigger == controls::AfTriggerCancel) {
		finish(chinese_ ? QStringLiteral("对焦已取消") : QStringLiteral("Focus cancelled"));
		return;
	}
	// Earlier frames can still carry the result of the previous scan.
	if (stage_ == Stage::Starting && trigger == controls::AfTriggerStart)
		setStage(Stage::Scanning);
	if (stage_ != Stage::Scanning)
		return;

	const auto state = metadata.get(controls::AfState);
	if (state == controls::AfStateFocused)
		finish(chinese_ ? QStringLiteral("已合焦") : QStringLiteral("Focused"));
	else if (state == controls::AfStateFailed)
		finish(chinese_ ? QStringLiteral("未能合焦，请重试") : QStringLiteral("Could not focus. Try again."));
}

void FocusButton::queueFailed(const ControlList &sent)
{
	if (sent.contains(controls::AfTrigger.id()))
		finish(chinese_ ? QStringLiteral("对焦请求失败") : QStringLiteral("Focus request failed"));
}
