#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "error: run as root (sudo)" >&2; exit 1; }

systemctl disable --now log-central-agent-restart.timer log-central-agent-sites.timer log-central-agent.service 2>/dev/null || true
rm -rf /etc/systemd/system/log-central-agent.service \
    /etc/systemd/system/log-central-agent.service.d \
    /etc/systemd/system/log-central-agent-sites.service \
    /etc/systemd/system/log-central-agent-sites.timer \
    /etc/systemd/system/log-central-agent-restart.service \
    /etc/systemd/system/log-central-agent-restart.timer
systemctl daemon-reload

rm -rf /opt/log-central-agent /etc/log-central-agent /var/lib/log-central-agent
if id -u log-central-agent >/dev/null 2>&1; then
    userdel log-central-agent
fi

echo "==> log-central-agent removed"
