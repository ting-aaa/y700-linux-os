"""Exercise the initrd transfer protocol over a Linux PTY with a small fixture."""
import hashlib
import os
import pty
import signal
import shutil
import subprocess
import tempfile
import tty
from pathlib import Path

TRANSFER = Path(__file__).resolve().parents[2] / "src/boot/ram-receive-transfer"
PAYLOAD = bytes(range(256)) * 16
DIGEST = hashlib.sha256(PAYLOAD).hexdigest()


def run_case(mode):
    with tempfile.TemporaryDirectory() as tmp:
        target = Path(tmp) / "carrier"
        master, slave = pty.openpty()
        try:
            tty.setraw(slave)
            busybox = shutil.which("busybox")
            shell = [busybox, "sh"] if busybox else ["/bin/sh"]
            with subprocess.Popen([*shell, str(TRANSFER), os.ttyname(slave),
                                   str(len(PAYLOAD)), DIGEST, str(target)],
                                  stderr=subprocess.PIPE) as process:
                try:
                    with os.fdopen(os.dup(master), "r+b", buffering=0) as peer:
                        peer.write(b"INFO\n")
                        assert peer.readline() == f"Y700_RAM_INFO {len(PAYLOAD)} {DIGEST}\n".encode()
                        if mode == "wrong-begin":
                            peer.write(b"BEGIN incorrect\n")
                        else:
                            peer.write(f"BEGIN {DIGEST}\n".encode())
                            assert peer.readline() == b"Y700_RAM_SEND\n"
                            peer.write(bytes(len(PAYLOAD)) if mode == "corrupt" else PAYLOAD)
                            if mode != "corrupt":
                                assert peer.readline() == b"Y700_RAM_VERIFIED\n"
                                peer.write(b"CONTINUE\n" if mode == "valid" else b"wrong\n")
                    assert (process.wait(timeout=5) == 0) == (mode == "valid")
                    assert target.exists() == (mode != "wrong-begin")
                    if mode == "valid":
                        assert target.read_bytes() == PAYLOAD
                finally:
                    if process.poll() is None:
                        process.kill()
        finally:
            os.close(slave)
            os.close(master)


if __name__ == "__main__":
    def timed_out(_signum, _frame):
        raise TimeoutError("RAM transfer fixture stalled")

    signal.signal(signal.SIGALRM, timed_out)
    for case in ("wrong-begin", "corrupt", "wrong-continuation", "valid"):
        signal.alarm(10)
        run_case(case)
        signal.alarm(0)
        print(f"RAM_TRANSFER_CASE {case} passed", flush=True)
