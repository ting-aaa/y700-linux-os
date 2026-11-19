"""Exercise terminal host states without touching a USB device or issuing a real reset."""

import json
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

MONITOR = Path(__file__).resolve().parents[1] / "scripts/monitor-tablet-trial.py"


@unittest.skipUnless(
    sys.platform == "linux", "the USB trial controller runs in Linux/WSL"
)
class HostMonitorTest(unittest.TestCase):
    def invoke(self, directory, wrapper, *options, **overrides):
        root = Path(directory)
        bridge = root / "simulated-ssh"
        bridge.write_text(wrapper)
        state = {
            "id": "test",
            "notes": "a" * 64,
            "baseline": "b" * 64,
            "exercise": False,
            "start": "initial",
            "boots": [],
            "deadline": time.time() - 10,
        }
        state.update(overrides)
        (root / "state.json").write_text(json.dumps(state))
        return subprocess.run(
            [sys.executable, str(MONITOR), str(bridge), "test", str(root), "a" * 64, *options],
            text=True,
            capture_output=True,
            timeout=8,
            check=False,
        )

    def test_expired_disconnection_stops_without_dispatch(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "unexpected-command"
            wrapper = f'case "$1" in *" status") exit 255;; *) touch "{marker}"; exit 1;; esac\n'
            result = self.invoke(directory, wrapper)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("remote reset was not confirmed", result.stderr)
            self.assertFalse(marker.exists())

    def test_completed_run_can_be_read_again_offline(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "unexpected-probe"
            result = self.invoke(
                directory, f'touch "{marker}"\n', closed=True, result="PASS"
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(marker.exists())

    def test_late_candidate_gets_finish_without_workload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "finish-command"
            wrapper = (
                f'if [[ -f "{marker}" ]]; then echo "other boot unknown hash active inactive 0"; '
                f'elif [[ $1 == *" status" ]]; then echo "test late trial {"a" * 64} active active 0"; '
                f'else echo "$1" > "{marker}"; fi\n'
            )
            result = self.invoke(root, wrapper, "--startup-seconds", "2700", startup_seconds=2700)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(marker.read_text().strip(), "/usr/local/libexec/y700-lab-device finish test late")
            saved = json.loads((root / "state.json").read_text())
            self.assertIn("after the host deadline", saved["abort_reason"])
            self.assertNotIn("checks", saved)

    def test_resuming_does_not_silently_change_discovery_window(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.invoke(directory, "exit 99\n", startup_seconds=2700)
            self.assertIn("startup window differs", result.stderr)

    def test_first_candidate_uses_a_fresh_return_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "finish-command"
            wrapper = (
                f'if [[ -f "{marker}" ]]; then echo "other boot unknown hash active inactive 0"; '
                f'elif [[ $1 == *" status" ]]; then echo "test ready trial {"a" * 64} active active 0"; '
                f'else echo "$1" > "{marker}"; fi\n'
            )
            now = time.time()
            self.invoke(root, wrapper, "--startup-seconds", "2700",
                        startup_seconds=2700, deadline=now + 2000)
            saved = json.loads((root / "state.json").read_text())
            self.assertEqual(saved.get("passed_boot"), "ready")
            self.assertGreaterEqual(saved["deadline"], now + 420)
            self.assertLess(saved["deadline"], now + 430)


if __name__ == "__main__":
    unittest.main()
