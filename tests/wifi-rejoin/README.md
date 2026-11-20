# Automatic WPA3 rejoin

Use the existing [ARM64 Wi-Fi chooser fixture](../wifi-chooser/run-vm.sh) inputs. Supply the sealed Y700 root in `RAW_ROOT`, `ROOT_FORMAT=qcow2` for a QCOW2 root, the matching `KERNEL_IMAGE` and [hwsim module](../wifi-chooser/build-hwsim.sh) in `HWSIM_MODULE`. Set `QEMU`, `QEMU_DATA`, `ARM64_BUSYBOX` and `ARM64_UV` to the corresponding tools. The ARM64 `WIFI_DEBS` directory supplies `hostapd`, `dnsmasq-base`, `iw` and `libnftables1`. The ARM64 `X11_DEBS` directory supplies `xvfb`, `xdotool` and `libxdo3`.

```sh
bash tests/wifi-rejoin/run.sh same
bash tests/wifi-rejoin/run.sh alternate
```

Both modes initially connect from a real ordinary local PAM session using the production NetworkManager applet and one generated WPA3 password. The AP and DHCP server are in a separate guest network namespace. The test stops only its own hostapd process, waits for association, NetworkManager activation and IPv4 to disappear, and checks that a station-bound ping fails. After starting hostapd again, the station must activate the original saved profile automatically, negotiate SAE and PMF, obtain its DHCP configuration and send two station-bound pings to the AP. The original applet remains running to watch for password prompts.

`same` performs two stop/start cycles against the same AP. `alternate` adds a third cycle on a second hwsim AP radio with a distinct BSSID and the same SSID, credentials and guest network. The third cycle describes service rediscovery on a different BSSID after a complete outage. The AP uses normal hostapd shutdown and startup. There is no management-frame injection or device passthrough. QEMU has no external network and attaches the root read-only.
