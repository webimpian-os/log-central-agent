#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "error: run as root (sudo)" >&2; exit 1; }

systemctl disable --now runcloud-log-central-sites.timer runcloud-log-central.service 2>/dev/null || true
rm -f /etc/systemd/system/runcloud-log-central.service \
    /etc/systemd/system/runcloud-log-central-sites.service \
    /etc/systemd/system/runcloud-log-central-sites.timer
systemctl daemon-reload

rm -rf /opt/runcloud-log-central /etc/runcloud-log-central /var/lib/runcloud-log-central
if id -u runcloud-log-central >/dev/null 2>&1; then
    userdel runcloud-log-central
fi

echo "==> runcloud-log-central removed"
