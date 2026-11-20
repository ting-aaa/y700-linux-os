#!/usr/bin/env bash
# Preserve the original dev12.5 command line and archive timestamp.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
export SOURCE_DATE_EPOCH=1795132800
exec bash "$here/package-board-image.sh" dev12.5 "$@"
