# Saved WPA3 password recovery

Use the standard `run-vm.sh` input paths listed in [the Wi-Fi chooser guide](../../docs/WIFI-CHOOSER.md). The sealed dev12.10 root used for these cases has SHA-256 `18e75eff99d13c9aa6e446eaf03d79d5ac0122f9815f9419d96715a2e6e426fd`. All radios belong to the ARM64 guest. The AP runs in a separate network namespace, with local DHCP and no external network.

To repeat the confirmed ordinary-user GTK case, put the two candidate packages from the [offline update](../../docs/WIFI-PASSWORD-RETRY.md) in one directory. Put the four signed Debian ARM64 AP/test-runtime archives named in `hostapd-2.11.sha256` in another. Only the modern AP process uses those private libraries.

```sh
WIFI_SECURITY=sae WIFI_ACTOR=seat WIFI_ATTEMPT=chooser WIFI_KEYBOARD=gtk \
  WIFI_CANDIDATE_DEBS="$CANDIDATE_DEBS" WIFI_AP_DEBS="$AP_2_11_DEBS" \
  bash tests/wifi-chooser/run-vm.sh
```

The random incorrect and correct test passwords are supplied to the masked GTK entry. The most recent 100% Xfce run observed supplicant status 15, NetworkManager's request for new credentials and an automatically reopened nm-applet dialog. After correction, the original profile UUID was active and the unrelated profile retained its settings. The AP independently reported SAE and protected management frames. DHCP and an interface-bound ping crossed the virtual wireless link.

Without `WIFI_AP_DEBS` the fixture uses the older Debian AP. `WIFI_ATTEMPT=blocked` checks a stock client's missing second dialog over 50 seconds after a manual reselection. `WIFI_ATTEMPT=cancel` also checks that cancelling a retry leaves the station disconnected and the profile identities intact. Each case requires its own passing receipt.

Omitting `WIFI_KEYBOARD=gtk` selects a 200% Xfce desktop and the installed Onboard keyboard. Its receipt counts the actual key taps and checks the masked field length. The optional `WIFI_TOUCHSCREEN=1 DUMMY_DEB=…` uses a virtual Type B touchscreen through Xorg/libinput. The radio and 100% GTK result above does not qualify the full 200% touchscreen path.
