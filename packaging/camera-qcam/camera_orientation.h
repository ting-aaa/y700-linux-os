/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once

#include <QObject>
#include <libcamera/orientation.h>

struct _XDisplay;
class QSocketNotifier;

class PanelRotation : public QObject
{
	Q_OBJECT
public:
	explicit PanelRotation(QObject *parent);
	~PanelRotation();
	int degrees() const { return degrees_; }

Q_SIGNALS:
	void changed();

private:
	int readDegrees() const;
	_XDisplay *display_ = nullptr;
	QSocketNotifier *notifier_ = nullptr;
	int degrees_ = 0;
};

/* Return a clockwise in-memory rotation. Leave horizontal mirroring policy intact. */
int cameraDisplayRotation(libcamera::Orientation buffer, int location, int panelDegrees);
