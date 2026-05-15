#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

CONF=/tmp/uvxlan-control-bridge-test.conf
PHY_A=vethvx_phy0
PHY_B=vethvx_peer0
BR=br-vx-test0
TAP=tapvx_brctl0

cleanup() {
    VXLAN_TS_CONFIG="$CONF" ./userspace-vxlan-tailscale.sh stop >/dev/null 2>&1 || true
    ip link delete "$PHY_A" >/dev/null 2>&1 || true
    ip link delete "$PHY_B" >/dev/null 2>&1 || true
    ip link delete "$BR" type bridge >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup
ip link add "$PHY_A" type veth peer name "$PHY_B"
ip link set "$PHY_A" up
ip link set "$PHY_B" up

cat >"$CONF" <<EOF
TUNNEL_NAME="uvxlan-bridge-test"
VNI="100"
TAP_IFACE="$TAP"
BRIDGE_IFACE="$BR"
MANAGE_BRIDGE="1"
PHYS_IFACES="$PHY_A"
DETACH_PHYS_ON_STOP="1"
REMOVE_MANAGED_BRIDGE_ON_STOP="1"
VXLAN_PORT="47920"
LOCAL_LISTEN="127.0.0.1:47920"
PEERS="127.0.0.1:47921"
MTU="1280"
FRAME_SIZE="1600"
BINARY_PATH="/tmp/tapvxlan-control-bridge-test"
PID_FILE="/tmp/tapvxlan-control-bridge-test.pid"
LOG_FILE="/tmp/tapvxlan-control-bridge-test.log"
AUTO_BUILD="1"
GOPROXY_VALUE="https://goproxy.cn,direct"
EOF

VXLAN_TS_CONFIG="$CONF" ./userspace-vxlan-tailscale.sh start

ip link show "$BR" >/dev/null
ip link show "$TAP" >/dev/null
ip -o link show "$PHY_A" | grep -q "master $BR"
ip -o link show "$TAP" | grep -q "master $BR"

echo "==bridge=="
ip -d link show "$BR"
echo "==members=="
ip -o link show "$PHY_A"
ip -o link show "$TAP"

VXLAN_TS_CONFIG="$CONF" ./userspace-vxlan-tailscale.sh stop

if ip link show "$TAP" >/dev/null 2>&1; then
    echo "$TAP still exists"
    exit 1
fi
if ip link show "$BR" >/dev/null 2>&1; then
    echo "$BR still exists"
    exit 1
fi

echo "bridge creation and member attach verification passed"
