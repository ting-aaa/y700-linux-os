/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Included after the V4L2 ABI headers. Only the observed single-plane
 * timestamp-copy, zero-sequence pair qualifies. */
static inline int
iris_vp9_start_buffer (const struct v4l2_buffer *buf,
    const struct v4l2_plane *plane, int confirm_keyframe)
{
  unsigned int flags = buf->flags & ~V4L2_BUF_FLAG_MAPPED;
  unsigned int expected = V4L2_BUF_FLAG_TIMESTAMP_COPY |
      (confirm_keyframe ? V4L2_BUF_FLAG_KEYFRAME : V4L2_BUF_FLAG_ERROR);

  if (flags != expected || buf->type != V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE ||
      buf->sequence != 0 || buf->timestamp.tv_sec != 0 ||
      buf->timestamp.tv_usec != 0 || buf->length != 1 ||
      plane->data_offset != 0 || plane->length == 0)
    return 0;

  return plane->bytesused == (confirm_keyframe ? plane->length : 0);
}
