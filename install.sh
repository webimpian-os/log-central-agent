#!/usr/bin/env bash
set -euo pipefail

AGENT_VERSION="${AGENT_VERSION:-v1.0.0}"
REPO="webimpian-os/log-central-agent"
VECTOR_VERSION="0.61.0"

NAME="log-central-agent"
PREFIX="/opt/$NAME"
ETC_DIR="/etc/$NAME"
SECRETS_DIR="$ETC_DIR/secrets"
STATE_DIR="/var/lib/$NAME"
SERVICE_USER="$NAME"
SERVICE="$NAME.service"
TIMER="$NAME-sites.timer"
DROPIN_DIR="/etc/systemd/system/$SERVICE.d"

say() { printf '==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

url=""
app=""
token=""
token_stdin=0
panel=""

while [ $# -gt 0 ]; do
    case "$1" in
        --url) [ $# -ge 2 ] || fail "--url needs a value"; url="$2"; shift 2 ;;
        --app) [ $# -ge 2 ] || fail "--app needs a value"; app="$2"; shift 2 ;;
        --panel) [ $# -ge 2 ] || fail "--panel needs a value"; panel="$2"; shift 2 ;;
        --token-stdin) token_stdin=1; shift ;;
        *) fail "unknown option: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || fail "run as root (sudo)"
command -v systemctl >/dev/null || fail "systemd is required"
for cmd in curl tar sha256sum install runuser useradd journalctl; do
    command -v "$cmd" >/dev/null || fail "$cmd is required"
done

is_panel() {
    case "$1" in
        runcloud) [ -d /opt/RunCloud ] && [ -d /etc/nginx-rc ] ;;
        plesk) [ -f /usr/local/psa/version ] && [ -d /var/www/vhosts/system ] ;;
        *) return 1 ;;
    esac
}

# Keep in sync with config/panels/*.yaml.
site_logs() {
    case "$1" in
        runcloud)
            compgen -G '/home/*/logs/apache2/*_error.log' || true
            compgen -G '/home/*/logs/nginx/*_error.log' || true
            ;;
        plesk)
            compgen -G '/var/www/vhosts/system/*/logs/error_log' || true
            compgen -G '/var/www/vhosts/system/*/logs/proxy_error_log' || true
            ;;
    esac
}

installed_panel="$(cat "$ETC_DIR/panel" 2>/dev/null || true)"
[ -n "$panel" ] || panel="$installed_panel"
if [ -z "$panel" ]; then
    for candidate in runcloud plesk; do
        if is_panel "$candidate"; then
            [ -z "$panel" ] || fail "this server looks like both RunCloud and Plesk, pass --panel. Nothing was changed"
            panel="$candidate"
        fi
    done
    [ -n "$panel" ] || fail "no supported panel found (RunCloud or Plesk). Nothing was changed"
fi
case "$panel" in
    runcloud | plesk) ;;
    *) fail "unknown panel: $panel (use runcloud or plesk)" ;;
esac
is_panel "$panel" || fail "this server doesn't look like a $panel server. Nothing was changed"
[ -z "$installed_panel" ] || [ "$installed_panel" = "$panel" ] \
    || fail "already installed for $installed_panel, run uninstall.sh first. Nothing was changed"

case "$panel" in
    runcloud) panel_name="RunCloud" ;;
    plesk) panel_name="Plesk $(awk '{ print $1; exit }' /usr/local/psa/version)" ;;
esac
log_count="$(site_logs "$panel" | wc -l | tr -d ' ')"
say "Detected $panel_name with $log_count site error logs"

case "$(uname -m)" in
    x86_64) arch="x86_64"; vector_sha256="e1609b8a55ef1c1fc4fd88633e2bc6366e9a4022f6f1ae846cadd27af5237621" ;;
    aarch64 | arm64) arch="aarch64"; vector_sha256="12d7e91db2e447003558c955c4f510b17ed1d77340757f3e591e5222e464675c" ;;
    *) fail "unsupported CPU architecture: $(uname -m)" ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

saved() {
    if [ -f "$SECRETS_DIR/$1" ]; then cat "$SECRETS_DIR/$1"; fi
}

ask() {
    local label="$1" var="$2" hidden="${3:-}" value=""
    { true </dev/tty; } 2>/dev/null || fail "$label is required: pass it as an option"
    if [ -n "$hidden" ]; then
        read -r -s -p "$label: " value </dev/tty
        echo >/dev/tty
    else
        read -r -p "$label: " value </dev/tty
    fi
    printf -v "$var" '%s' "$value"
}

