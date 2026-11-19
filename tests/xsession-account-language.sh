#!/bin/dash
# Exercise Debian's sourced Xsession fragments without using a real account bus.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
hook=${1:-$here/../packaging/input-pinyin/35y700_account_language}
user_hook=${2:-/etc/X11/Xsession.d/40x11-common_xsessionrc}
test -r "$hook" && test -r "$user_hook"
work=$(mktemp -d)
trap 'rm -f -- "$work/calls" "$work/xsessionrc"; rmdir -- "$work"' EXIT

uid=1000
backend=normal
language='s "zh_CN.utf8"'
export LANG=C.UTF-8 LANGUAGE=en_GB:en LC_TIME=C XDG_SESSION_CLASS=user
id() {
    test "$*" = -u || return 1
    printf '%s\n' "$uid"
}
busctl() {
    printf '%s\n' "$3" >> "$work/calls"
    test "$1" = --system && test "$2" = --timeout=2s || return 1
    case $3 in
        call)
            test "$4 $5 $6 $7 $8 $9" = "org.freedesktop.Accounts /org/freedesktop/Accounts org.freedesktop.Accounts FindUserById x $uid" || return 1
            case $backend in
                no-bus) return 1 ;;
                foreign) printf 'o "/org/freedesktop/Accounts/User1001"\n' ;;
                *) printf 'o "/org/freedesktop/Accounts/User%s"\n' "$uid" ;;
            esac ;;
        get-property)
            test "$4 $5 $6 $7" = "org.freedesktop.Accounts /org/freedesktop/Accounts/User$uid org.freedesktop.Accounts.User Language" || return 1
            test "$backend" != unavailable || return 1
            printf '%s\n' "$language" ;;
        *) return 1 ;;
    esac
}

unchanged() {
    . "$hook"
    test "$LANG:$LANGUAGE:$LC_TIME" = C.UTF-8:en_GB:en:C
}
(backend=no-bus; unchanged)
(
    busctl() {
        shift  # Route --system to a private, nonexistent socket for this case.
        command busctl --address="unix:path=$work/absent" "$@"
    }
    unchanged
)
(backend=unavailable; unchanged)
(: > "$work/calls"; backend=foreign; unchanged; test "$(cat "$work/calls")" = call)
for record in 's ""' 's "fr_FR.UTF-8"' 's "zh_CN.UTF-8@invalid"' 's "en_US.UTF-8" extra'; do
    (language=$record; unchanged)
done
(: > "$work/calls"; uid=0; unchanged; test ! -s "$work/calls")
(: > "$work/calls"; XDG_SESSION_CLASS=greeter; unchanged; test ! -s "$work/calls")

(
    . "$hook"
    test "$LANG:$LANGUAGE:$LC_TIME" = zh_CN.UTF-8:zh_CN:zh:C
    printf '%s\n' 'export LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_MESSAGES=en_US.UTF-8' > "$work/xsessionrc"
    USERXSESSIONRC=$work/xsessionrc
    . "$user_hook"
    dash -ec 'test "$LANG:$LANGUAGE:$LC_MESSAGES:$LC_TIME" = en_US.UTF-8:en_US:en:en_US.UTF-8:C'

    printf '%s\n' 'unset LANGUAGE; export LANG=en_US.UTF-8' > "$work/xsessionrc"
    . "$hook"
    . "$user_hook"
    dash -ec 'test "$LANG" = en_US.UTF-8 && test -z "${LANGUAGE+x}"'
)
(
    unset XDG_SESSION_CLASS LANGUAGE
    language='s "en_US.UTF-8"'
    . "$hook"
    dash -ec 'test "$LANG:$LANGUAGE" = en_US.UTF-8:en_US:en'
)
printf '%s\n' 'PASS dash Xsession account lookup, fallback, session class and explicit user locale override'
