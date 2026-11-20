/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Consume probed decoder input caps. A partially described BT.601 stream can
 * match the known components of the board's advertised "bt601" mode. Keep the
 * full alternatives first and leave the actual stream and raw output alone. */
static GstCaps *
iris_partial_input_color (GstCaps *caps, const struct v4l2_capability *device,
    enum v4l2_buf_type queue)
{
  const gchar *partial[] = { "0:4:0:0", "2:4:0:0" };
  guint count, i, j;
  GValue bt601 = G_VALUE_INIT;

  if (queue != V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE ||
      strcmp ((const gchar *) device->driver, "iris_driver") ||
      strcmp ((const gchar *) device->card, "Iris Decoder") ||
      !g_str_has_prefix ((const gchar *) device->bus_info,
          "platform:aa00000.video-codec:"))
    return caps;

  g_value_init (&bt601, G_TYPE_STRING);
  g_value_set_static_string (&bt601, "bt601");
  count = gst_caps_get_size (caps);
  caps = gst_caps_make_writable (caps);
  for (i = 0; i < count; i++) {
    const GstStructure *s = gst_caps_get_structure (caps, i);
    const GValue *colors = gst_structure_get_value (s, "colorimetry");

    if (!(gst_structure_has_name (s, "video/x-h264") ||
            gst_structure_has_name (s, "video/x-h265") ||
            gst_structure_has_name (s, "video/x-vp9")) ||
        !colors || !gst_value_intersect (NULL, colors, &bt601))
      continue;

    for (j = 0; j < G_N_ELEMENTS (partial); j++) {
      GstCaps *alternative = gst_caps_copy_nth (caps, i);
      gst_structure_set (gst_caps_get_structure (alternative, 0),
          "colorimetry", G_TYPE_STRING, partial[j], NULL);
      gst_caps_append (caps, alternative);
    }
  }
  g_value_unset (&bt601);
  return caps;
}