[ -n "$url" ] || url="$(saved url)"
[ -n "$app" ] || app="$(saved app)"
if [ "$token_stdin" -eq 1 ]; then
    IFS= read -r token || true
else
    token="$(saved token)"
fi

[ -n "$url" ] || ask "Log Central URL (e.g. https://logs.example.com)" url
[ -n "$app" ] || ask "Log Central app slug" app
[ -n "$token" ] || ask "Log Central app token (input hidden)" token hidden

url="${url%/}"
[[ "$url" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]] || fail "invalid Log Central URL: $url"
[[ "$app" =~ ^[A-Za-z0-9_-]+$ ]] || fail "invalid app slug: $app"
[[ "$token" =~ ^[A-Za-z0-9._-]+$ ]] || fail "missing or malformed app token"

check_token() {
    # No environment field: rejected after the token check, so nothing is stored.
    local probe response status body
    probe='[{"timestamp":"2000-01-01 00:00:00.000","fingerprint":"00000000000000000000000000000000","app":"'"$app"'"}]'
    response="$(printf 'Authorization: Bearer %s\n' "$token" \
        | curl -sS -m 20 -H @- -H 'Content-Type: application/json' -H 'Accept: application/json' \
            --data "$probe" -w '\n%{http_code}' "$url/api/errors")" || fail "cannot reach $url"
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"
    case "$status" in
        401) fail "Log Central rejected the app token" ;;
        403) fail "the Log Central app behind this token is disabled" ;;
        400 | 422 | 202) ;;
        *) fail "unexpected response from $url/api/errors (HTTP $status): $body" ;;
    esac
    [[ "$body" != *"does not match the authenticated app"* ]] || fail "the token belongs to a different app than '$app'"
}

preflight() {
    local path free_mb available_mb load cpus
    for path in /opt /var/lib "$work"; do
        free_mb="$(df -Pm "$path" | awk 'NR == 2 { print $4 }')"
        [ "$free_mb" -ge 1024 ] || fail "only ${free_mb} MB free for $path, need at least 1 GB"
    done
    available_mb="$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)"
    [ "$available_mb" -ge 512 ] || fail "only ${available_mb} MB of memory available, need at least 512 MB"
    cpus="$(nproc)"
    load="$(cut -d ' ' -f 1 /proc/loadavg)"
    awk -v current="$load" -v cpus="$cpus" 'BEGIN { exit !(current < cpus) }' \
        || fail "the server is busy (load $load on $cpus CPUs), try again later"
}

say "Checking disk, memory and load"
preflight

say "Checking the app token against $url"
check_token

if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/config/pipeline.yaml" ]; then
    src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    say "Downloading $NAME $AGENT_VERSION"
    mkdir -p "$work/src"
    curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/tags/$AGENT_VERSION" | tar -xz -C "$work/src" --strip-components=1
    src="$work/src"
fi

install -d -m 0755 "$PREFIX/bin" "$PREFIX/config"

if ! "$PREFIX/bin/vector" --version 2>/dev/null | grep -q "^vector $VECTOR_VERSION "; then
    say "Installing Vector $VECTOR_VERSION"
    archive="vector-$VECTOR_VERSION-$arch-unknown-linux-musl.tar.gz"
    curl -fsSL -o "$work/$archive" "https://github.com/vectordotdev/vector/releases/download/v$VECTOR_VERSION/$archive"
    echo "$vector_sha256  $work/$archive" | sha256sum -c --quiet - || fail "the Vector download failed its checksum"
    mkdir -p "$work/vector"
    tar -xzf "$work/$archive" -C "$work/vector"
    binary="$(find "$work/vector" -type f -name vector -path '*/bin/*' | head -n 1)"
    [ -n "$binary" ] || fail "no vector binary inside $archive"
    install -m 0755 "$binary" "$PREFIX/bin/vector.new"
    mv -f "$PREFIX/bin/vector.new" "$PREFIX/bin/vector"
fi

id -u "$SERVICE_USER" >/dev/null 2>&1 \
    || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER"

