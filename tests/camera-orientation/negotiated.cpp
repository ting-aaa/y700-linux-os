/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <iostream>
#include <libcamera/camera.h>
#include <libcamera/camera_manager.h>
#include <libcamera/property_ids.h>

int main()
{
    libcamera::CameraManager manager;
    if (manager.start())
        return 1;
    unsigned int count = 0;
    for (const auto &camera : manager.cameras()) {
        const auto &properties = camera->properties();
        const auto model = properties.get(libcamera::properties::Model);
        if (!model || (*model != "hi1339" && *model != "s5k4h7" && *model != "sc202cs"))
            continue;
        auto config = camera->generateConfiguration({ libcamera::StreamRole::Viewfinder });
        if (!config || config->size() != 1)
            return 1;
        config->orientation = libcamera::Orientation::Rotate0;
        if (config->validate() == libcamera::CameraConfiguration::Invalid)
            return 1;
        const auto rotation = properties.get(libcamera::properties::Rotation);
        const auto location = properties.get(libcamera::properties::Location);
        if (!rotation || !location)
            return 1;
        std::cout << "VIEWFINDER model=" << *model << " rotation_property=" << *rotation
                  << " location=" << *location << " requested=Rotate0 negotiated="
                  << config->orientation << "\n";
        ++count;
    }
    std::cout << "CAMERA_ORIENTATION lenses=" << count
              << " acquired=0 configured=0 started=0 frames=0\n";
    return count == 3 ? 0 : 1;
}
