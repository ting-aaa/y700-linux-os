"""Monitor one armed trial using an existing host-key-pinned SSH wrapper."""

import argparse
import fcntl
import hashlib
import json
import re
import shlex
import subprocess
import time
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("ssh", type=Path, help="existing executable SSH wrapper (Bash)")
p.add_argument("run_id")
p.add_argument("state", type=Path, help="private persistent PC run directory")
p.add_argument("candidate_notes", help="SHA-256 of the candidate kernel's ELF notes")
p.add_argument(
    "--exercise-timeout",
    action="store_true",
    help="withhold first boot acknowledgement",
)
p.add_argument(
    "--check",
    type=Path,
    help="trusted, repeatable shell check to execute over SSH on a candidate boot",
)
p.add_argument("--check-seconds", type=int, default=25, help="bounded device workload time")
p.add_argument("--startup-seconds", type=int, default=420,
               help="host discovery window from arming to first candidate boot")
args = p.parse_args()
if not 60 <= args.startup_seconds <= 3600:
    p.error("startup time must be between 60 and 3600 seconds")
if not 25 <= args.check_seconds <= 3600:
    p.error("check time must be between 25 and 3600 seconds")
payload = args.check.read_bytes() if args.check else b""
payload_hash = hashlib.sha256(payload).hexdigest()
if not re.fullmatch("[a-z0-9][a-z0-9-]{0,39}", args.run_id) or not re.fullmatch(
    "[a-f0-9]{64}", args.candidate_notes
):
    p.error("invalid run ID or candidate hash")
args.state.mkdir(mode=0o700, parents=True, exist_ok=True)
lock = (args.state / "lock").open("a")
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
statefile = args.state / "state.json"
device = "/usr/local/libexec/y700-lab-device"
last_status_error = None


def remote(*words):
    global last_status_error
    try:
        proc = subprocess.run(
            ["bash", str(args.ssh), shlex.join(words)],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=12,
            check=False,
        )
    except subprocess.TimeoutExpired:
        proc = None
    if words == (device, "status"):
        if proc is None:
            error = "SSH status command timed out"
        elif proc.returncode:
            error = (proc.stderr.strip().splitlines() or [f"SSH exited {proc.returncode}"])[-1]
        else:
            error = None
        if error and error != last_status_error:
            event(error)
        last_status_error = error
    if proc is None:
        return None
    return proc.stdout.strip() if proc.returncode == 0 else None


def save():
    tmp = statefile.with_suffix(".new")
    tmp.write_text(json.dumps(state, indent=2) + "\n")
    tmp.replace(statefile)


def event(message):
    line = time.strftime("%FT%TZ", time.gmtime()) + " " + message
    print(line, flush=True)
    with (args.state / "events.log").open("a") as stream:
        print(line, file=stream)


def check_boot(boot, attempt):
    """Record the dispatch before sending. Never re-run an ambiguous command on the same boot."""
    checks = state.setdefault("checks", {})
    if boot not in checks:
        checks[boot] = "interrupted"
        state["deadline"] += args.check_seconds - 25
        save()
        command = f'set -e; test "$(cat /proc/sys/kernel/random/boot_id)" = {shlex.quote(boot)}; '
        if args.check_seconds > 25:
            # A runtime-only drop-in disappears on reboot. If the PC disappears,
            # PID 1 still has an independent, finite deadline on this boot.
            unit = "y700-lab-deadline.timer"
            directory = f"/run/systemd/system/{unit}.d"
            command += (
                f"mkdir -p {directory}; "
                f"printf '[Timer]\\nOnBootSec=\\nOnActiveSec={args.check_seconds + 45}s\\n' "
                f"> {directory}/check-window.conf; systemctl daemon-reload; systemctl restart {unit}; "
                f"systemctl is-active --quiet {unit}; "
            )
        command += f"Y700_TEST_ATTEMPT={attempt} Y700_CHECK_SECONDS={args.check_seconds} timeout -k 5 {args.check_seconds} bash -se"
        with (args.state / ("check-" + boot + ".log")).open("xb") as log:
            try:
                proc = subprocess.run(
                    ["bash", str(args.ssh), command],
                    input=payload,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    timeout=args.check_seconds + 15,
                    check=False,
                )
                checks[boot] = str(proc.returncode)
            except subprocess.TimeoutExpired:
                checks[boot] = "transport-timeout"
        save()
        event(f"check attempt {attempt}: {checks[boot]}")
    return checks[boot] == "0"


if statefile.exists():
    state = json.loads(statefile.read_text())
    if (state["id"], state["notes"], state["exercise"]) != (
        args.run_id,
        args.candidate_notes,
        args.exercise_timeout,
    ):
        p.error("state belongs to another test")
    if state.get("check_seconds",25) != args.check_seconds or state.get("payload", hashlib.sha256(b"").hexdigest()) != payload_hash:
        p.error("check content differs from the saved run")
    if state.get("startup_seconds", 420) != args.startup_seconds:
        p.error("startup window differs from the saved run")
    if state.get("closed"):
        print(state["result"])
        raise SystemExit(0 if state["result"] == "PASS" else 1)
