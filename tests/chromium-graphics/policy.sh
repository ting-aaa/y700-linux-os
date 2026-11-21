#!/bin/bash
# Exercise the packaged launch hook against GLib without a display or a browser.
set -euo pipefail
src=$(cd "$(dirname "$0")/../../packaging/chromium-graphics" && pwd)
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
export XDG_CONFIG_HOME=$work/config GSETTINGS_BACKEND=keyfile GSETTINGS_SCHEMA_DIR=$work/schemas
mkdir "$GSETTINGS_SCHEMA_DIR"
cp "$src/org.y700.chromium.gschema.xml" "$GSETTINGS_SCHEMA_DIR"
glib-compile-schemas --strict "$GSETTINGS_SCHEMA_DIR"
hook() {
    CHROMIUM_FLAGS=$1 dash -ec '
        file=$1; shift; . "$file"
        printf "%s\n" "$CHROMIUM_FLAGS"
    ' sh "$src/99-y700-software-rendering" "${@:2}"
}
existing=--disable-pings
[[ $(hook "$existing") == "$existing --disable-gpu" ]]
gsettings set org.y700.chromium hardware-acceleration true
[[ $(hook "$existing") == "$existing --use-gl=angle --use-angle=vulkan" ]]
[[ $(hook "$existing" --headless=new) == "$existing --use-gl=angle --use-angle=vulkan --enable-gpu" ]]
[[ $(hook "$existing" --disable-gpu) == "$existing" ]]
[[ $(hook "$existing" --use-angle=swiftshader) == "$existing" ]]
[[ $(hook "$existing --use-gl=egl") == "$existing --use-gl=egl" ]]
[[ $(XDG_CONFIG_HOME=$work/other hook "$existing") == "$existing --disable-gpu" ]]
gsettings reset org.y700.chromium hardware-acceleration
[[ $(hook "$existing" --headless) == "$existing --disable-gpu" ]]
if command -v desktop-file-validate >/dev/null; then
    desktop-file-validate "$src/y700-chromium-graphics.desktop"
fi
echo CHROMIUM_GRAPHICS_POLICY_PASS
