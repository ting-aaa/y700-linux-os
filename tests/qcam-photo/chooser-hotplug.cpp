/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "cam_select_dialog.h"

#include <QApplication>
#include <QComboBox>

#include <iostream>

int main(int argc, char **argv)
{
	QApplication app(argc, argv);
	libcamera::CameraManager manager;
	CameraSelectorDialog dialog(&manager, nullptr);
	auto *combo = dialog.findChild<QComboBox *>();
	if (!combo || !dialog.getCameraId().empty())
		return 1;

	const QString external = QStringLiteral("/fixture/unknown/camera@20");
	const QString front = QStringLiteral("/base/soc@0/cci@ac15000/i2c-bus@1/camera@10");
	const QString main = QStringLiteral("/base/soc@0/cci@ac15000/i2c-bus@0/camera@20");
	dialog.addCamera(external);
	dialog.selectCamera(main);
	if (combo->currentData().toString() != external || combo->currentText() != external)
		return 1;

	dialog.addCamera(front);
	dialog.selectCamera(front);
	dialog.addCamera(main);
	dialog.addCamera(main);
	if (combo->count() != 3 || combo->currentData().toString() != front)
		return 1;
	dialog.removeCamera(main);
	dialog.removeCamera(main);
	if (combo->count() != 2 || combo->currentData().toString() != front)
		return 1;
	dialog.removeCamera(front);
	if (combo->currentData().toString() != external)
		return 1;
	dialog.removeCamera(external);
	if (!dialog.getCameraId().empty())
		return 1;
	std::cout << "QCAM_CHOOSER_PASS empty single absent-main suffix hotplug current removal\n";
}
