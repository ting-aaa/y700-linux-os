#!/usr/bin/env bash
# Export only bounded aggregate key/value rows from the pinned camera measurement tools.
set -eu
export LC_ALL=C
rows=0
while IFS= read -r line; do
    if [[ $line == *' AF_DIAG phase='* ]]; then line="AF_DIAG phase=${line#* AF_DIAG phase=}"; fi
    if (( ${#line} <= 640 && rows < 256 )) &&
        [[ $line =~ ^AF_(PREVIEW|SCAN|RESULT|EXPOSURE|DIAG|CLEANUP|ERROR)(\ [a-z_]+=[a-zA-Z0-9_./:+-]+)+$ ]]; then
        printf '%s\n' "$line"
        ((++rows))
    fi
done
