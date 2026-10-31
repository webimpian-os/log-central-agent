#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
vector="${VECTOR:-vector}"

"$vector" test config/pipeline.yaml tests/runtime.yaml tests/*.test.yaml
tests/refresh_sites.test.sh

if command -v shellcheck >/dev/null; then
    shellcheck install.sh uninstall.sh bin/refresh-sites scripts/*.sh tests/*.sh
    echo "shellcheck ... passed"
else
    echo "shellcheck ... skipped (not installed)"
fi
