# Y700 internal speaker routing and digital gain

The dev11 platform profile corrects a mute setting on both internal CS35L45 amplifiers. On the real TB320FC_PRC, both amplifiers moved from raw 0 (mute) to raw 249 (**−40.00 dB**) when the signed-in desktop reloaded the profile. Five seconds of digital silence then reached both protected speaker routes. Actual sound from the left and right grilles still needs a listener. [Managed profile](../packaging/root/usr/share/alsa/ucm2/Lenovo-Y700/HiFi.conf) · [Original Asphalt profile](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/asphalt/HiFi.conf#L15-L47)

## Read-only observations with the dev10 profile

| Part of the signal path | Observation |
| --- | --- |
| Desktop | The default WirePlumber sink opened the `HiFi: Speaker: sink` profile for `hw:LenovoY700,0`. Its advertised positions were `FL,FR`. |
| Board and codecs | ASoC DAPM linked **Speaker Left** to `SPK1 SPK` on I²C 6 at `0x30` and **Speaker Right** to `SPK2 SPK` at `0x31`. Both codec drivers were `cs35l45`. |
| Serial audio and protection | Both DSPs selected `ASP_RX1` and `ASP_RX2` for inputs 1 and 2. Their remaining six inputs selected `VMON`, `IMON`, `VDD_BATTMON`, `VDD_BSTMON`, `CLASSH_TGT` and `VDD_BATTMON`. Both DACs selected `DSP_TX1`. |
| Firmware at each amplifier | The ASoC DSP debug interface reported firmware ID `0x0004fa00`, version `0x00002e01` twice. It recorded the `spk1-` and `spk2-` versions of `cs35l45-dsp1-spk-prot.wmfw` and their corresponding `.bin` coefficient files. |
| Gain and idle state | Both digital controls reported integer range 0–457, TLV minimum −102.25 dB, step 0.25 dB and a mute flag at raw 0. Both simple mixer values read `0 [0%] [-99999.99dB]`. The analog controls both read raw 0, equivalent to +10 dB on their separate scale. Both playback PCMs were closed, both speaker widgets were off and both amplifiers reported runtime-suspended. |

The original extracted Android `sku_cape/mixer_paths_waipio_mtp.xml` assigns receive slots 0/1 on **both** chips and routes each DAC through its local `DSP_TX1`. The two factory coefficient sets identify left and right deployment groups. This supports the Debian topology's use of both incoming channels on each DSP. The transfer from each input to each mono driver, any stereo crossfeed, the audible level and the physical grille positions in a given orientation require separate assessment. The earlier ALSA and PipeWire streams established successful digital playback and active links. Their exit codes cannot establish the resulting acoustic level. [Board topology](https://github.com/dianqk/nixos-android-devices/blob/8dcb481fc2ce91794fd294630e06f15a52ec7513/pkgs/asphalt/audio/Lenovo-Y700.m4) · [Prior playback and factory coefficients](PERIPHERALS.md#built-in-speakers) · [CS35L45 hardware](https://www.cirrus.com/products/cs35l45)

## Why raw 249

Debian's ALSA UCM engine calls `snd_ctl_ascii_value_parse` for `cset`. Its integer path handles integer and percentage values. It reads the leading `-40` in `-40dB` and clamps it to the control's minimum of zero. For nonzero raw values on these amplifiers, the TLV gives `−102.25 + raw × 0.25` dB. Raw 249 therefore implements the board profile's intended attenuation. The profile retains the original analog gain, protection firmware, DSP inputs, amplifier enable sequence and disable sequence. This repair applies to the internal speaker profile. The observation exposed two playback PCMs and no capture PCM. Microphone capture, headphone output, maximum safe volume and acoustic tuning have separate evidence requirements. [ALSA UCM executor](https://github.com/alsa-project/alsa-lib/blob/v1.2.14/src/ucm/main.c#L456-L467) · [ALSA integer parser](https://github.com/alsa-project/alsa-lib/blob/v1.2.14/src/control/ctlparse.c#L51-L75) · [Cirrus control and TLV](https://github.com/torvalds/linux/blob/master/sound/soc/codecs/cs35l45.c)

The ordinary platform package owns `/usr/share/alsa/ucm2/Lenovo-Y700/HiFi.conf`. Its SHA-256 changes from `1ba9c514c4aae63f849e8bd64c1d90d2541ae45854379101db65896630770110` to `a3fa9c79d3c0233825d34c3dfd5376d0243e02e1af3445a80d73d50c8d09cd36`. The image builder retains the packaged file when staging the upstream card definition. Installing the file and applying its new settings are distinct operations. ALSA selects these settings when a client loads the new profile and enables the speaker device.

## Physical dev11 activation and digital playback

After package installation, the active X11 user still had the original PipeWire graph and both hardware gains read 0. The session had no existing streams or active links. Both PCM devices were closed and both amplifiers were suspended. One restart of that user's WirePlumber loaded the corrected profile. PipeWire and pipewire-pulse kept their existing invocations. ALSA reported `249 [54%] [-40.00dB]` independently for SPK1 and SPK2.

The test supplied 960,000 zero bytes as two-channel S16_LE audio at 48 kHz to the existing default speaker sink. Exactly two PipeWire links became active, FL → FL and FR → FR. The board's MultiMedia1 playback PCM reported RUNNING, S16_LE, 48 kHz and two channels. Its hardware pointer advanced from 16,800 to 25,920 frames across consecutive observations. During that interval **Speaker Left** and **Speaker Right** both reported On in DAPM. The firmware selections, DSP inputs and `DSP_TX1` DAC routes matched the protective profile before and after playback.

The stream drained successfully. The sink returned to suspended with zero streams and zero active links, both PCMs closed and both amplifiers runtime-suspended. The desktop volume remained 0.40, both channel volumes remained 0.063997 and the mute flags stayed clear. The boot, local X11 session, USB maintenance connection and default sink/profile remained intact. The kernel journal contained zero new matching audio-driver faults, and the new WirePlumber invocation contained zero matching audio errors. This run sent silence throughout and made no microphone recording. The local receipts are `out/speaker-ucm/physical-dev11-active.log` and `physical-dev11-after.log`.

## ARM64 reproduction

The complete old and new profiles ran through the packaged `alsaucm -c hw:Y700Dummy set _verb HiFi set _enadev Speaker` on the Y700 kernel with Debian `libasound2t64 1.2.14-1+deb13u1`. A virtual ALSA card exposed the measured raw range and TLV. Both digital controls began each test at a nonzero value. Stock UCM moved both to 0 and the simple mixer printed its mute indicator. Corrected UCM moved both to 249 and the simple mixer printed `[-40.00dB]`. The regression also checked each DAC input, all eight DSP input selections, both protection firmware selections, analog gain and the remaining profile bytes.

```sh
bash tests/speaker-ucm/run-qemu.sh "$prepared_y700_kernel_tree" "$dev10_or_dev11_qcow2" "$arm64_static_busybox"
```

The runner builds the upstream `snd-dummy` module in a temporary directory, attaches the product root read-only and executes the test in a RAM overlay. The fixture opens only a sound control device. It passed with `Y700_SPEAKER_UCM_PASS` and `SPEAKER_FIXTURE_EXIT=0`. [Regression](../tests/speaker-ucm/guest.sh)

## Touch volume and mute

Tap the speaker icon on the Xfce panel. The top row controls playback. Tap its slider to change volume or its switch to mute and unmute. If your panel has no speaker icon, open **Settings → Panel → Items → Add**, then choose the installed **PulseAudio Plugin**. [Xfce panel settings](https://docs.xfce.org/xfce/xfce4-panel/preferences#items) · [Xfce audio plugin](https://docs.xfce.org/panel-plugins/xfce4-pulseaudio-plugin/start)

In the isolated dev11.1 ARM64 desktop at 200%, the stock plugin responded to synthetic pointer taps. The private PipeWire Pulse server reported playback changing from about 47% to 77%, switching to muted and back at 77%, then returning to the exact selected 47% level in both channels. The software sink carried digital silence to keep its audio format active. It had no hardware audio device. This qualifies the menu and its software control path. Audible output from the tablet speakers still requires separate evidence.

## Attended stereo check

With the corrected profile active, run the following from a terminal in the tablet's signed-in desktop. The probe checks that the default sink is the protected internal speaker and that both hardware controls already report −40.00 dB. It waits for Enter and sends a 440 Hz tone at 1% of digital full scale, first exclusively left and then exclusively right, with a quarter-second quiet interval. It opens a targeted playback stream and leaves volume and routing controls alone.

```sh
uv run --offline --no-project --python /usr/bin/python3 python tests/speaker-ucm/listen.py --listen
```

Record which physical edge faces the USB port, which grille responds in each interval and whether either interval is silent or audible from both sides. The probe has not been played on the physical tablet during this investigation. [Attended probe](../tests/speaker-ucm/listen.py)
