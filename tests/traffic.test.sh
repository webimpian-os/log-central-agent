#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
vector="${VECTOR:-vector}"
work="$(mktemp -d)"
pid=""
trap '[ -z "$pid" ] || kill "$pid" 2>/dev/null; rm -rf "$work"' EXIT

now() { date -u '+%d/%b/%Y:%H:%M:%S +0000'; }
old="$(date -u -d '-1 hour' '+%d/%b/%Y:%H:%M:%S +0000' 2>/dev/null || date -u -v-1H '+%d/%b/%Y:%H:%M:%S +0000')"

access() {
    local webapp="$1" ip="$2" status="$3" path="$4" time="$5" method="${6:-GET}"
    printf '104.23.160.48 - - [%s] "%s %s HTTP/2.0" %s 512 "-" "load-test" "%s" "https://%s.test"\n' \
        "$time" "$method" "$path" "$status" "$ip" "$webapp"
}

repeat() {
    local count="$1"
    shift
    for _ in $(seq 1 "$count"); do access "$@"; done
}

fail() {
    echo "traffic: $1" >&2
    cat "$2" >&2 2>/dev/null || true
    exit 1
}

site_log() {
    mkdir -p "$1/$2/logs/nginx"
    echo "$1/$2/logs/nginx/$2_access.log"
}

run() {
    local dir="$1" writer="$2" pipeline="${3:-$root/config/pipeline.yaml}"
    mkdir -p "$dir/home" "$dir/data"
    cat > "$dir/test.yaml" <<EOF
data_dir: $dir/data
sources:
  apache_error_logs:
    type: file
    include: ["$dir/none/*"]
  nginx_error_logs:
    type: file
    include: ["$dir/none/*"]
  access_logs:
    type: file
    include: ["$dir/home/*/logs/nginx/*_access.log"]
    read_from: beginning
sinks:
  alerts:
    type: file
    inputs: [traffic_alerts]
    path: $dir/alerts.json
    encoding:
      codec: json
EOF
    (cd "$root" && exec "$vector" --quiet --config "$pipeline" --config "$dir/test.yaml" --config tests/runtime.yaml \
        --graceful-shutdown-limit-secs 5 >"$dir/vector.log" 2>&1) &
    pid=$!
    local read_bytes total_bytes
    "$writer" "$dir/home"
    for _ in $(seq 1 30); do
        read_bytes="$(cat "$dir"/data/*/checkpoints.json 2>/dev/null | awk -F '"position":' '{ for (i = 2; i <= NF; i++) sum += $i } END { print sum + 0 }')" || read_bytes=0
        total_bytes="$(cat "$dir"/home/*/logs/nginx/*_access.log | wc -c | tr -d ' ')"
        [ "${read_bytes:-0}" -ge "$total_bytes" ] && break
        sleep 1
    done
    sleep 2
    kill -TERM "$pid"
    wait "$pid" || true
    pid=""
    touch "$dir/alerts.json"
}

one_minute() {
    local home="$1" time
    # The Lua timer ticks once on the first request; the rest then fall in one window.
    access warmup 203.0.113.9 200 / "$(now)" > "$(site_log "$home" warmup)"
    sleep 3
    time="$(now)"
    {
        repeat 2000 demoshop 203.0.113.50 200 /wp-login.php "$time"
        for i in $(seq 1 1200); do access demoshop "198.51.100.$((i % 250))" 200 "/page-$i/" "$time"; done
    } > "$(site_log "$home" demoshop)"
    { repeat 8 bakery 203.0.113.9 502 / "$time"; repeat 2 bakery 203.0.113.9 200 /about/ "$time"; } > "$(site_log "$home" bakery)"
    { repeat 20 quiet 203.0.113.9 200 / "$time"; repeat 2 quiet 203.0.113.9 500 /broken/ "$time"; } > "$(site_log "$home" quiet)"
    { repeat 8 scanned 203.0.113.70 500 /wp-json/batch/v1 "$time" POST; repeat 2 scanned 203.0.113.9 200 / "$time"; } > "$(site_log "$home" scanned)"
    repeat 100 login 203.0.113.66 200 /wp-login.php "$time" POST > "$(site_log "$home" login)"
    repeat 4000 stale 203.0.113.9 200 / "$old" > "$(site_log "$home" stale)"
}

steady_then_burst() {
    local home="$1" log
    log="$(site_log "$home" steady)"
    for _ in $(seq 1 8); do
        repeat 10 steady 198.51.100.7 200 / "$(now)" >> "$log"
        sleep 1
    done
    repeat 1500 steady 203.0.113.50 200 / "$(now)" >> "$log"
}

run "$work/minute" one_minute
alerts="$work/minute/alerts.json"
grep -q '"message":"\[demo-shop.test\] 3200 requests in one minute, 62% from 203.0.113.50"' "$alerts" \
    || fail "missing the traffic spike" "$alerts"
grep -q '"message":"\[bakery.test\] 8 of 10 requests got a server error in one minute, mostly on /"' "$alerts" \
    || fail "missing the failing site" "$alerts"
grep -q '"message":"\[login.test\] 100 login attempts in one minute from 203.0.113.66"' "$alerts" \
    || fail "missing the brute force attack" "$alerts"
! grep -q 'quiet\|stale\|warmup' "$alerts" || fail "alerted on a quiet site or old traffic" "$alerts"
! grep -q 'scanned' "$alerts" || fail "a scanner on the REST batch endpoint looked like a failing site" "$alerts"
[ "$(wc -l < "$alerts")" -eq 3 ] || fail "expected exactly 3 alerts" "$alerts"

# Minutes become seconds so a site's usual traffic is learnt quickly.
sed -e 's/WARMUP_MINUTES = 30/WARMUP_MINUTES = 3/' -e 's/interval_seconds: 60/interval_seconds: 1/' \
    "$root/config/pipeline.yaml" > "$work/fast-pipeline.yaml"
run "$work/usual" steady_then_burst "$work/fast-pipeline.yaml"
alerts="$work/usual/alerts.json"
grep -qE '"message":"\[steady.test\] [0-9]+ requests in one minute \(usually about [0-9]+\)' "$alerts" \
    || fail "missing the spike against usual traffic" "$alerts"

echo "traffic ... passed"
