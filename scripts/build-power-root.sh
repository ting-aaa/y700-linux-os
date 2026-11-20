#!/bin/bash
# Compatibility entry point for regenerating the two sealed dev12.7 variants.
set -euo pipefail
layer=power-desktop
if [[ ${1:-} == --blueman-update ]]; then layer=blueman; shift; fi
exec bash "$(dirname "$0")/update-sealed-root.sh" "$layer" "$@"
