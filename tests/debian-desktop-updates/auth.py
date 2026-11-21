"""Use Debian's tty polkit agent and PAM for this disposable GUI process only."""
from contextlib import contextmanager
import os
from pathlib import Path
import pty
import select
import signal
import threading


@contextmanager
def admin_agent():
    matches = []
    for item in Path("/proc").glob("[0-9]*/exe"):
        try:
            if item.readlink() == Path("/usr/bin/gpk-update-viewer"):
                matches.append(int(item.parent.name))
        except (PermissionError, FileNotFoundError):
            pass
    assert len(matches) == 1, matches
    target = matches[0]
    assert Path(f"/proc/{target}").stat().st_uid == os.getuid() == 1000
    ready, notify = os.pipe()
    os.set_inheritable(notify, True)
    pid, tty = pty.fork()
    if pid == 0:
        os.close(ready)
        os.execv("/usr/bin/pkttyagent", ["pkttyagent", "--process", str(target), "--notify-fd", str(notify)])
    os.close(notify)
    done = threading.Event()
    observed = {"prompts": 0, "action": False, "authenticated": False}
    def prompt():
        buffer = b""
        while not done.is_set():
            if not select.select([tty], [], [], .25)[0]:
                continue
            try:
                chunk = os.read(tty, 4096)
            except OSError:
                return
            if not chunk:
                return
            buffer = (buffer + chunk)[-8096:]
            if b"org.freedesktop.packagekit.system-update" in buffer:
                observed["action"] = True
            if b"Choose identity to authenticate as" in buffer and buffer.rstrip().endswith(b":"):
                assert observed["action"]
                os.write(tty, b"1\n")
                buffer = b""
            if b"Password:" in buffer:
                if not observed["action"] or observed["prompts"] != 0:
                    return
                observed["prompts"] += 1
                secret = Path("/run/updater-qa-password").read_bytes().strip()
                os.write(tty, secret + b"\n")
                buffer = b""
            if b"AUTHENTICATION COMPLETE" in buffer:
                observed["authenticated"] = True
    thread = threading.Thread(target=prompt, daemon=True)
    thread.start()
    try:
        assert select.select([ready], [], [], 12)[0] and os.read(ready, 1) == b"", "agent registration"
        if os.waitpid(pid, os.WNOHANG)[0]:
            raise RuntimeError("pkttyagent exited before authorization")
        yield observed
    finally:
        done.set()
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
        thread.join(2)
        os.close(tty)
        os.close(ready)
