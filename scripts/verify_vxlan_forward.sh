#!/usr/bin/env bash
set -euo pipefail

LOG_A=/tmp/tapvx_a.log
LOG_B=/tmp/tapvx_b.log
rm -f "$LOG_A" "$LOG_B"

/tmp/tapvxlan-udp -tap tapvx_a -listen 127.0.0.1:47901 -peers 127.0.0.1:47902 >"$LOG_A" 2>&1 &
pid_a=$!
/tmp/tapvxlan-udp -tap tapvx_b -listen 127.0.0.1:47902 -peers 127.0.0.1:47901 >"$LOG_B" 2>&1 &
pid_b=$!

cleanup() {
    kill "$pid_a" "$pid_b" >/dev/null 2>&1 || true
    wait "$pid_a" "$pid_b" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 1
ip link set tapvx_a up
ip link set tapvx_b up

echo "==program-a-log=="
cat "$LOG_A"
echo "==program-b-log=="
cat "$LOG_B"
echo "==tap-links=="
ip -d link show tapvx_a
ip -d link show tapvx_b

python3 - <<'PY'
import socket
import time

src = "tapvx_a"
dst = "tapvx_b"
marker = b"tap-vxlan-forward-test"
frame = (
    b"\xff\xff\xff\xff\xff\xff" +
    b"\x02\x00\x00\x00\x00\x01" +
    b"\x88\xb5" +
    marker
)

rx = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.ntohs(0x0003))
rx.bind((dst, 0))
rx.settimeout(3)

tx = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
tx.bind((src, 0))

time.sleep(0.2)
tx.send(frame)

deadline = time.time() + 3
while time.time() < deadline:
    packet, addr = rx.recvfrom(65535)
    if marker in packet:
        print("forwarded frame received")
        print("received_len=%d" % len(packet))
        print("ifname=%s" % addr[0])
        raise SystemExit(0)

print("forwarded frame not received")
raise SystemExit(1)
PY

cleanup
trap - EXIT
sleep 1

echo "==after-stop=="
ip link show tapvx_a >/dev/null 2>&1 && { echo "tapvx_a still exists"; exit 1; }
ip link show tapvx_b >/dev/null 2>&1 && { echo "tapvx_b still exists"; exit 1; }
echo "tap devices removed"
