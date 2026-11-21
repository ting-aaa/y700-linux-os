/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "focus_button.h"

#include <libcamera/control_ids.h>
#include <QApplication>
#include <QLocale>
#include <QStatusBar>
#include <cstdlib>
#include <iostream>

using namespace libcamera;

static void check(bool result, const char *description)
{
	if (!result) {
		std::cerr << description << '\n';
		std::exit(1);
	}
}

int main(int argc, char **argv)
{
	QApplication app(argc, argv);
	QLocale::setDefault(QLocale::c());
	QStatusBar bar;
	FocusButton button(&bar);
	bar.addPermanentWidget(&button);
	bar.show();
	const ControlInfoMap capable({
		{ &controls::AfMode, ControlInfo(controls::AfModeValues) },
		{ &controls::AfTrigger, ControlInfo(controls::AfTriggerValues) },
	}, controls::controls);
	const ControlInfoMap fixed;
	ControlList start(controls::controls), cancel(controls::controls);
	ControlList none(controls::controls), outcome(controls::controls);
	button.start(fixed);
	check(button.isHidden(), "fixed focus");
	button.start(capable);
	check(button.isVisible() && button.text() == "Focus", "controllable lens");
	check(button.minimumHeight() >= 48 && button.minimumWidth() >= 96 &&
	      button.devicePixelRatioF() == 2, "200% touch target");
	button.prepare(none);
	check(none.empty(), "preview must not start autofocus");
	button.click();
	button.click();
	button.prepare(none);
	check(none.empty(), "cancel before queue");
	button.click();
	button.prepare(start);
	check(start.get(controls::AfMode) == controls::AfModeAuto &&
	      start.get(controls::AfTrigger) == controls::AfTriggerStart, "start request");
	button.prepare(none);
	check(none.empty(), "send start only once");
	outcome.set(controls::AfState, controls::AfStateFocused);
	button.completed(none, outcome);
	check(button.text() == "Cancel focus", "ignore previous scan result");
	outcome.set(controls::AfState, controls::AfStateScanning);
	button.completed(start, outcome);
	outcome.set(controls::AfState, controls::AfStateFocused);
	button.completed(none, outcome);
	check(button.text() == "Focus" && bar.currentMessage() == "Focused", "sharp result");
	button.click();
	button.prepare(start);
	button.click();
	button.prepare(cancel);
	check(cancel.get(controls::AfTrigger) == controls::AfTriggerCancel &&
	      !button.isEnabled(), "queue cancellation");
	button.completed(start, outcome);
	check(!button.isEnabled(), "wait for cancel acknowledgement");
	button.completed(cancel, none);
	check(button.isEnabled() && bar.currentMessage() == "Focus cancelled", "cancelled result");
	button.click();
	button.prepare(start);
	outcome.set(controls::AfState, controls::AfStateFailed);
	button.completed(start, outcome);
	check(bar.currentMessage() == "Could not focus. Try again.", "low contrast feedback");
	button.click();
	button.prepare(start);
	button.queueFailed(start);
	check(button.text() == "Focus" && bar.currentMessage() == "Focus request failed", "queue failure");
	button.click();
	button.stop();
	button.start(fixed);
	button.prepare(none);
	check(button.isHidden() && none.empty(), "switch lenses while a start is pending");
	QLocale::setDefault(QLocale::Chinese);
	FocusButton chinese(&bar);
	chinese.start(capable);
	check(chinese.text() == QStringLiteral("对焦"), "Chinese focus label");
	chinese.click();
	check(chinese.text() == QStringLiteral("取消对焦"), "Chinese cancel label");
	std::cout << "QCAM_FOCUS_PASS preview start cancel stale success failure switch zh scale=2\n";
}
