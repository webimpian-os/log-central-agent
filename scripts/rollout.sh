#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
options=()
hosts=()

while [ $# -gt 0 ]; do
    case "$1" in
        --url | --app)
            [ $# -ge 2 ] || { echo "error: $1 needs a value" >&2; exit 1; }
            options+=("$1" "$2")
            shift 2
            ;;
        -*) echo "error: unknown option: $1" >&2; exit 1 ;;
        *) hosts+=("$1"); shift ;;
    esac
done

[ ${#hosts[@]} -gt 0 ] || { echo "usage: scripts/rollout.sh [--url URL] [--app SLUG] host..." >&2; exit 1; }

if [ -n "${LOG_CENTRAL_TOKEN:-}" ]; then
    options+=(--token-stdin)
fi

args=""
for option in ${options[@]+"${options[@]}"}; do
    args+=" $(printf '%q' "$option")"
done

for host in "${hosts[@]}"; do
    echo "==> $host"
    remote_dir="$(COPYFILE_DISABLE=1 tar -C "$root" --no-xattrs -cz install.sh config bin systemd \
        | ssh "$host" 'dir="$(mktemp -d)" && tar -xz -C "$dir" && echo "$dir"')"
    printf '%s\n' "${LOG_CENTRAL_TOKEN:-}" \
        | ssh "$host" "bash $remote_dir/install.sh$args; status=\$?; rm -rf $remote_dir; exit \$status"
done