else:
    initial = (remote(device, "status") or "").split()
    if (
        len(initial) != 7
        or initial[0] != args.run_id
        or initial[2] != "baseline"
        or initial[4] != "active"
    ):
        raise SystemExit("expected an armed and healthy baseline")
    state = {
        "id": args.run_id,
        "notes": args.candidate_notes,
        "exercise": args.exercise_timeout,
        "start": initial[1],
        "baseline": initial[3],
        "boots": [],
        "payload": payload_hash,
        "check_seconds": args.check_seconds,
        "startup_seconds": args.startup_seconds,
        "deadline": time.time() + args.startup_seconds,
    }
    save()
    event("armed baseline " + initial[1])
last = None
while True:
    fields = (remote(device, "status") or "").split()
    status = fields if len(fields) == 7 else None
    key = tuple(status) if status else ("unreachable",)
    if key != last:
        event(" ".join(key))
        last = key
    if time.time() > state["deadline"]:
        if (status and status[0] == args.run_id and status[2] == "trial"
                and not state.get("abort_reason")):
            state["abort_reason"] = "candidate discovered after the host deadline"
            state["deadline"] = time.time() + 420
            save()
            event(state["abort_reason"])
            remote(device, "finish", args.run_id, status[1])
            continue
        can_close = (
            status and status[3] == state["baseline"] and status[1] != state["start"]
        )
        if not can_close:
            raise SystemExit(
                "deadline exceeded; remote reset was not confirmed; inspect saved state"
            )
        if "close_limit" not in state:
            state["close_limit"] = time.time() + 20
            save()
        elif time.time() > state["close_limit"]:
            raise SystemExit("could not confirm cleanup")
    if status:
        active, boot, role, notes, desktop, timer, fault = status
        if (
            active == "none"
            and state.get("closing")
            and boot == state["closing"]
            and notes == state["baseline"]
        ):
            state["closed"] = True
            save()
            event(state["result"] + "; baseline confirmed and temporary policy removed")
            break
        if active != args.run_id:
            raise SystemExit("active run changed; monitor stopped")
        if role == "baseline" and boot == state["start"] and not state.get("abort_reason"):
            if (
                state.get("start_calls", 0) < 2
                and time.time() - state.get("last_start", 0) > 20
            ):
                state["start_calls"] = state.get("start_calls", 0) + 1
                state["last_start"] = time.time()
                save()
                remote(device, "start", active, boot)
        elif role == "baseline" and notes == state["baseline"] and desktop == "active":
            history = remote("cat", "/var/lib/y700-lab/runs/" + active + "/events")
            if history is not None:
                (args.state / "device-events.log").write_text(history + "\n")
                expected_retry = not state["exercise"] or (
                    len(state["boots"]) == 2
                    and state["boots"][0] + " deadline" in history
                )
                good = state.get("passed_boot", "")
                state["result"] = (
                    "PASS"
                    if good and good + " finish" in history and expected_retry and not state.get("abort_reason")
                    else "FAIL"
                )
                state["closing"] = boot
                save()
                remote(device, "close", active, boot)
        elif role == "trial":
            if boot not in state["boots"]:
                if not state["boots"]:
                    state["deadline"] = time.time() + 420
                state["boots"].append(boot)
                save()
            if state.get("abort_reason") or notes != args.candidate_notes or fault != "0" or len(state["boots"]) > 2:
                state.pop("passed_boot", None)
                save()
                event(
                    "unexpected kernel, GPU fault or excess boot; returning to baseline"
                )
                remote(device, "finish", active, boot)
            elif (
                desktop == "active"
                and timer == "active"
                and (not args.exercise_timeout or len(state["boots"]) == 2)
            ):
                if payload:
                    attempt = len(state["boots"])
                    passed = check_boot(boot, attempt)
                    if not passed:
                        # A hardware stop from the check is terminal, even if
                        # a separate status query does not see the same event.
                        if state["checks"][boot] == "76":
                            state["abort_reason"] = "workload observed a hardware fault"
                            state.pop("passed_boot", None)
                            save()
                        current = (remote(device, "status") or "").split()
                        if len(current) != 7 or current[:2] != [active, boot]:
                            time.sleep(3)
                            continue
                        remote(
                            device,
                            "retry" if attempt == 1 and current[-1] == "0" and not state.get("abort_reason") else "finish",
                            active,
                            boot,
                        )
                        time.sleep(3)
                        continue
                    # The workload may have reset the GPU or lost the target.
                    after = (remote(device, "status") or "").split()
                    if after != status:
                        time.sleep(3)
                        continue
                state["passed_boot"] = boot
                save()
                remote(device, "finish", active, boot)
        elif role == "unknown":
            raise SystemExit("unrecognized running kernel; monitor stopped")
    time.sleep(3)
raise SystemExit(0 if state["result"] == "PASS" else 1)
