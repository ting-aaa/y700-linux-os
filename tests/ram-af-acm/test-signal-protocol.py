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
bracket = os.environ["AF_QA_SIGNAL"] == "bracket"
command = "BRACKET" if bracket else "SIGNAL"
with contextlib.closing(Channel(None, socket_path)) as channel:
    state, token = status(channel, True)
    assert state == "READY"
    if os.environ["AF_QA_SIGNAL"] == "deadline":
        print("SIGNAL_QA idle=1 no_capture=1")
        sys.exit(0)
    channel.send(command + " incorrect")
    expect(channel, "AF1 REFUSED command")
    channel.send(f"{command} {token}")
    expect(channel, "AF1 REFUSED config_required")
    assert check_config(channel, token, virtual=True) == 0
    channel.send(f"{command} {token}")
    expect(channel, f"AF1 RUNNING {token} virtual=1")
time.sleep(3)
with contextlib.closing(Channel(None, socket_path)) as channel:
    assert status(channel, True) == ("DONE", token)
    for action in (["START", "SIGNAL", "BRACKET"] if bracket else ["START", "SIGNAL"]):
        channel.send(f"{action} {token}")
        expect(channel, "AF1 REFUSED consumed")
    channel.send(f"ACK {token} " + "0" * 64)
    expect(channel, "AF1 REFUSED acknowledgement")
    assert result(channel, token, virtual=True, start=False, acknowledge=True, signal=not bracket, bracket=bracket) == 0
    print(f"SIGNAL_QA replay=1 single_execution=1 config=1 numeric_receipt=1 acknowledged=1 bracket={int(bracket)}")
