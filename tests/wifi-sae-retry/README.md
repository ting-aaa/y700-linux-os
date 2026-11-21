# WPA3 saved-password retry with a NetworkManager SecretAgent

The guest runs the two ARM64 client packages, NetworkManager and wpa_supplicant, on a read-only dev12.10 root with a volatile overlay. The existing Wi-Fi chooser fixture supplies two mac80211_hwsim radios, hostapd and a separate DHCP namespace. A local PAM seat runs this focused D-Bus client as the ordinary desktop UID. The graphical chooser has its own test in `tests/wifi-chooser`.

Set the input variables documented at the top of `tests/wifi-chooser/run-vm.sh`. Set `WIFI_CANDIDATE_DEBS` to the directory holding the two verified update packages. Run from Linux with QEMU's ARM64 system emulator.

```sh
bash tests/wifi-sae-retry/run.sh
```

The default AP uses the Debian 13 hostapd 2.10 package. The test first attempts a generated, absent SAE network. It requires a real association timeout with no request for replacement credentials. For the visible AP it saves a deliberately incorrect synthetic password, selects the explicit AP and checks the station's reported authentication status. With status 1 the first activation must fail before explicitly selecting the same AP and profile a second time. The agent supplies the correct synthetic password only in response to a request with `ALLOW_INTERACTION | REQUEST_NEW`. It checks the active AP, profile UUID, unrelated profile settings and negotiated SAE and PMF. DHCP and ping exercise the virtual link. Authentication status and NetworkManager failure reason are reported separately.

The absent-network and retry actors have 60- and 117-second process limits. The VM has a 240-second host timeout. SSIDs, addresses, passphrases and profile UUIDs are omitted from the receipt. Set `WIFI_AP_DEBS` to the chooser fixture's pinned modern AP directory to exercise the separate automatic status-15 path.

The stock hostapd 2.10 run on dev12.10 recorded five station-side `AuthStatusCode=1` notifications, a failed first activation with NetworkManager reason 53, and exactly one replacement request on the second selection with flags 7. The daemon reported zero automatic prompts and one explicit prompt. The absent-network control also timed out with reason 53 and made zero replacement requests. The VM exited successfully after 136 seconds of guest uptime. The local receipt is `out/wifi-sae-retry/legacy-agent-2.log` with SHA-256 `250825b9ccd6c697279272df56c688426f0da9a966e6151994504714924260c3`.
