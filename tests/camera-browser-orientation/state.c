/* Exercise the session lease and safe fallback independently of cameras or X11. */
#include <assert.h>
#include <stdio.h>
#include "panel-orientation.h"

int main(void)
{
	int lock = -1;
	const uint64_t *reader = y700_map_orientation(0, NULL);
	assert(reader && y700_panel_quarters(reader) == 0);
	uint64_t *writer = y700_map_orientation(1, &lock);
	assert(writer && lock >= 0);
	int other = -1;
	assert(!y700_map_orientation(1, &other));
	uint64_t now = y700_monotonic_seconds();
	for (unsigned q = 0; q < 4; q++) {
		__atomic_store_n(writer, (now << 2) | q, __ATOMIC_RELEASE);
		assert(y700_panel_quarters(reader) == q);
	}
	__atomic_store_n(writer, ((now + 60) << 2) | 1, __ATOMIC_RELEASE);
	assert(y700_panel_quarters(reader) == 0);
	if (now > 8) {
		__atomic_store_n(writer, ((now - 8) << 2) | 1, __ATOMIC_RELEASE);
		assert(y700_panel_quarters(reader) == 0);
	}
	munmap(writer, sizeof(*writer));
	munmap((void *)reader, sizeof(*reader));
	close(lock);

	assert(chdir(getenv("XDG_RUNTIME_DIR")) == 0);
	const char *file = "y700-camera-panel.state";
	assert(chmod(file, 0644) == 0 && !y700_map_orientation(0, NULL));
	assert(unlink(file) == 0 && symlink("/dev/null", file) == 0);
	assert(!y700_map_orientation(0, NULL));
	assert(unlink(file) == 0 && mkfifo(file, 0600) == 0);
	assert(!y700_map_orientation(0, NULL));
	assert(unlink(file) == 0);
	assert(chmod(".", 0755) == 0 && !y700_map_orientation(0, NULL));
	puts("PANEL_STATE_PASS rotations=4 expired=1 future=1 duplicate_watcher=1 unsafe_files=3 unsafe_directory=1");
	return 0;
}
