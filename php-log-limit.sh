#!/usr/bin/env bash
set -euo pipefail

# Apache cuts error-log lines at 8 KB, so a higher limit buys nothing.
LIMIT=8192
FPM_FILE="00-log-central-agent.conf"
INI_FILE="99-log-central-agent.ini"
MARK="; Added by log-central-agent (php-log-limit.sh) so full PHP stack traces reach the error logs."

say() { printf '==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

undo=0
case "${1:-}" in
    "") ;;
    --undo) undo=1 ;;
    *) fail "unknown option: $1" ;;
esac

[ "$(id -u)" -eq 0 ] || fail "run as root (sudo)"

at_least() { [ "$(printf '%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]; }

# Succeeds only when the file changed. Empty content removes it.
sync_file() {
    if [ -z "$2" ]; then
        [ -f "$1" ] || return 1
        rm -f "$1"
    else
        [ -f "$1" ] && [ "$(cat "$1")" = "$2" ] && return 1
        printf '%s\n' "$2" > "$1"
    fi
}

passes_test() { "$bin" -t --fpm-config "$conf" > /dev/null 2>&1; }

failed=0
while read -r -u 3 pid title; do
    conf="${title#*master process (}"
    conf="${conf%)}"
    bin="$(readlink "/proc/$pid/exe")"
    bin="${bin% (deleted)}"
    version="$("$bin" -v 2> /dev/null | sed -n 's/^PHP \([0-9][0-9.]*[0-9]\).* (fpm.*/\1/p')"
    name="PHP $version ($conf)"

    if [ -z "$version" ]; then
        say "$name: skipped, can't tell its PHP version"
        continue
    fi
    if ! at_least "$version" 7.3; then
        say "$name: skipped, PHP before 7.3 has a fixed limit"
        continue
    fi
    include="$(sed -n 's/^[[:space:]]*include[[:space:]]*=[[:space:]]*//p' "$conf" | head -1)"
    case "$include" in
        */\*.conf) fpm_path="${include%/\*.conf}/$FPM_FILE" ;;
        *) say "$name: skipped, no pool folder to add to"; continue ;;
    esac
    if ! passes_test; then
        say "$name: skipped, its config test already fails"
        failed=1
        continue
    fi

    fpm_content="" ini_content="" ini_path=""
    if [ "$undo" -eq 0 ]; then
        fpm_content="$MARK"$'\n'"[global]"$'\n'"log_limit = $LIMIT"
        ini_content="$MARK"$'\n'"log_errors_max_len = 0"
    fi
    changed=0
    sync_file "$fpm_path" "$fpm_content" && changed=1
    # PHP 8.1 removed log_errors_max_len, which cuts messages at 1,024 characters too.
    if ! at_least "$version" 8.1; then
        scan="$("$bin" -i 2> /dev/null | sed -n 's/^Scan this dir for additional \.ini files => //p')"
        if [ -d "$scan" ]; then
            ini_path="$scan/$INI_FILE"
            sync_file "$ini_path" "$ini_content" && changed=1
        else
            say "$name: no ini folder, so its messages stay cut at 1,024 characters"
        fi
    fi
    if [ "$changed" -eq 0 ]; then
        say "$name: already done"
        continue
    fi

    if ! passes_test; then
        [ "$undo" -eq 1 ] || rm -f "$fpm_path" ${ini_path:+"$ini_path"}
        say "$name: config test failed, nothing reloaded"
        failed=1
        continue
    fi
    unit="$(ps -o unit= -p "$pid" | tr -d ' ')"
    kill -USR2 "$pid"
    sleep 3
    if [[ "$(ps -o args= -p "$pid" || true)" == "php-fpm: master process"* ]]; then
        say "$name: reloaded"
    else
        rm -f "$fpm_path" ${ini_path:+"$ini_path"}
        systemctl start "$unit" || true
        say "$name: did not come back after the reload, change removed and $unit started again"
        failed=1
    fi
done 3< <(pgrep -a -f '^php-fpm: master process')

exit "$failed"
