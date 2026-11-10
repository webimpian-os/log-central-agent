#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

for expected in "$root"/tests/fixtures/patch-report/*.expected.json; do
    os="$(basename "$expected" .expected.json)"
    actual="$(AGENT_PATCH_FIXTURES="$root/tests/fixtures/patch-report/$os" "$root/bin/patch-report" --print)"

    if [ "$actual" != "$(cat "$expected")" ]; then
        echo "patch-report: unexpected report for $os" >&2
        diff <(echo "$actual") "$expected" >&2 || true
        exit 1
    fi

    if command -v python3 >/dev/null && ! python3 -m json.tool <<<"$actual" >/dev/null; then
        echo "patch-report: the $os report is not valid JSON" >&2
        exit 1
    fi
done

echo "patch-report ... passed"
