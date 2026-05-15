#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

CONF=/tmp/uvxlan-control-test.conf
cat >"$CONF" <<'EOF'
TUNNEL_NAME="uvxlan-test"
VNI="100"
TAP_IFACE="tapvx_ctl0"
BRIDGE_IFACE=""
VXLAN_PORT="47910"
LOCAL_LISTEN="127.0.0.1:47910"
PEERS="127.0.0.1:47911"
MTU="1280"
FRAME_SIZE="1600"
BINARY_PATH="/tmp/tapvxlan-control-test"
PID_FILE="/tmp/tapvxlan-control-test.pid"
LOG_FILE="/tmp/tapvxlan-control-test.log"
AUTO_BUILD="1"
GOPROXY_VALUE="https://goproxy.cn,direct"
EOF

cleanup() {
    VXLAN_TS_CONFIG="$CONF" ./userspace-vxlan-tailscale.sh stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

VXLAN_TS_CONFIG="$CONF" ./userspace-vxlan-tailscale.sh start
ip -d link show tapvx_ctl0
VXLAN_TS_CONFIG="$CONF" ./userspace-vxlan-tailscale.sh status
VXLAN_TS_CONFIG="$CONF" ./userspace-vxlan-tailscale.sh stop

if ip link show tapvx_ctl0 >/dev/null 2>&1; then
    echo "tapvx_ctl0 still exists"
    exit 1
fi

echo "control script start/stop verification passed"
