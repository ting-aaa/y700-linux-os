/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include <gst/gst.h>
#include <gst/video/video.h>
#include <linux/videodev2.h>
#include <string.h>
#include "iris-input-color.h"

static const struct v4l2_capability iris = {
  .driver = "iris_driver", .card = "Iris Decoder",
  .bus_info = "platform:aa00000.video-codec:de"
};

static void
check (const char *name, const char *offered, const char *stream,
    const struct v4l2_capability *device, enum v4l2_buf_type queue,
    gboolean stock_match, gboolean trial_match)
{
  GstCaps *original = gst_caps_from_string (offered);
  GstCaps *input = gst_caps_from_string (stream);
  GstCaps *untouched = gst_caps_copy (input);
  GstCaps *trial = iris_partial_input_color (gst_caps_ref (original), device, queue);

  g_assert_nonnull (original);
  g_assert_nonnull (input);
  g_assert_cmpint (gst_caps_can_intersect (original, input), ==, stock_match);
  g_assert_cmpint (gst_caps_can_intersect (trial, input), ==, trial_match);
  g_assert_true (gst_caps_is_equal (input, untouched));
  g_assert_true (gst_caps_is_subset (original, trial));
  g_print ("PASS %s stock=%d private=%d input_metadata_unchanged=1\n",
      name, stock_match, trial_match);
  gst_caps_unref (trial);
  gst_caps_unref (original);
  gst_caps_unref (input);
  gst_caps_unref (untouched);
}

int
main (int argc, char **argv)
{
  const enum v4l2_buf_type queue = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
  const char *offers = "video/x-h264,stream-format=byte-stream,colorimetry=(string){ bt601, bt709 }";
  const char *partial = "video/x-h264,stream-format=byte-stream,colorimetry=(string)2:4:0:0";
  struct v4l2_capability other = iris;
  GstVideoColorimetry basis;

  gst_init (&argc, &argv);
  g_assert_true (gst_video_colorimetry_from_string (&basis, "bt601"));
  g_assert_cmpint (basis.range, ==, GST_VIDEO_COLOR_RANGE_16_235);
  g_assert_cmpint (basis.matrix, ==, GST_VIDEO_COLOR_MATRIX_BT601);
  if (argc == 4) {
    GstCaps *presented = gst_caps_from_string (argv[3]);
    GstCaps *probed = gst_caps_from_string (argv[2]);
    const GstStructure *fields = gst_caps_get_structure (presented, 0);
    int i;
    for (i = 0; i < gst_structure_n_fields (fields); i++) {
      const gchar *key = gst_structure_nth_field_name (fields, i);
      GstCaps *one_removed = gst_caps_copy (presented);
      gst_structure_remove_field (gst_caps_get_structure (one_removed, 0), key);
      g_assert_cmpint (gst_caps_can_intersect (one_removed, probed), ==,
          !strcmp (key, "colorimetry"));
      gst_caps_unref (one_removed);
    }
    gst_caps_unref (presented);
    gst_caps_unref (probed);
    check (argv[1], argv[2], argv[3], &iris, queue, FALSE, TRUE);
    return 0;
  }
  g_assert_cmpint (argc, ==, 1);
  check ("unknown range", offers, "video/x-h264,colorimetry=(string)0:4:0:0", &iris, queue, FALSE, TRUE);
  check ("limited range", offers, partial, &iris, queue, FALSE, TRUE);
  check ("full range", offers, "video/x-h264,colorimetry=(string)1:4:0:0", &iris, queue, FALSE, FALSE);
  check ("different matrix", offers, "video/x-h264,colorimetry=(string)2:3:0:0", &iris, queue, FALSE, FALSE);
  check ("PQ", offers, "video/x-h264,colorimetry=bt2100-pq", &iris, queue, FALSE, FALSE);
  check ("HLG", offers, "video/x-h264,colorimetry=bt2100-hlg", &iris, queue, FALSE, FALSE);
  check ("original full match", offers, "video/x-h264,colorimetry=bt709", &iris, queue, TRUE, TRUE);
  check ("no BT601 measured", "video/x-h264,colorimetry=bt709", partial, &iris, queue, FALSE, FALSE);
  check ("partial is not AVC conversion", offers, "video/x-h264,stream-format=avc,colorimetry=(string)2:4:0:0",
      &iris, queue, FALSE, FALSE);
  check ("unrelated codec", "video/x-av1,colorimetry=bt601",
      "video/x-av1,colorimetry=(string)2:4:0:0", &iris, queue, FALSE, FALSE);
  check ("raw output", "video/x-raw,format=NV12,colorimetry=bt601",
      "video/x-raw,format=NV12,colorimetry=(string)2:4:0:0", &iris,
      V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, FALSE, FALSE);
  check ("other queue", offers, partial, &iris, V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, FALSE, FALSE);
  strcpy ((char *) other.driver, "other");
  check ("other driver", offers, partial, &other, queue, FALSE, FALSE);
  other = iris;
  strcpy ((char *) other.card, "Iris Encoder");
  check ("encoder", offers, partial, &other, queue, FALSE, FALSE);
  other = iris;
  strcpy ((char *) other.bus_info, "platform:other-codec:dec");
  check ("other platform address", offers, partial, &other, queue, FALSE, FALSE);
  return 0;
}