install -m 0644 "$src/config/pipeline.yaml" "$src/config/runtime.yaml" "$PREFIX/config/"
install -m 0644 "$src/config/panels/$panel.yaml" "$PREFIX/config/panel.yaml"
install -m 0755 "$src/bin/refresh-sites" "$PREFIX/bin/refresh-sites"
install -m 0644 "$src/systemd/$NAME.service" "$src/systemd/$NAME-sites.service" "$src/systemd/$NAME-sites.timer" \
    /etc/systemd/system/
if [ -f "$src/systemd/$panel.conf" ]; then
    install -d -m 0755 "$DROPIN_DIR"
    install -m 0644 "$src/systemd/$panel.conf" "$DROPIN_DIR/panel.conf"
else
    rm -f "$DROPIN_DIR/panel.conf"
fi
echo "$AGENT_VERSION" > "$PREFIX/VERSION"

install -d -m 0755 "$ETC_DIR"
echo "$panel" > "$ETC_DIR/panel"
install -d -m 0700 -o "$SERVICE_USER" -g "$SERVICE_USER" "$SECRETS_DIR"
write_secret() {
    local tmp
    tmp="$(mktemp "$SECRETS_DIR/.$1.XXXXXX")"
    printf '%s' "$2" > "$tmp"
    chown "$SERVICE_USER:$SERVICE_USER" "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$SECRETS_DIR/$1"
}
write_secret url "$url"
write_secret app "$app"
write_secret token "$token"

install -d -m 0755 -o "$SERVICE_USER" -g "$SERVICE_USER" "$STATE_DIR"
"$PREFIX/bin/refresh-sites"

runuser -u "$SERVICE_USER" -- "$PREFIX/bin/vector" validate --no-environment --resolve-secrets \
    "$PREFIX/config/pipeline.yaml" "$PREFIX/config/panel.yaml" "$PREFIX/config/runtime.yaml" >/dev/null \
    || fail "Vector rejected the configuration"

units=("$SERVICE")
if [ "$panel" = "runcloud" ]; then
    units+=("$TIMER")
fi

systemctl daemon-reload
systemctl enable --quiet "${units[@]}"
systemctl restart "${units[@]}"

stop_and_fail() {
    systemctl disable --now --quiet "${units[@]}" || true
    fail "$1"
}

sleep 3
if ! systemctl is-active --quiet "$SERVICE"; then
    journalctl -u "$SERVICE" -n 20 --no-pager >&2 || true
    fail "$SERVICE did not start"
fi

enforced_limits() {
    local memory cpu pid nice
    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        memory="$(cat "/sys/fs/cgroup/system.slice/$SERVICE/memory.max" 2>/dev/null)"
        cpu="$(cut -d ' ' -f 1 "/sys/fs/cgroup/system.slice/$SERVICE/cpu.max" 2>/dev/null)"
    else
        memory="$(cat "/sys/fs/cgroup/memory/system.slice/$SERVICE/memory.limit_in_bytes" 2>/dev/null)"
        cpu="$(cat "/sys/fs/cgroup/cpu,cpuacct/system.slice/$SERVICE/cpu.cfs_quota_us" 2>/dev/null)"
    fi
    pid="$(systemctl show -p MainPID --value "$SERVICE")"
    nice="$(ps -o ni= -p "$pid" 2>/dev/null | tr -d ' ')"
    echo "    memory limit: ${memory:-?} bytes, CPU quota: ${cpu:-?}/100000, nice: ${nice:-?}"
    [ "$memory" = "268435456" ] && [ "$cpu" = "50000" ] && [ "$nice" = "19" ]
}

enforced_limits || stop_and_fail "the kernel is not enforcing the CPU/memory limits, so the agent was stopped"

# Vector silently skips folders it can't read.
sees_logs() {
    local invocation output
    invocation="$(systemctl show -p InvocationID --value "$SERVICE")"
    for _ in $(seq 1 15); do
        output="$(journalctl --no-pager -o cat "_SYSTEMD_INVOCATION_ID=$invocation" 2>/dev/null || true)"
        if grep -qE "Found new file to watch|Resuming to watch file" <<<"$output"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

if [ "$log_count" -gt 0 ]; then
    sees_logs || stop_and_fail "the agent can't see the site logs, so it was stopped"
    say "$NAME $AGENT_VERSION is running on $panel_name, following $log_count site error logs"
else
    say "$NAME $AGENT_VERSION is running on $panel_name. No site has logged anything yet"
fi
echo "    Follow it with: journalctl -u $SERVICE -f"
