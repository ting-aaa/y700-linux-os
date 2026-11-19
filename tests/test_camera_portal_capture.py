"""Regression checks for portal camera sample and routing evidence."""
import json
import os
from pathlib import Path
import runpy
from types import SimpleNamespace
import unittest


witness = runpy.run_path(str(Path(__file__).with_name("camera-portal-capture.py")))
STREAM = "y700.camera.probe.fixture"
ARGS = SimpleNamespace(sensor="hi1339", serial="32", frames=12)
SOURCE = {"id": 31, "type": witness["NODE"], "info": {"props": {
    "media.class": "Video/Source", "media.role": "Camera", "object.serial": 32}}}
STREAM_NODE = {"id": 47, "type": witness["NODE"], "info": {"props": {"node.name": STREAM}}}
SAMPLE = (f"CAMERA_SAMPLE sensor=hi1339 serial=32 format=RGB size=640x480 frames=12 "
          f"bytes=11059200 rejected=0 stream={STREAM} target_node=31")


def link(obj, source):
    return {"id": obj, "type": witness["LINK"], "info": {
        "input-node-id": 47, "output-node-id": source, "state": "active"}}


def removed(obj):
    return {"id": obj, "info": None}


def verify(*batches):
    reader, writer = os.pipe()
    with os.fdopen(reader, "rb") as pipe, os.fdopen(writer, "wb", buffering=0) as publisher:
        graph = witness["GraphMonitor"](pipe)
        for batch in batches:
            publisher.write(json.dumps(batch).encode())
            graph.read()
        return witness["verified_link"](graph.events, STREAM, 31, "32")


class PortalWitnessTests(unittest.TestCase):
    def test_valid_link_and_tombstones_in_one_batch(self):
        self.assertEqual(verify([SOURCE, STREAM_NODE], [link(49, 31), removed(49), removed(47)]),
                         (31, 47, 49))

    def test_transient_conflict_in_final_batch(self):
        with self.assertRaisesRegex(RuntimeError, "unexpected source"):
            verify([SOURCE, STREAM_NODE, link(49, 31)], [link(50, 33), removed(50), removed(47)])

    def test_transient_conflict_before_stream_name_arrives(self):
        with self.assertRaisesRegex(RuntimeError, "unexpected source"):
            verify([SOURCE, link(50, 33), removed(50), STREAM_NODE, link(49, 31), removed(47)])

    def test_prior_incarnation_of_global_id(self):
        self.assertEqual(verify([SOURCE, link(50, 33), removed(50), removed(47)],
                                [STREAM_NODE, link(49, 31), removed(49), removed(47)]), (31, 47, 49))

    def test_source_serial_and_complete_lifetime(self):
        self.assertIsNone(verify([SOURCE, STREAM_NODE, link(49, 31)]))
        changed = {"id": 31, "type": witness["NODE"], "info": {"props": {"object.serial": 35}}}
        with self.assertRaisesRegex(RuntimeError, "unexpected source"):
            verify([SOURCE, STREAM_NODE, link(49, 31), changed, removed(47)])

    def test_sample_fields(self):
        parse = witness["sample_target"]
        self.assertEqual(parse(SAMPLE, ARGS, STREAM), 31)
        for old, new in [("format=RGB", "format=MJPG"), ("640x480", "1280x720"),
                         ("11059200", "11059199"), ("rejected=0", "rejected=-1"),
                         ("frames=12", "frames=11"), ("target_node=31", "target_node=4294967295"),
                         ("serial=32", "serial=32 serial=32")]:
            with self.subTest(new=new), self.assertRaises((ValueError, RuntimeError)):
                parse(SAMPLE.replace(old, new), ARGS, STREAM)


if __name__ == "__main__":
    unittest.main()
