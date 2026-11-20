#!/bin/bash
# Read the coded caps that reach a stateful decoder, for both the original and remux.
set -euo pipefail
[[ $# == 2 ]] || { echo 'Usage: check-bt709.sh ORIGINAL_CLIPS LOOPED_CLIPS' >&2; exit 2; }
for folder in "$@"; do
    for name in h264.mp4 hevc.mp4 vp9.webm; do
        case $name in
            h264.mp4) demux=qtdemux; parser=h264parse; caps=video/x-h264,stream-format=byte-stream,alignment=au ;;
            hevc.mp4) demux=qtdemux; parser=h265parse; caps=video/x-h265,stream-format=byte-stream,alignment=au ;;
            vp9.webm) demux=matroskademux; parser=vp9parse; caps=video/x-vp9 ;;
        esac
        file=$folder/$name
        log=$(LC_ALL=C GST_DEBUG_NO_COLOR=1 timeout 15 gst-launch-1.0 -v filesrc "location=$file" \
            '!' "$demux" '!' "$parser" '!' "$caps" '!' fakesink)
        line=$(grep -F '/GstFakeSink:fakesink0.GstPad:sink: caps =' <<< "$log" | tail -1)
        for field in 'width=(int)1920' 'height=(int)1080' 'bit-depth-luma=(uint)8' \
                'bit-depth-chroma=(uint)8' 'chroma-format=(string)4:2:0' 'colorimetry=(string)bt709'; do
            if [[ $line != *"$field,"* && $line != *"$field" ]]; then
                echo "$file: expected $field in $line" >&2
                exit 1
            fi
        done
        digest=$(sha256sum "$file")
        printf 'PARSED_BT709 folder=%s file=%s parser=%s width=1920 height=1080 depth=8 colorimetry=bt709 sha256=%s\n' \
            "$(basename "$folder")" "$name" "$parser" "${digest%% *}"
    done
done
