#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

table="$work/sites.csv"
expected="webapp,domain
demoshop,demo-shop.test
noalias,
wildcard,wild.test
wwwonly,www.only.test"

AGENT_APACHE_CONF_DIR="$root/tests/fixtures/apache2-rc" AGENT_SITES_TABLE="$table" "$root/bin/refresh-sites"

if [ "$(cat "$table")" != "$expected" ]; then
    echo "refresh-sites: unexpected table" >&2
    diff <(echo "$expected") "$table" >&2 || true
    exit 1
fi

before="$(stat -c %Y "$table" 2>/dev/null || stat -f %m "$table")"
sleep 1
AGENT_APACHE_CONF_DIR="$root/tests/fixtures/apache2-rc" AGENT_SITES_TABLE="$table" "$root/bin/refresh-sites"
after="$(stat -c %Y "$table" 2>/dev/null || stat -f %m "$table")"

if [ "$before" != "$after" ]; then
    echo "refresh-sites: rewrote an unchanged table" >&2
    exit 1
fi

leftovers=("$work"/sites.csv.*)
if [ -e "${leftovers[0]}" ]; then
    echo "refresh-sites: left a temp file behind" >&2
    exit 1
fi

echo "refresh-sites ... passed"
