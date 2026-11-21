/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "camera_orientation.h"

#include <cstring>

#include <QGuiApplication>
#include <QSocketNotifier>
#include <libcamera/property_ids.h>
#include <X11/Xlib.h>
#include <X11/extensions/Xrandr.h>

PanelRotation::PanelRotation(QObject *parent)
	: QObject(parent)
{
	if (QGuiApplication::platformName() != QStringLiteral("xcb"))
		return;
	display_ = XOpenDisplay(nullptr);
	int major = 0, minor = 0;
	if (!display_ || !XRRQueryVersion(display_, &major, &minor) || (major == 1 && minor < 3))
		return;

	XRRSelectInput(display_, DefaultRootWindow(display_),
		       RRScreenChangeNotifyMask | RRCrtcChangeNotifyMask | RROutputChangeNotifyMask);
	degrees_ = readDegrees();
	notifier_ = new QSocketNotifier(ConnectionNumber(display_), QSocketNotifier::Read, this);
	connect(notifier_, &QSocketNotifier::activated, this, [this]() {
		while (XPending(display_)) {
			XEvent event;
			XNextEvent(display_, &event);
		}
		int degrees = readDegrees();
		if (degrees != degrees_) {
			degrees_ = degrees;
			Q_EMIT changed();
		}
	});
}

PanelRotation::~PanelRotation()
{
	if (notifier_)
		notifier_->setEnabled(false);
	if (display_)
		XCloseDisplay(display_);
}

int PanelRotation::readDegrees() const
{
	int degrees = 0;
	auto *resources = XRRGetScreenResourcesCurrent(display_, DefaultRootWindow(display_));
	if (!resources)
		return degrees;
	for (int i = 0; i < resources->noutput; ++i) {
		auto *output = XRRGetOutputInfo(display_, resources, resources->outputs[i]);
		if (!output)
			continue;
		bool panel = output->nameLen == 5 && std::memcmp(output->name, "DSI-1", 5) == 0;
		if (panel && output->connection == RR_Connected && output->crtc) {
			auto *crtc = XRRGetCrtcInfo(display_, resources, output->crtc);
			if (crtc) {
				// RandR rotates the displayed desktop counterclockwise on the native panel.
				if (crtc->rotation & RR_Rotate_90) degrees = 90;
				else if (crtc->rotation & RR_Rotate_180) degrees = 180;
				else if (crtc->rotation & RR_Rotate_270) degrees = 270;
				XRRFreeCrtcInfo(crtc);
			}
		}
		XRRFreeOutputInfo(output);
		if (panel)
			break;
	}
	XRRFreeScreenResources(resources);
	return degrees;
}

int cameraDisplayRotation(libcamera::Orientation buffer, int location, int panelDegrees)
{
	using namespace libcamera;
	int rotation;
	bool mirrored;
	switch (buffer) {
	case Orientation::Rotate0:         rotation = 0;   mirrored = false; break;
	case Orientation::Rotate0Mirror:   rotation = 0;   mirrored = true;  break;
	case Orientation::Rotate90:        rotation = 90;  mirrored = false; break;
	case Orientation::Rotate90Mirror:  rotation = 90;  mirrored = true;  break;
	case Orientation::Rotate180:       rotation = 180; mirrored = false; break;
	case Orientation::Rotate180Mirror: rotation = 180; mirrored = true;  break;
	case Orientation::Rotate270:       rotation = 270; mirrored = false; break;
	case Orientation::Rotate270Mirror: rotation = 270; mirrored = true;  break;
	default: return 0;
	}
	int body = 0;
	if (location == properties::CameraLocationBack)
		body = panelDegrees;
	else if (location == properties::CameraLocationFront)
		body = -panelDegrees;
	// The buffer represents a clockwise rotation followed by an optional mirror.
	// A pure rotation on mirrored coordinates acts in the opposite direction.
	return ((mirrored ? rotation - body : body - rotation) + 720) % 360;
}
