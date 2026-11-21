#!/bin/bash
# Retained interface for the original RTC1 supplement.
exec bash "$(dirname "$0")/build-dt-probe-entry.sh" --rtc1 "$@"
