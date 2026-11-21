/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <iostream>
#include <string>
#include <libcamera/camera.h>
#include <libcamera/camera_manager.h>
#include <libcamera/property_ids.h>

int main()
{
	using namespace libcamera;
	CameraManager manager;
	if (manager.start())
		return 1;
	const std::string prefix = "/base/soc@0/cci@";
	unsigned int seen = 0;
	for (const auto &camera : manager.cameras()) {
		const auto &id = camera->id();
		if (id.compare(0, prefix.size(), prefix))
			continue;
		auto config = camera->generateConfiguration({ StreamRole::Viewfinder });
		if (!config || config->size() != 1)
			return 1;
		config->orientation = Orientation::Rotate0;
		if (config->validate() == CameraConfiguration::Invalid || config->orientation != Orientation::Rotate270)
			return 1;
		const bool front = id == prefix + "ac15000/i2c-bus@1/camera@10";
		if (camera->properties().get(properties::Location) !=
		    (front ? properties::CameraLocationFront : properties::CameraLocationBack))
			return 1;
		std::cout << "QCAM_VIRTUAL_NEGOTIATED id=" << id << " orientation=Rotate270 facing="
			  << (front ? "front" : "rear") << '\n';
		++seen;
	}
	return seen == 3 ? 0 : 1;
}
