/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once

#include <QPushButton>
#include <libcamera/controls.h>

class QStatusBar;

class FocusButton : public QPushButton
{
public:
	explicit FocusButton(QStatusBar *status);
	void start(const libcamera::ControlInfoMap &controls);
	void stop();
	void prepare(libcamera::ControlList &controls);
	void completed(const libcamera::ControlList &sent, const libcamera::ControlList &metadata);
	void queueFailed(const libcamera::ControlList &sent);

private:
	enum class Stage { Idle, SendStart, Starting, Scanning, SendCancel, Cancelling };
	void setStage(Stage stage);
	void finish(const QString &message);
	QStatusBar *status_;
	const bool chinese_;
	Stage stage_ = Stage::Idle;
};
