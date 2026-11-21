"""Exercise UFS1 framing, durable receipts and reconnects without a tablet."""
import hashlib
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import collect as host


def frame(variant=0, virtual=1, *, error=0, alter=None):
    guard = int(error != 1)
    reads = 0 if error else 2
    rows = [f"UFS1 META {variant} {virtual} {guard} {guard} {reads} {error}".encode(),
            b"UFS1 RANGE 75000000 850000000 75000000 850000000"]
    if not error:
        for index, duration in enumerate((-1, 80, -1, 120)):
            rows.append(f"UFS1 PHASE {index} -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 {duration}".encode())
    if alter is not None:
        alter(rows)
    digest = hashlib.sha256(b"".join(row + b"\n" for row in rows)).hexdigest().encode()
    return [host.BEGIN, *rows, b"UFS1 END " + digest]


def wire(rows):
    return b"".join(row + b"\n" for row in rows)


class CollectorTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.receipt = Path(self.temp.name) / "result.log"

    def test_signed_but_invalid_rows(self):
        cases = [
            lambda r: r.__setitem__(0, b"UFS1 META 1 1 1 1 2 0"),
            lambda r: r.__setitem__(0, b"UFS1 META 0 0 1 1 2 0"),
            lambda r: r.__setitem__(0, b"UFS1 META 0 1 0 0 0 0"),
            lambda r: r.__setitem__(0, b"UFS1 META 0 1 0 0 0 8"),
            lambda r: r.__setitem__(0, b"UFS1 META 0 1 0 0 2 7"),
            lambda r: r.__setitem__(1, b"UFS1 RANGE 850000000 75000000 0 1"),
            lambda r: r.__setitem__(1, b"UFS1 RANGE 75000000 850000000 0 9999999999999999999"),
            lambda r: r.__setitem__(2, r[2].replace(b"PHASE 0 ", b"PHASE 00 ")),
            lambda r: r.__setitem__(2, r[2].replace(b"-1", b"5", 1)),
            lambda r: r.__setitem__(2, r[2] + b" PRIVATE"),
            lambda r: r.__setitem__(3, r[3][:-2] + b"-1"),
            lambda r: r.__delitem__(3),
            lambda r: r.__setitem__(3, r[4]),
            lambda r: r.__setitem__(5, r[5].replace(b"-1 120", b"3 120")),
        ]
        for case in cases:
            with self.subTest(case=case), self.assertRaises(host.InvalidReceipt):
                host.validate(frame(alter=case), 0, 1)

    def run_peer(self, scripts, *, resume=False):
        """Each script is a separate connection and checks exact host requests."""
        scripts = iter(scripts)
        threads, failures = [], []

        def opener():
            script = next(scripts)
            a, b = socket.socketpair()
            a.settimeout(.1)
            b.settimeout(4)

            def serve():
                try:
                    with b, b.makefile("rb") as f:
                        script(f, b)
                except Exception as exc:
                    failures.append(exc)
            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            threads.append(thread)
            return host.Channel(a, True)

        try:
            return host.collect(opener, 0, 1, self.receipt, resume=resume,
                                deadline=time.monotonic() + 6)
        finally:
            for thread in threads:
                thread.join(4)
                self.assertFalse(thread.is_alive())
            self.assertIsNone(next(scripts, None), "Expected reconnect did not happen")
            if failures:
                raise failures[0]

    def start(self, f, sock, operation=b"READ"):
        self.assertEqual(f.readline(), b"UFS1 STATUS\n")
        sock.sendall(b"UFS1 READY 0 1\r\n")
        self.assertEqual(f.readline(), b"UFS1 " + operation + b" 0\n")

    def respond(self, f, sock, rows, operation=b"READ", confirm=True):
        self.start(f, sock, operation)
        # Split a row across packets and mix CRLF/LF. The sealed file uses LF.
        payload = wire(rows).replace(b"\n", b"\r\n", 1)
        sock.sendall(payload[:4])
        sock.sendall(payload[4:])
        if confirm:
            ack = f.readline()
            self.assertEqual(ack, b"UFS1 ACK " + rows[-1].split()[-1] + b"\n")
            self.assertEqual(self.receipt.read_bytes(), wire(rows))
            sock.sendall(b"UFS1 RETURN\n")
        else:
            self.assertEqual(f.readline(), b"", "Invalid data was acknowledged")

    def test_acked_success_and_existing_result_only(self):
        rows = frame()
        self.assertEqual(self.run_peer([lambda f, s: self.respond(f, s, rows)]), 0)
        self.assertEqual(self.run_peer([lambda f, s: self.respond(f, s, rows, b"RESULT")]), 0)
        self.assertEqual(list(self.receipt.parent.iterdir()), [self.receipt])

    def test_ack_negative_identity(self):
        rows = frame(error=3, alter=lambda r: r.__setitem__(0, b"UFS1 META 0 1 1 0 0 3"))
        self.assertEqual(self.run_peer([lambda f, s: self.respond(f, s, rows)]), 3)

    def test_reconnect_never_reissues_read(self):
        rows = frame()

        def partial(f, sock):
            self.start(f, sock)
            sock.sendall(wire(rows[:3]) + b"UFS1 PHA")

        self.assertEqual(self.run_peer([partial, lambda f, s: self.respond(f, s, rows, b"RESULT")]), 0)

    def test_missing_ack_replays_durable_file(self):
        rows = frame()

        def disconnect_at_ack(f, sock):
            self.start(f, sock)
            sock.sendall(wire(rows))
            self.assertTrue(f.readline().startswith(b"UFS1 ACK "))
            self.assertEqual(self.receipt.read_bytes(), wire(rows))

        self.assertEqual(self.run_peer([disconnect_at_ack, lambda f, s: self.respond(f, s, rows, b"RESULT")]), 0)

    def test_resume_without_prior_file(self):
        rows = frame()
        self.assertEqual(self.run_peer([lambda f, s: self.respond(f, s, rows, b"RESULT")], resume=True), 0)

    def test_bad_digest_no_ack(self):
        rows = frame()
        rows[-1] = b"UFS1 END " + b"0" * 64
        with self.assertRaisesRegex(host.InvalidReceipt, "digest"):
            self.run_peer([lambda f, s: self.respond(f, s, rows, confirm=False)])
        self.assertFalse(self.receipt.exists())

    def test_existing_different_receipt_no_overwrite(self):
        prior = wire(frame(error=1))
        self.receipt.write_bytes(prior)
        with self.assertRaisesRegex(host.InvalidReceipt, "differs"):
            self.run_peer([lambda f, s: self.respond(f, s, frame(), b"RESULT", confirm=False)])
        self.assertEqual(self.receipt.read_bytes(), prior)

    def test_publish_failure_prevents_ack(self):
        with patch.object(host.os, "link", side_effect=OSError("disk error")):
            with self.assertRaisesRegex(host.InvalidReceipt, "persist"):
                self.run_peer([lambda f, s: self.respond(f, s, frame(), confirm=False)])
        self.assertEqual(list(self.receipt.parent.iterdir()), [])

    def test_identity_before_read(self):
        def other(f, sock):
            self.assertEqual(f.readline(), b"UFS1 STATUS\n")
            sock.sendall(b"UFS1 READY 1 1\n")
            self.assertEqual(f.readline(), b"")
        with self.assertRaisesRegex(host.InvalidReceipt, "mismatch"):
            self.run_peer([other])

    def test_bounded_line(self):
        def bad(f, sock):
            self.start(f, sock)
            sock.sendall(b"A" * (host.MAX_LINE + 1))
            self.assertEqual(f.readline(), b"")
        with self.assertRaisesRegex(host.InvalidReceipt, "Unterminated"):
            self.run_peer([bad])

    @unittest.skipUnless(os.name == "posix", "QEMU host uses a Unix-domain virtserial socket")
    def test_cli_over_qemu_transport(self):
        path = str(Path(self.temp.name) / "serial.sock")
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(path)
            listener.listen()
            listener.settimeout(4)
            for error in (0, 1):
                runner = [os.environ.get("UV", "uv"), "run", "--offline", "--no-project",
                          "--python", sys.executable, "python", "-B", host.__file__]
                with subprocess.Popen([*runner, "--vm-socket", path, "--variant", "0", "--output", str(self.receipt)],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
                    try:
                        client, _ = listener.accept()
                        with client, client.makefile("rb") as stream:
                            client.settimeout(4)
                            self.respond(stream, client, frame(error=error))
                        output, errors = process.communicate(timeout=4)
                        self.assertEqual(process.returncode, error)
                        self.assertIn(b"return_acknowledged=1", output)
                        self.assertEqual(errors, b"")
                    finally:
                        if process.poll() is None:
                            process.kill()
                self.receipt.unlink()


if __name__ == "__main__":
    unittest.main()
