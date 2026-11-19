# Two LightDM sign-ins with different display languages

Use a disposable ARM64 Xfce seat with the `chinese-ime` layer, a new test account with an English desktop, Debian's GTK 3 Python bindings, and an ARM64 `uv` executable on the user's PATH. The test saves the user's language preference. The initial and returning sessions both go through LightDM on seat0.

In the first English Xfce session, run these commands from the repository as the test user. Keep the same state directory across logout.

```sh
set -eu
state="$HOME/.local/state/y700-language-test"
entry="$HOME/.config/autostart/y700-language-test.desktop"
uv_bin=$(command -v uv)
test ! -e "$state"
test ! -e "$entry"
install -d -m 0700 "$state"
install -d "$(dirname "$entry")"
install -m 0644 tests/display-language/observe-session.py "$state/observe-session.py"
cat > "$entry" <<EOF
[Desktop Entry]
Type=Application
Name=Y700 display language test
Exec="$uv_bin" run --offline --no-project --python /usr/bin/python3 python "$state/observe-session.py" "$state"
OnlyShowIn=XFCE;
Terminal=false
EOF
"$uv_bin" run --offline --no-project --python /usr/bin/python3 python "$state/observe-session.py" "$state"
```

1. In the product's **Display language** window, select **简体中文** within two minutes. Wait for the command to return. The first session stays in English.
2. Use the Xfce account menu to log out. Enter the same account and password in LightDM. The observer runs again through Xfce autostart. A standard GTK dialog shows Chinese buttons for about twelve seconds.
3. Inspect the saved session IDs and translated button label. Both sessions must report `service=lightdm type=x11 class=user active=yes`. Their IDs must differ. The second must report a Chinese locale and a GTK label containing `取消`. The system-wide default in this image remains English.

```sh
state="$HOME/.local/state/y700-language-test"
cat "$state/events"
test "$(cat "$state/first-session")" != "$(cat "$state/second-session")"
test "$(cat "$state/second-session")" = "$XDG_SESSION_ID"
grep -F 'Y700_LANG_TRANSLATED_GTK' "$state/events" | grep -F '取消'
grep -Fx 'LANG=en_US.UTF-8' /etc/default/locale
```

For the reference 1024×768 virtual seat, `--report-touch-target` adds the on-screen button coordinates to `Y700_LANG_CHOICE`. A host can send a contact at that point and observe `Y700_LANG_SAVED` before driving logout. Enrollment and password entry use the image's existing UI.

Remove the test autostart entry before a third login, retain the events with the test evidence, and shut down the disposable guest. In this account the entry is `~/.config/autostart/y700-language-test.desktop`.
