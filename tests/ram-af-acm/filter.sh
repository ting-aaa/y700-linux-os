#!/usr/bin/env bash
# Export only bounded aggregate key/value rows from the pinned camera measurement tools.
set -eu
export LC_ALL=C
rows=0
while IFS= read -r line; do
    if [[ $line == *' AF_DIAG phase='* ]]; then line="AF_DIAG phase=${line#* AF_DIAG phase=}"; fi
    if [[ $line == 'AF_CONFIG_RESOURCE '* ]]; then
        path=${line#* path=}; path=${path%% *}
        case $path in
            /dev/dma_heap/linux,cma|/dev/dma_heap/reserved|/dev/dma_heap/system|/dev/udmabuf) ;;
            /opt/y700-camera/lib/libcamera/ipa/ipa_soft_simple.so|/opt/y700-camera/lib/libcamera/ipa/ipa_soft_simple.so.sign) ;;
            /opt/y700-camera/libexec/libcamera/soft_ipa_proxy|/opt/y700-camera/share/libcamera/ipa/simple/hi1339.yaml|/opt/y700-camera/share/libcamera/ipa/simple/uncalibrated.yaml) ;;
            *) continue ;;
        esac
    fi
    if (( ${#line} <= 640 && rows < 256 )) &&
        [[ $line =~ ^AF_(PREVIEW|SCAN|RESULT|EXPOSURE|DIAG|CLEANUP|ERROR|CONFIG|CONFIG_RESOURCE|CONFIG_ONLY|ALLOCATOR|TEST)(\ [a-z_]+=[a-zA-Z0-9_.,/:+-]+)+$ ]]; then
        printf '%s\n' "$line"
        ((++rows))
    fi
done
