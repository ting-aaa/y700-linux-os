import os
import sys
import time

from host import Channel, result, status


def expect(channel, wanted):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        line = channel.line()
        if line == wanted:
            return
    raise AssertionError(wanted)


link = Channel(None, sys.argv[1])
try:
    state, token = status(link, True)
    assert state == "READY"
    link.send("START incorrect")
    expect(link, "AF1 REFUSED command")
    assert status(link, True) == ("READY", token)
    if os.getenv("AF_QA_DISCONNECT") == "1":
        link.send("START " + token)
        expect(link, f"AF1 RUNNING {token} virtual=1")
        link.close()
        time.sleep(2)
        link = Channel(None, sys.argv[1])
        assert status(link, True) == ("DONE", token)
        print("RAM_AF_RECONNECTED after_start=1 result_retained=1")
    else:
        assert result(link, token, True, True) == 0
    link.send("START " + token)
    expect(link, "AF1 REFUSED consumed")
    assert status(link, True) == ("DONE", token)
    assert result(link, token, True, False) == 0
    print("RAM_AF_PROTOCOL_PASS wrong_start_rejected=1 synthetic=1 one_execution=1 replay=1")
finally:
    link.close()
