# Y700 file manager touch test on the tablet

The USB runner launches the installed Xorg, Xfwm, Thunar and Onboard on a private 2560×1600 display at 200%. A normal test account sends direct XI2 touch events through Xorg's inputtest driver. AT-SPI locates the file manager controls. The companion ARM64 guest exercises Linux Type-B input and libinput. The board test covers the desktop software executing on the tablet. Finger contact on the physical glass is a separate check.

The test runs in private mount, process, IPC and network namespaces. Its separate home, D-Bus, X socket and temporary directories live in RAM. Xorg gets a dummy video driver, with no tablet console, physical input nodes or GPU in its device tree. The command compares the live boot, active seat, four desktop services, full package list and installed Thunar executable before and after. Its final argument can stage a candidate executable only inside that temporary filesystem.

Run in Linux or WSL with the pinned USB SSH helper, the Debian Xorg 21.1.16 inputtest protocol header, Trixie's arm64 dummy video driver package and an ARM64 uv binary. The host uses the AArch64 cross C compiler. A fresh private directory is created for each run.

```sh
Y700_THUNAR_STOCK=1 bash tests/thunar-board/run.sh "$ssh_helper" "$inputtest_header" "$dummy_deb" "$arm64_uv"
bash tests/thunar-board/run.sh "$ssh_helper" "$inputtest_header" "$dummy_deb" "$arm64_uv" "$candidate_deb"
bash tests/thunar-board/run.sh "$ssh_helper" "$inputtest_header" "$dummy_deb" "$arm64_uv"
```

The first command checks the stock package. The second previews a local package. The third checks an installed update. Results are printed to standard output. [Shared file manager exercise](../thunar-touch/exercise.py) · [X.Org touch event model](https://www.x.org/Development/Documentation/Multitouch/)
