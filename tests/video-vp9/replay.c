/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Compiled alongside the real plugin sources by replay.py. */
static GstV4l2MemoryGroup groups[2];
static guint reads, releases, errors;
static guint first_bytes;
static GstFlowReturn second_poll;

static GstFlowReturn
fixture_poll (GstV4l2BufferPool *pool, gboolean wait)
{
  return reads ? second_poll : GST_FLOW_OK;
}

static GstFlowReturn
fixture_dqbuf (GstV4l2Allocator *allocator, GstV4l2MemoryGroup **group)
{
  g_assert_cmpuint (reads, <, G_N_ELEMENTS (groups));
  *group = &groups[reads++];
  return GST_FLOW_OK;
}

static void
fixture_requeue (GstBufferPool *pool, GstBuffer *buf, gboolean queued)
{
  releases++;
  gst_buffer_unref (buf);
}

static void
capture_error (GstV4l2BufferPool *pool, guint frame, gpointer unused)
{
  g_assert_cmpuint (frame, ==, 0);
  errors++;
}

static void
replay (const char *name, gboolean eligible, GstFlowReturn next_poll,
    guint next_flags, guint next_bytes, guint next_sequence, guint next_time,
    guint expected_errors, guint expected_reads)
{
  GstV4l2Object obj = { 0 };
  GstV4l2BufferPool *pool = g_object_new (GST_TYPE_V4L2_BUFFER_POOL, NULL);
  GstBuffer *out = NULL, *original[2];
  GstFlowReturn expected = next_poll;
  guint expected_requeues = eligible && !first_bytes;
  guint i;

  reads = releases = errors = 0;
  second_poll = next_poll;
  obj.element = gst_pipeline_new (NULL);
  obj.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
  gst_video_info_set_format (&obj.info.vinfo, GST_VIDEO_FORMAT_NV12, 384, 256);
  pool->caps_info.vinfo = obj.info.vinfo;
  pool->obj = &obj;
  pool->video_fd = -1;
  pool->check_iris_vp9_start = eligible;
  pool->num_queued = 2;
  memset (groups, 0, sizeof groups);
  for (i = 0; i < 2; i++) {
    GstV4l2MemoryGroup *g = &groups[i];

    g->buffer.type = obj.type;
    g->buffer.index = i;
    g->buffer.flags = V4L2_BUF_FLAG_MAPPED | V4L2_BUF_FLAG_TIMESTAMP_COPY |
        (i ? next_flags : V4L2_BUF_FLAG_ERROR);
    g->buffer.sequence = i ? next_sequence : 0;
    g->buffer.timestamp.tv_sec = i ? next_time : 0;
    g->buffer.field = V4L2_FIELD_NONE;
    g->buffer.length = g->n_mem = 1;
    g->planes[0].bytesused = i ? next_bytes : first_bytes;
    g->planes[0].length = obj.info.vinfo.size;
    original[i] = pool->buffers[i] = gst_buffer_new_allocate (NULL, obj.info.vinfo.size, NULL);
    g->mem[0] = gst_buffer_peek_memory (original[i], 0);
    pool->buffer_state[i] = BUFFER_STATE_QUEUED;
  }
  g_signal_connect (pool, "capture-error-dequeued", G_CALLBACK (capture_error), NULL);
  GstFlowReturn ret = gst_v4l2_buffer_pool_dqbuf (pool, &out, NULL, TRUE);
  if (next_flags & V4L2_BUF_FLAG_LAST && !next_bytes && expected_reads == 2) {
    expected = GST_V4L2_FLOW_LAST_BUFFER;
    expected_requeues++;
  }
  g_assert_cmpint (ret, ==, expected);
  g_assert_cmpuint (reads, ==, expected_reads);
  g_assert_cmpuint (errors, ==, expected_errors);
  g_assert_cmpuint (releases, ==, expected_requeues);
  if (ret == GST_FLOW_OK) {
    g_assert_true (out == original[expected_reads - 1]);
    g_assert_cmpint (GST_BUFFER_FLAG_IS_SET (out, GST_BUFFER_FLAG_CORRUPTED),
        ==, expected_reads == 1 || !!(next_flags & V4L2_BUF_FLAG_ERROR));
  }
  gst_clear_buffer (&out);
  for (i = 0; i < 2; i++)
    gst_clear_buffer (&pool->buffers[i]);
  gst_object_unref (pool);
  g_print ("PASS %s reads=%u requeued=%u error_signals=%u\n", name, reads, releases, errors);
}

int
main (int argc, char **argv)
{
  const guint key = V4L2_BUF_FLAG_KEYFRAME, full = 147456;

  gst_init (&argc, &argv);
  replay ("duplicate first keyframe", TRUE, GST_FLOW_OK, key, full, 0, 0, 0, 2);
  replay ("different sequence", TRUE, GST_FLOW_OK, key, full, 1, 0, 1, 2);
  replay ("different timestamp", TRUE, GST_FLOW_OK, key, full, 0, 1, 1, 2);
  replay ("short keyframe", TRUE, GST_FLOW_OK, key, full - 1, 0, 0, 1, 2);
  replay ("delta frame", TRUE, GST_FLOW_OK, V4L2_BUF_FLAG_PFRAME, full, 0, 0, 1, 2);
  replay ("second CAPTURE error", TRUE, GST_FLOW_OK, V4L2_BUF_FLAG_ERROR, 0, 0, 0, 2, 2);
  replay ("end of stream", TRUE, GST_V4L2_FLOW_LAST_BUFFER, 0, 0, 0, 0, 1, 1);
  replay ("dequeued LAST buffer", TRUE, GST_FLOW_OK, V4L2_BUF_FLAG_LAST, 0, 0, 0, 1, 2);
  replay ("flush", TRUE, GST_FLOW_FLUSHING, 0, 0, 0, 0, 1, 1);
  replay ("device failure", TRUE, GST_FLOW_ERROR, 0, 0, 0, 0, 1, 1);
  replay ("source change", TRUE, GST_V4L2_FLOW_RESOLUTION_CHANGE, 0, 0, 0, 0, 1, 1);
  replay ("other stream", FALSE, GST_FLOW_OK, key, full, 0, 0, 1, 1);
  first_bytes = 1024;
  replay ("corrupt picture with payload", TRUE, GST_FLOW_OK, key, full, 0, 0, 1, 1);
  return 0;
}
