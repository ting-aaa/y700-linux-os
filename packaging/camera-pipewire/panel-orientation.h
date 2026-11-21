/* Shared only by a user's X11 display watcher and camera SPA nodes. */
#pragma once

#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static inline uint64_t y700_monotonic_seconds(void)
{
	struct timespec now;
	return clock_gettime(CLOCK_MONOTONIC, &now) == 0 ? (uint64_t)now.tv_sec : 0;
}

/* Open only a private regular file in the owner's private runtime directory.
 * Readers can precede the graphical session. Only the writer changes the word.
 * Keeping the same inode across logins also handles compositor restarts. */
static inline uint64_t *y700_map_orientation(int writer, int *held_lock)
{
	const char *path = getenv("XDG_RUNTIME_DIR");
	struct stat st;
	if (!path || path[0] != '/')
		return NULL;
	int dir = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
	if (dir < 0)
		return NULL;
	int fd = -1;
	if (fstat(dir, &st) == 0 && st.st_uid == getuid() && !(st.st_mode & 0077))
		fd = openat(dir, "y700-camera-panel.state", O_RDWR | O_CREAT | O_NONBLOCK |
		            O_CLOEXEC | O_NOFOLLOW, 0600);
	close(dir);
	if (fd < 0)
		return NULL;
	uint64_t *word = NULL;
	if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == getuid() &&
	    (st.st_mode & 0777) == 0600 && st.st_nlink == 1 &&
	    (!writer || flock(fd, LOCK_EX | LOCK_NB) == 0) &&
	    (st.st_size == sizeof(*word) || (st.st_size == 0 && ftruncate(fd, sizeof(*word)) == 0))) {
		void *map = mmap(NULL, sizeof(*word), PROT_READ | (writer ? PROT_WRITE : 0),
		                 MAP_SHARED, fd, 0);
		if (map != MAP_FAILED)
			word = (uint64_t *)map;
	}
	if (writer && word)
		*held_lock = fd;
	else
		close(fd);
	return word;
}

static inline unsigned int y700_panel_quarters(const uint64_t *word)
{
	if (!word)
		return 0;
	uint64_t state = __atomic_load_n(word, __ATOMIC_ACQUIRE);
	uint64_t then = state >> 2;
	uint64_t now = y700_monotonic_seconds();
	/* A disconnected or hung X session cannot leave an old rotation active. */
	return then && now >= then && now - then <= 6 ? state & 3U : 0;
}
