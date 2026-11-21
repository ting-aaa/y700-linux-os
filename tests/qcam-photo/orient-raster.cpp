// SPDX-License-Identifier: GPL-2.0-or-later
// Exercise the raster qcam viewfinder and its real JPEG writer on an asymmetric image.
#include "viewfinder_qt.h"
#include "photo_store.h"
#include "../common/image.h"

#include <QApplication>
#include <QFile>
#include <QPainter>
#include <QTemporaryDir>
#include <array>
#include <iostream>
#include <stdexcept>
#include <sys/mman.h>
#include <unistd.h>
#include <libcamera/property_ids.h>

using namespace libcamera;

static void require(bool condition, const char *message)
{
	if (!condition)
		throw std::runtime_error(message);
}

static const std::array<QColor, 4> colors = {
	QColor(220, 20, 20), QColor(20, 210, 30), QColor(10, 50, 220), QColor(230, 210, 10)
};

static void checkCorners(const QImage &image, QRect bounds, int turns)
{
	std::array<QPointF, 4> points = { QPointF(.25, .25), QPointF(.75, .25),
					   QPointF(.75, .75), QPointF(.25, .75) };
	for (int i = 0; i < 4; i++) {
		auto actual = image.pixelColor(bounds.x() + int(bounds.width() * points[i].x()),
					       bounds.y() + int(bounds.height() * points[i].y()));
		auto expected = colors[(i + 4 - turns) % 4];
		require(std::abs(actual.red() - expected.red()) < 10 &&
			std::abs(actual.green() - expected.green()) < 10 &&
			std::abs(actual.blue() - expected.blue()) < 10, "corner color mismatch");
	}
}

int main(int argc, char **argv)
try {
	QApplication app(argc, argv);
	constexpr int width = 96, height = 64, bytes = width * height * 4;
	int fd = memfd_create("qcam-synthetic-rgb", MFD_CLOEXEC);
	require(fd >= 0 && ftruncate(fd, bytes) == 0, "synthetic memfd");
	std::array<FrameBuffer::Plane, 1> planes = { FrameBuffer::Plane{ SharedFD(std::move(fd)), 0, bytes } };
	FrameBuffer buffer(planes);
	auto &metadata = const_cast<FrameMetadata &>(buffer.metadata());
	metadata.planes()[0].bytesused = bytes;
	auto rgb = Image::fromFrameBuffer(&buffer, Image::MapMode::ReadWrite);
	require(rgb != nullptr, "map synthetic frame");
	QImage input(rgb->data(0).data(), width, height, width * 4, QImage::Format_RGBX8888);
	{
		QPainter painter(&input);
		painter.fillRect(0, 0, width/2, height/2, colors[0]);
		painter.fillRect(width/2, 0, width/2, height/2, colors[1]);
		painter.fillRect(width/2, height/2, width/2, height/2, colors[2]);
		painter.fillRect(0, height/2, width/2, height/2, colors[3]);
	}

	ViewFinderQt view(nullptr);
	require(view.setFormat(formats::ABGR8888, QSize(width, height), ColorSpace::Sycc, width * 4) == 0,
		"raster format");
	view.resize(320, 320);
	view.show();
	view.render(&buffer, rgb.get());
	QTemporaryDir temp;
	require(temp.isValid(), "private photo directory");
	struct Lens {
		Orientation orientation;
		int location;
		std::array<int, 4> turns;
	};
	// Expected rotations in clockwise quarter turns: normal / left / inverted / right.
	const Lens lenses[] = {
		{ Orientation::Rotate270, properties::CameraLocationBack, { 1, 2, 3, 0 } },
		{ Orientation::Rotate270, properties::CameraLocationFront, { 1, 0, 3, 2 } },
		{ Orientation::Rotate0, properties::CameraLocationBack, { 0, 1, 2, 3 } },
		{ Orientation::Rotate90, properties::CameraLocationBack, { 3, 0, 1, 2 } },
		{ Orientation::Rotate180, properties::CameraLocationBack, { 2, 3, 0, 1 } },
		{ Orientation::Rotate0Mirror, properties::CameraLocationBack, { 0, 3, 2, 1 } },
		{ Orientation::Rotate90Mirror, properties::CameraLocationBack, { 1, 0, 3, 2 } },
		{ Orientation::Rotate180Mirror, properties::CameraLocationFront, { 2, 3, 0, 1 } },
		{ Orientation::Rotate270Mirror, properties::CameraLocationFront, { 3, 0, 1, 2 } },
		{ Orientation::Rotate270, properties::CameraLocationExternal, { 1, 1, 1, 1 } }
	};
	unsigned cases = 0;
	for (const Lens &lens : lenses) {
		view.setCameraOrientation(lens.orientation, lens.location);
		for (int p = 0; p < 4; ++p) {
			int turns = lens.turns[p];
			view.setDisplayRotation(90 * p);
			app.processEvents();
			QImage screenshot = view.grab().toImage();
			QSize native = turns % 2 ? QSize(height, width) : QSize(width, height);
			QRect visible(QPoint(0, 0), native.scaled(screenshot.size(), Qt::KeepAspectRatio));
			visible.moveCenter(screenshot.rect().center());
			checkCorners(screenshot, visible, turns);
			auto black = screenshot.pixelColor(2, 2);
			require(black.red() < 10 && black.green() < 10 && black.blue() < 10, "letterbox");
			QString path, error;
			require(qcam_photo::save(view.getCurrentImage(), temp.path(), &path, &error), "JPEG save");
			QImage saved(path);
			require(!saved.isNull() && saved.size() == native, "JPEG pixel dimensions");
			checkCorners(saved, saved.rect(), turns);
			require(QFile::remove(path), "remove synthetic photo");
			++cases;
		}
	}
	view.stop();
	std::cout << "PASS orientation_cases=" << cases << " preview_corners=" << 4*cases
		  << " jpeg_corners=" << 4*cases << " scale=" << view.devicePixelRatioF() << '\n';
	return 0;
} catch (const std::exception &e) {
	std::cerr << "FAIL " << e.what() << '\n';
	return 1;
}
