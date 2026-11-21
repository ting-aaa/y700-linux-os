#!/bin/bash
set -eu
[[ $# == 3 && ( $1 == tap || $1 == hold ) && $2 =~ ^[0-9]+$ && $3 =~ ^[0-9]+$ ]]
printf '%s %s %s\n' "$@" >"$XDG_RUNTIME_DIR/contact.req"
read -r reply <"$XDG_RUNTIME_DIR/contact.ack"
test "$reply" = OK
