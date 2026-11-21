/* SPDX-License-Identifier: LGPL-2.1-or-later */
#pragma once

#include <cerrno>
#include <fcntl.h>
#include <iostream>
#include <sys/stat.h>
#include <unistd.h>

/* Mirror the CPU ISP's four allocator candidates. Opening a heap checks the
 * process's access policy. Allocating a buffer would require a separate ioctl. */
static inline void reportConfigResources()
{
	const char *heaps[] = { "/dev/dma_heap/linux,cma", "/dev/dma_heap/reserved",
				"/dev/dma_heap/system", "/dev/udmabuf" };
	for (const char *path : heaps) {
		struct stat info{};
		const int statRc = stat(path, &info) == 0 ? 0 : -errno;
		const bool character = statRc == 0 && S_ISCHR(info.st_mode);
		std::cout << "AF_CONFIG_RESOURCE path=" << path << " stat_rc=" << statRc
			  << " char=" << character << " open_rdwr_rc=";
		if (character) {
			const int fd = open(path, O_RDWR | O_CLOEXEC | O_NOCTTY);
			const int rc = fd >= 0 ? 0 : -errno;
			if (fd >= 0)
				close(fd);
			std::cout << rc;
		} else {
			std::cout << "none";
		}
		std::cout << std::endl;
	}

	/* Report the shipped search locations. The module signature and worker
	 * participate in IPA isolation. The generic tuning file is a valid fallback. */
	struct Resource { const char *path; int mode; };
	const Resource files[] = {
		{ "/opt/y700-camera/lib/libcamera/ipa/ipa_soft_simple.so", R_OK },
		{ "/opt/y700-camera/lib/libcamera/ipa/ipa_soft_simple.so.sign", R_OK },
		{ "/opt/y700-camera/libexec/libcamera/soft_ipa_proxy", X_OK },
		{ "/opt/y700-camera/share/libcamera/ipa/simple/hi1339.yaml", R_OK },
		{ "/opt/y700-camera/share/libcamera/ipa/simple/uncalibrated.yaml", R_OK },
	};
	for (const auto &resource : files) {
		const int rc = faccessat(AT_FDCWD, resource.path, resource.mode, AT_EACCESS) == 0 ? 0 : -errno;
		std::cout << "AF_CONFIG_RESOURCE path=" << resource.path << " access_mode=" << resource.mode
			  << " access_rc=" << rc << std::endl;
	}
}
