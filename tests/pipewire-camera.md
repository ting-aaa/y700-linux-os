# Finite PipeWire camera check

Build the [probe](pipewire-camera.c) against the Debian libpipewire and libspa development headers. The executable uses the system PipeWire library on the tablet.

```sh
cc -std=gnu11 -O2 $(pkg-config --cflags libpipewire-0.3 libspa-0.2) \
  tests/pipewire-camera.c $(pkg-config --libs libpipewire-0.3 libspa-0.2) \
  -o pw-camera-probe
```

Run the executable as the active desktop user against that user's PipeWire graph. The camera source must already be available. Use the CPU software ISP on the camera producer when validating that path.

```sh
./pw-camera-probe --list
./pw-camera-probe hi1339 SERIAL 12 20
./pw-camera-probe s5k4h7 SERIAL 12 20
./pw-camera-probe sc202cs SERIAL 12 20
```

Use the `serial` from `--list` for each sensor. The probe matches the exact board camera path in `api.libcamera.path` when present. An exact WirePlumber board node name can identify a source without that property. When both identify a sensor, they must agree. The probe verifies the PipeWire Link to the selected source and negotiates linear 640×480 raw colour. A passing receipt reports the negotiated format, dimensions and total bytes from the requested number of valid buffers. It reads buffer metadata and never opens or writes pixel payloads. Missing, empty and incomplete samples fail.

For a Camera portal test, have the authorized client pass its `OpenPipeWireRemote` socket into the probe as `Y700_CAMERA_PORTAL_FD` or `--fd FD`. Discovery and capture use that connection. `--list` reports the board sources visible on it.

Stock portal permissions can hide Link objects. In an isolated test graph, start an independently authorized QA observer before capturing. Use a fresh token to correlate the capture stream and Link with the selected source, for example `pw-camera-probe --fd FD --observer TOKEN hi1339 SERIAL 12 20`. The probe prints `CAMERA_SAMPLE` with its stream name and target node ID. A portal acceptance requires both that sample and the observer's matching Link evidence. The observer can use its separate permission to read the test graph while the capture stays within the granted connection.

Use the [portal access helper](camera-portal-access.py) for discovery and the [capture witness](camera-portal-capture.py) for an automated `PORTAL_CAMERA_OK` receipt. Run in an authorized interactive or isolated desktop profile and respond to the normal consent dialog when prompted. Repeat the capture with each sensor's serial from discovery.

```sh
uv run --offline --no-project --python /usr/bin/python3 python \
  tests/camera-portal-access.py -- ./pw-camera-probe --list
uv run --offline --no-project --python /usr/bin/python3 python \
  tests/camera-portal-capture.py ./pw-camera-probe hi1339 SERIAL 12 20
```
