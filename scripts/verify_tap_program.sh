#!/usr/bin/env bash
set -euo pipefail

LOG=/tmp/tapvx_prog0.log
rm -f "$LOG"

/tmp/tapvxlan-udp -tap tapvx_prog0 -listen 127.0.0.1:47890 >"$LOG" 2>&1 &
pid=$!

cleanup() {
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 1

echo "==program-log=="
cat "$LOG"
echo "==tap-link=="
ip -d link show tapvx_prog0

cleanup
trap - EXIT
sleep 1

echo "==after-stop=="
ip link show tapvx_prog0 >/dev/null 2>&1 && {
    echo "tap still exists"
    exit 1
}
echo "tap removed"
