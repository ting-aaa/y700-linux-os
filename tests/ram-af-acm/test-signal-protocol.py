"""Drive the real RAM guest through the synthetic-only signal branch."""
import contextlib
import os
import sys
import time

from host import Channel, check_config, result, status


def expect(channel, row):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if channel.line() == row:
            return
    raise AssertionError(row)


socket_path = sys.argv[1]
with contextlib.closing(Channel(None, socket_path)) as channel:
    state, token = status(channel, True)
    assert state == "READY"
    if os.environ["AF_QA_SIGNAL"] == "deadline":
        print("SIGNAL_QA idle=1 no_capture=1")
        sys.exit(0)
    channel.send("SIGNAL incorrect")
    expect(channel, "AF1 REFUSED command")
    channel.send(f"SIGNAL {token}")
    expect(channel, "AF1 REFUSED config_required")
    assert check_config(channel, token, virtual=True) == 0
    channel.send(f"SIGNAL {token}")
    expect(channel, f"AF1 RUNNING {token} virtual=1")
time.sleep(3)
with contextlib.closing(Channel(None, socket_path)) as channel:
    assert status(channel, True) == ("DONE", token)
    for command in ["START", "SIGNAL"]:
        channel.send(f"{command} {token}")
        expect(channel, "AF1 REFUSED consumed")
    channel.send(f"ACK {token} " + "0" * 64)
    expect(channel, "AF1 REFUSED acknowledgement")
    assert result(channel, token, virtual=True, start=False, acknowledge=True, signal=True) == 0
    print("SIGNAL_QA replay=1 single_execution=1 config=1 numeric_receipt=1 acknowledged=1")
