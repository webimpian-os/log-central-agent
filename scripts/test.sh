#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
vector="${VECTOR:-vector}"

for panel in config/panels/*.yaml; do
    echo "== $(basename "$panel" .yaml)"
    "$vector" test config/pipeline.yaml "$panel" tests/runtime.yaml tests/*.test.yaml
done
tests/refresh_sites.test.sh
tests/patch_report.test.sh
tests/wp_inventory.test.sh
VECTOR="$vector" tests/traffic.test.sh

if command -v shellcheck >/dev/null; then
    shellcheck install.sh uninstall.sh php-log-limit.sh bin/refresh-sites bin/patch-report bin/wp-inventory scripts/*.sh tests/*.sh
    echo "shellcheck ... passed"
else
    echo "shellcheck ... skipped (not installed)"
fi
