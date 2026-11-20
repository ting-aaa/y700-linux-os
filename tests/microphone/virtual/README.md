# Y700 microphone application test

This Linux PC test boots the sealed dev12.9 ARM64 userspace twice using the prepared 7.3.4 Asphalt kernel. Each QEMU process mounts the image read-only and gets a fresh RAM overlay, a virtual ALSA card and an isolated D-Bus session. The only signal sources are generated PCM samples. The guest uses the image's ordinary `y700` account, ALSA, WirePlumber, PipeWire and Pulse-compatible server.

```sh
bash tests/microphone/virtual/run.sh "$prepared_kernel" "$dev12_9_root" \
    "$arm64_static_busybox" "$arm64_uv" "$new_log_dir"
```

Host dependencies include ARM64 QEMU, a prepared LLVM kernel module build, `aarch64-linux-gnu-gcc`, cpio, gzip and patch. `QEMU_SYSTEM_AARCH64`, `QEMU_FIRMWARE_DIR` and `AARCH64_CC` select alternate tool locations. The runner checks the sealed ext4, kernel Image and upstream PCM test driver against their pinned hashes. It stores the three candidate UCM hashes with both case logs.

The guest first reads the installed board verb. It then adds the [optional microphone profile](../../../packaging/microphone) to the RAM overlay while retaining the complete original speaker verb. The kernel fixture adapts Linux's PCM test driver to the board's two playback endpoints and optional capture endpoint. It gives capture and playback separate directions, restricts the formats to 48 kHz S16_LE stereo and services the buffer every 10 ms. ALSA userspace controls supply the enum values, switches and gains needed to execute the candidate UCM sequences. [Linux PCM test driver](https://docs.kernel.org/sound/cards/pcmtest.html)

| Guest hardware | Expected application result |
| --- | --- |
| D0p and D1p, all candidate mixer controls, no capture PCM | Speaker appears. WirePlumber exposes zero `Audio/Source` nodes. The speaker monitor delivers the 375 Hz test signal on both channels. |
| Same hardware plus D2c | A Mic source appears at `hw:LenovoY700,2`. The ordinary Pulse recording client opens its default source and reads the generated 1,000 Hz left / 1,500 Hz right signal. A simultaneous recording of the speaker monitor contains 375 Hz on both channels. |

The client reads 48,000 stereo frames per stream. It checks the ALSA capture PCM's running state, rate, format and channel count, then compares the three frequencies on each channel. The client retains samples only in guest memory. The VM can establish device selection, UCM behavior and audio transport through the shipping application interfaces. Physical microphone bias, SoundWire, the AudioReach DSP and acoustic channel placement require board measurements. [Pulse recording interface](https://www.freedesktop.org/software/pulseaudio/doxygen/simple.html)

Both cases passed on the dev12.9 root `e40d2b7b297913c7200d2238f8f79d5a28926b983866cf09ca61f3dcbd8a0ddb`, with PipeWire 1.4.2, WirePlumber 0.5.8 and libasound 1.2.14. On the playback-only card an ordinary Pulse default-input request also returned the 375 Hz speaker monitor. On the capture card the same request returned the distinct stereo microphone pattern while the separately opened monitor retained the playback signal.

The mixer checks run twice while both clients hold their streams after receiving a full second. In the capture case the ADC1/ADC3 switches, DEC2/DEC5 and TX3 were enabled. The virtual speaker controls showed Protection, DSP_TX1, raw gain 249 and both power switches on in both cases. One earlier fixture sample taken when the PCM first entered RUNNING observed a speaker switch still off. PCM startup alone is insufficient to establish the duplex mixer state. The local receipts are `out/microphone/final-virtual/{playback,capture}.log`.
