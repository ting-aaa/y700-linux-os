/* Watch only the active internal DSI-1 CRTC. No camera, image or input access. */
#include <X11/Xlib.h>
#include <X11/extensions/Xrandr.h>
#include <errno.h>
#include <poll.h>
#include <string.h>

#include "panel-orientation.h"

static int quarters(Display *display, Window root)
{
	XRRScreenResources *resources = XRRGetScreenResourcesCurrent(display, root);
	if (!resources)
		return -1;
	int result = -1;
	for (int i = 0; i < resources->noutput; ++i) {
		XRROutputInfo *output = XRRGetOutputInfo(display, resources, resources->outputs[i]);
		if (!output)
			continue;
		if (output->connection == RR_Connected && output->crtc &&
		    output->nameLen == 5 && !memcmp(output->name, "DSI-1", 5)) {
			XRRCrtcInfo *crtc = XRRGetCrtcInfo(display, resources, output->crtc);
			if (crtc) {
				switch (crtc->rotation) {
				case RR_Rotate_0: result = 0; break;
				case RR_Rotate_90: result = 1; break;
				case RR_Rotate_180: result = 2; break;
				case RR_Rotate_270: result = 3; break;
				}
				XRRFreeCrtcInfo(crtc);
			}
		}
		XRRFreeOutputInfo(output);
		if (result >= 0)
			break;
	}
	XRRFreeScreenResources(resources);
	return result;
}

int main(void)
{
	Display *display = XOpenDisplay(NULL);
	int event, error;
	if (!display || !XRRQueryExtension(display, &event, &error))
		return 0;
	Window root = DefaultRootWindow(display);
	XRRSelectInput(display, root, RRScreenChangeNotifyMask | RRCrtcChangeNotifyMask |
	               RROutputChangeNotifyMask);
	int orientation = quarters(display, root);
	if (orientation < 0)
		return 0;
	int lock;
	uint64_t *word = y700_map_orientation(1, &lock);
	if (!word)
		return 0;
	struct pollfd fd = { ConnectionNumber(display), POLLIN, 0 };
	for (;;) {
		uint64_t now = y700_monotonic_seconds();
		uint64_t state = orientation < 0 || !now ? 0 : (now << 2) | (unsigned)orientation;
		__atomic_store_n(word, state, __ATOMIC_RELEASE);
		if (!XPending(display)) {
			int n = poll(&fd, 1, 2000);
			if ((n < 0 && errno != EINTR) || fd.revents & (POLLHUP | POLLERR | POLLNVAL))
				break;
			if (n <= 0)
				continue;
		}
		while (XPending(display)) {
			XEvent ev;
			XNextEvent(display, &ev);
		}
		orientation = quarters(display, root);
	}
	__atomic_store_n(word, 0, __ATOMIC_RELEASE);
	munmap(word, sizeof(*word));
	close(lock);
	XCloseDisplay(display);
	return 0;
}
