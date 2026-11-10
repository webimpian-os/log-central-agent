#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
fixtures="$root/tests/fixtures/wp-inventory"

for panel in runcloud plesk; do
    actual="$(AGENT_HOSTNAME=web-01 AGENT_PANEL="$panel" AGENT_SITES_TABLE="$fixtures/sites.csv" \
        AGENT_RUNCLOUD_HOME="$fixtures/home" AGENT_PLESK_VHOSTS="$fixtures/vhosts" "$root/bin/wp-inventory" --print \
        | sed "s|$fixtures|FIXTURES|g")"

    if [ "$actual" != "$(cat "$fixtures/$panel.expected.jsonl")" ]; then
        echo "wp-inventory: unexpected inventory for $panel" >&2
        diff <(echo "$actual") "$fixtures/$panel.expected.jsonl" >&2 || true
        exit 1
    fi
done

echo "wp-inventory ... passed"
