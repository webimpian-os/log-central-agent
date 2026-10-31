#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
vector="${VECTOR:-vector}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

now="$(date -u '+%d/%b/%Y:%H:%M:%S +0000')"
old="$(date -u -d '-1 hour' '+%d/%b/%Y:%H:%M:%S +0000' 2>/dev/null || date -u -v-1H '+%d/%b/%Y:%H:%M:%S +0000')"

access() {
    local webapp="$1" ip="$2" status="$3" path="$4" time="$5"
    printf '104.23.160.48 - - [%s] "GET %s HTTP/2.0" %s 512 "-" "load-test" "%s" "https://%s.test"\n' \
        "$time" "$path" "$status" "$ip" "$webapp"
}

mkdir -p "$work"/home/{warmup,demoshop,bakery,quiet,stale}/logs/nginx "$work/data"

cat > "$work/test.yaml" <<EOF
data_dir: $work/data
sources:
  apache_error_logs:
    type: file
    include: ["$work/none/*"]
  nginx_error_logs:
    type: file
    include: ["$work/none/*"]
  access_logs:
    type: file
    include: ["$work/home/*/logs/nginx/*_access.log"]
    read_from: beginning
sinks:
  alerts:
    type: file
    inputs: [traffic_alerts]
    path: $work/alerts.json
    encoding:
      codec: json
EOF

cd "$root"
"$vector" --quiet --config config/pipeline.yaml --config "$work/test.yaml" --config tests/runtime.yaml \
    --graceful-shutdown-limit-secs 5 >"$work/vector.log" 2>&1 &
pid=$!
# The Lua timer ticks once on the first request; the rest then fall in one window.
access warmup 203.0.113.9 200 / "$now" > "$work/home/warmup/logs/nginx/warmup_access.log"
sleep 3
{
    for _ in $(seq 1 2000); do access demoshop 203.0.113.50 200 /wp-login.php "$now"; done
    for i in $(seq 1 1200); do access demoshop "198.51.100.$((i % 250))" 200 "/page-$i/" "$now"; done
} > "$work/home/demoshop/logs/nginx/demoshop_access.log"
{
    for _ in $(seq 1 8); do access bakery 203.0.113.9 502 / "$now"; done
    for _ in 1 2; do access bakery 203.0.113.9 200 /about/ "$now"; done
} > "$work/home/bakery/logs/nginx/bakery_access.log"
{
    for _ in $(seq 1 20); do access quiet 203.0.113.9 200 / "$now"; done
    for _ in 1 2; do access quiet 203.0.113.9 500 /broken/ "$now"; done
} > "$work/home/quiet/logs/nginx/quiet_access.log"
for _ in $(seq 1 4000); do access stale 203.0.113.9 200 / "$old"; done > "$work/home/stale/logs/nginx/stale_access.log"

for _ in $(seq 1 30); do
    read_bytes="$(cat "$work"/data/*/checkpoints.json 2>/dev/null | awk -F '"position":' '{ for (i = 2; i <= NF; i++) sum += $i } END { print sum + 0 }')" || read_bytes=0
    total_bytes="$(cat "$work"/home/*/logs/nginx/*_access.log | wc -c | tr -d ' ')"
    [ "${read_bytes:-0}" -ge "$total_bytes" ] && break
    sleep 1
done
kill -TERM "$pid"
wait "$pid" || true

fail() {
    echo "traffic: $1" >&2
    cat "$work/alerts.json" >&2 2>/dev/null || true
    exit 1
}

[ -f "$work/alerts.json" ] || fail "no alerts written"
grep -q '"message":"\[demo-shop.test\] 3200 requests in one minute, 62% from 203.0.113.50"' "$work/alerts.json" \
    || fail "missing the traffic spike"
grep -q '"message":"\[bakery.test\] 8 of 10 requests got a server error in one minute"' "$work/alerts.json" \
    || fail "missing the failing site"
! grep -q 'quiet\|stale' "$work/alerts.json" || fail "alerted on a quiet site or old traffic"
[ "$(wc -l < "$work/alerts.json")" -eq 2 ] || fail "expected exactly 2 alerts"

echo "traffic ... passed"
