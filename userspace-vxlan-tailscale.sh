#!/usr/bin/env bash
set -u

VERSION="0.1.0-userspace"

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

CONFIG_FILE="${VXLAN_TS_CONFIG:-/etc/userspace-vxlan-tailscale.conf}"

TUNNEL_NAME="uvxlan0"
VNI="100"
TAP_IFACE="tapvx100"
BRIDGE_IFACE=""
MANAGE_BRIDGE="0"
PHYS_IFACES=""
DETACH_PHYS_ON_STOP="0"
REMOVE_MANAGED_BRIDGE_ON_STOP="0"
VXLAN_PORT="4789"
LOCAL_LISTEN="0.0.0.0:${VXLAN_PORT}"
PEERS=""
MTU="1280"
FRAME_SIZE="1600"
BINARY_PATH="/usr/local/bin/tapvxlan-udp"
PID_FILE="/var/run/userspace-vxlan-tailscale.pid"
LOG_FILE="/var/log/userspace-vxlan-tailscale.log"
DOWNLOAD_BINARY="0"
GITHUB_REPO="Frankzhang854/userspace-vxlan"
RELEASE_VERSION="latest"
DOWNLOAD_BASE_URL=""
VERIFY_DOWNLOAD="1"
AUTO_BUILD="1"
GOPROXY_VALUE="${GOPROXY:-https://goproxy.cn,direct}"

RED=''
GREEN=''
YELLOW=''
BLUE=''
NC=''
if [ -t 1 ]; then
    RED="$(printf '\033[31m')"
    GREEN="$(printf '\033[32m')"
    YELLOW="$(printf '\033[33m')"
    BLUE="$(printf '\033[34m')"
    NC="$(printf '\033[0m')"
fi

info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
ok() { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
err() { printf '%s[ERR ]%s %s\n' "$RED" "$NC" "$*" >&2; }

need_root() {
    if [ "$(id -u)" != "0" ]; then
        err "Please run as root."
        exit 1
    fi
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
    fi
    LOCAL_LISTEN="${LOCAL_LISTEN:-0.0.0.0:${VXLAN_PORT}}"
    MANAGE_BRIDGE="${MANAGE_BRIDGE:-0}"
    PHYS_IFACES="${PHYS_IFACES:-}"
    DETACH_PHYS_ON_STOP="${DETACH_PHYS_ON_STOP:-0}"
    REMOVE_MANAGED_BRIDGE_ON_STOP="${REMOVE_MANAGED_BRIDGE_ON_STOP:-0}"
    DOWNLOAD_BINARY="${DOWNLOAD_BINARY:-0}"
    GITHUB_REPO="${GITHUB_REPO:-}"
    RELEASE_VERSION="${RELEASE_VERSION:-latest}"
    DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL:-}"
    VERIFY_DOWNLOAD="${VERIFY_DOWNLOAD:-1}"
}

write_default_config() {
    need_root
    if [ -f "$CONFIG_FILE" ]; then
        warn "Config already exists: $CONFIG_FILE"
        return 0
    fi
    cat >"$CONFIG_FILE" <<EOF
# User-space VXLAN over Tailscale/underlay config
# This backend does not require the kernel vxlan module.

TUNNEL_NAME="uvxlan0"
VNI="100"
TAP_IFACE="tapvx100"

# Optional. Set to br-lan or another Linux bridge to join the remote/local LAN.
# Leave empty for standalone testing.
BRIDGE_IFACE=""

# Optional bridge management.
# MANAGE_BRIDGE=1 lets this script create BRIDGE_IFACE when it does not exist.
# PHYS_IFACES is a comma/space-separated list of physical ports to add to it.
# Be careful: moving a management/uplink port into a bridge can interrupt access.
MANAGE_BRIDGE="0"
PHYS_IFACES=""

# Test cleanup options. Keep disabled on real devices unless you know the bridge
# is dedicated to this tunnel.
DETACH_PHYS_ON_STOP="0"
REMOVE_MANAGED_BRIDGE_ON_STOP="0"

VXLAN_PORT="4789"
LOCAL_LISTEN="0.0.0.0:4789"

# Comma-separated peer underlay addresses.
# For Tailscale, use peer Tailscale IPs or MagicDNS names, for example:
# PEERS="100.64.0.2:4789,peer-b.tailnet.ts.net:4789"
PEERS=""

MTU="1280"
FRAME_SIZE="1600"

BINARY_PATH="/usr/local/bin/tapvxlan-udp"
PID_FILE="/var/run/userspace-vxlan-tailscale.pid"
LOG_FILE="/var/log/userspace-vxlan-tailscale.log"

# Download a prebuilt binary from GitHub Releases when BINARY_PATH is missing.
# Set DOWNLOAD_BINARY=1 to install from GitHub Releases.
DOWNLOAD_BINARY="0"
GITHUB_REPO="Frankzhang854/userspace-vxlan"
RELEASE_VERSION="latest"
DOWNLOAD_BASE_URL=""
VERIFY_DOWNLOAD="1"

# Build cmd/tapvxlan-udp from this project if BINARY_PATH is missing.
AUTO_BUILD="1"
GOPROXY_VALUE="https://goproxy.cn,direct"
EOF
    ok "Created config: $CONFIG_FILE"
}

show_config() {
    load_config
    cat <<EOF
Version:       $VERSION
Config:        $CONFIG_FILE
Project dir:   $PROJECT_DIR
Tunnel name:   $TUNNEL_NAME
VNI:           $VNI
TAP iface:     $TAP_IFACE
Bridge iface:  ${BRIDGE_IFACE:-<none>}
Manage bridge: $MANAGE_BRIDGE
Phys ifaces:   ${PHYS_IFACES:-<none>}
Listen:        $LOCAL_LISTEN
Peers:         ${PEERS:-<empty>}
MTU:           $MTU
Frame size:    $FRAME_SIZE
Binary:        $BINARY_PATH
PID file:      $PID_FILE
Log file:      $LOG_FILE
Download bin:  $DOWNLOAD_BINARY
GitHub repo:   ${GITHUB_REPO:-<none>}
Release:       $RELEASE_VERSION
Auto build:    $AUTO_BUILD
EOF
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

iface_list() {
    printf '%s\n' "$1" | tr ',' ' '
}

detect_binary_asset() {
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)
            echo "tapvxlan-udp-linux-amd64"
            ;;
        i386|i486|i586|i686)
            echo "tapvxlan-udp-linux-386"
            ;;
        aarch64|arm64)
            echo "tapvxlan-udp-linux-arm64"
            ;;
        armv7l|armv7*)
            echo "tapvxlan-udp-linux-armv7"
            ;;
        armv6l|armv6*)
            echo "tapvxlan-udp-linux-armv6"
            ;;
        mips64*)
            err "mips64 is not included in the current release matrix"
            return 1
            ;;
        mipsel|mipsle)
            echo "tapvxlan-udp-linux-mipsle"
            ;;
        mips)
            echo "tapvxlan-udp-linux-mips"
            ;;
        riscv64)
            echo "tapvxlan-udp-linux-riscv64"
            ;;
        *)
            err "Unsupported architecture: $arch"
            return 1
            ;;
    esac
}

download_file() {
    url="$1"
    dest="$2"
    if command_exists curl; then
        curl -fL "$url" -o "$dest"
    elif command_exists wget; then
        wget -O "$dest" "$url"
    else
        err "curl or wget is required to download release binaries"
        return 1
    fi
}

release_base_url() {
    if [ -n "$DOWNLOAD_BASE_URL" ]; then
        printf '%s\n' "${DOWNLOAD_BASE_URL%/}"
        return 0
    fi
    if [ -z "$GITHUB_REPO" ]; then
        err "GITHUB_REPO is empty. Set it to owner/repo or set DOWNLOAD_BASE_URL."
        return 1
    fi
    if [ "$RELEASE_VERSION" = "latest" ]; then
        printf 'https://github.com/%s/releases/latest/download\n' "$GITHUB_REPO"
    else
        printf 'https://github.com/%s/releases/download/%s\n' "$GITHUB_REPO" "$RELEASE_VERSION"
    fi
}

download_binary() {
    asset="$(detect_binary_asset)" || return 1
    base_url="$(release_base_url)" || return 1
    tmp_dir="$(mktemp -d)"
    tmp_bin="$tmp_dir/$asset"
    tmp_checksums="$tmp_dir/checksums.txt"

    info "Downloading $asset from $base_url"
    download_file "$base_url/$asset" "$tmp_bin" || {
        rm -rf "$tmp_dir"
        return 1
    }

    if [ "$VERIFY_DOWNLOAD" = "1" ]; then
        if command_exists sha256sum; then
            if download_file "$base_url/checksums.txt" "$tmp_checksums"; then
                (
                    cd "$tmp_dir" &&
                    grep "  $asset\$" checksums.txt > checksums.one &&
                    sha256sum -c checksums.one
                ) || {
                    rm -rf "$tmp_dir"
                    err "Checksum verification failed for $asset"
                    return 1
                }
                ok "Checksum verified"
            else
                rm -rf "$tmp_dir"
                err "Failed to download checksums.txt"
                return 1
            fi
        else
            warn "sha256sum not found; skipping checksum verification"
        fi
    fi

    mkdir -p "$(dirname "$BINARY_PATH")"
    cp "$tmp_bin" "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
    rm -rf "$tmp_dir"
    ok "Installed binary: $BINARY_PATH"
}

check_tailscale() {
    if ! command_exists tailscale; then
        warn "tailscale command not found. This is OK if another underlay provides peer reachability."
        return 0
    fi
    if tailscale ip -4 >/dev/null 2>&1; then
        info "Tailscale IPv4: $(tailscale ip -4 2>/dev/null | head -n 1)"
    else
        warn "tailscale exists but no IPv4 was returned."
    fi
}

check_tap_support() {
    if [ ! -c /dev/net/tun ]; then
        err "/dev/net/tun does not exist. TAP cannot be created."
        return 1
    fi
    ok "/dev/net/tun exists"
}

check_env() {
    load_config
    check_tap_support || return 1
    command_exists ip || { err "ip command not found"; return 1; }
    check_tailscale
    if [ -n "$BRIDGE_IFACE" ]; then
        if ip link show "$BRIDGE_IFACE" >/dev/null 2>&1; then
            ok "Bridge exists: $BRIDGE_IFACE"
        elif [ "$MANAGE_BRIDGE" = "1" ]; then
            warn "Bridge does not exist yet and will be created: $BRIDGE_IFACE"
        else
            err "Bridge not found: $BRIDGE_IFACE"
            return 1
        fi
        for iface in $(iface_list "$PHYS_IFACES"); do
            if ip link show "$iface" >/dev/null 2>&1; then
                ok "Physical/member iface exists: $iface"
                if ip addr show dev "$iface" | grep -Eq 'inet |inet6 '; then
                    warn "$iface has IP addresses. Adding it to a bridge without IP migration can interrupt network access."
                fi
            else
                err "Physical/member iface not found: $iface"
                return 1
            fi
        done
    else
        warn "BRIDGE_IFACE is empty. TAP will not be attached to a LAN bridge."
    fi
    if [ -z "$PEERS" ]; then
        warn "PEERS is empty. The program can listen, but cannot flood frames to remote nodes."
    fi
}

build_binary() {
    load_config
    if [ -x "$BINARY_PATH" ]; then
        ok "Binary already exists: $BINARY_PATH"
        return 0
    fi
    if [ "$DOWNLOAD_BINARY" = "1" ]; then
        if download_binary; then
            return 0
        fi
        if [ "$AUTO_BUILD" != "1" ]; then
            return 1
        fi
        warn "Download failed; falling back to local build"
    fi
    if [ "$AUTO_BUILD" != "1" ]; then
        err "Binary missing and AUTO_BUILD is disabled: $BINARY_PATH"
        return 1
    fi
    if ! command_exists go; then
        err "go command not found. Install Go or place tapvxlan-udp at $BINARY_PATH."
        return 1
    fi
    if [ ! -d "$PROJECT_DIR/cmd/tapvxlan-udp" ]; then
        err "Project source not found: $PROJECT_DIR/cmd/tapvxlan-udp"
        return 1
    fi
    info "Building tapvxlan-udp..."
    mkdir -p "$(dirname "$BINARY_PATH")"
    (
        cd "$PROJECT_DIR" &&
        GOPROXY="$GOPROXY_VALUE" go build -o "$BINARY_PATH" ./cmd/tapvxlan-udp
    ) || return 1
    chmod +x "$BINARY_PATH"
    ok "Built binary: $BINARY_PATH"
}

is_running() {
    [ -f "$PID_FILE" ] || return 1
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" >/dev/null 2>&1
}

create_bridge_if_needed() {
    [ -n "$BRIDGE_IFACE" ] || return 0
    if ip link show "$BRIDGE_IFACE" >/dev/null 2>&1; then
        return 0
    fi
    if [ "$MANAGE_BRIDGE" != "1" ]; then
        err "Bridge not found and MANAGE_BRIDGE is not enabled: $BRIDGE_IFACE"
        return 1
    fi

    info "Creating bridge: $BRIDGE_IFACE"
    if ip link add name "$BRIDGE_IFACE" type bridge >/dev/null 2>&1; then
        :
    elif command_exists brctl && brctl addbr "$BRIDGE_IFACE" >/dev/null 2>&1; then
        :
    else
        err "Failed to create bridge: $BRIDGE_IFACE"
        return 1
    fi

    ip link set dev "$BRIDGE_IFACE" type bridge stp_state 0 forward_delay 0 >/dev/null 2>&1 || true
    ip link set dev "$BRIDGE_IFACE" up >/dev/null 2>&1 || {
        err "Failed to bring bridge up: $BRIDGE_IFACE"
        return 1
    }
    ok "Created bridge: $BRIDGE_IFACE"
}

add_iface_to_bridge() {
    member="$1"
    bridge="$2"
    [ -n "$member" ] && [ -n "$bridge" ] || return 0
    if ! ip link show "$member" >/dev/null 2>&1; then
        err "Interface not found: $member"
        return 1
    fi
    ip link set dev "$member" up >/dev/null 2>&1 || true
    if command_exists brctl; then
        brctl addif "$bridge" "$member" 2>/dev/null || true
    else
        ip link set dev "$member" master "$bridge" 2>/dev/null || true
    fi
    if ip -o link show "$member" | grep -q "master $bridge"; then
        ok "Attached $member to $bridge"
    else
        warn "Could not confirm $member is attached to $bridge"
    fi
}

prepare_bridge() {
    [ -n "$BRIDGE_IFACE" ] || return 0
    create_bridge_if_needed || return 1
    for iface in $(iface_list "$PHYS_IFACES"); do
        add_iface_to_bridge "$iface" "$BRIDGE_IFACE" || return 1
    done
    ip link set dev "$BRIDGE_IFACE" up >/dev/null 2>&1 || true
}

attach_bridge() {
    [ -n "$BRIDGE_IFACE" ] || return 0
    prepare_bridge || return 1
    add_iface_to_bridge "$TAP_IFACE" "$BRIDGE_IFACE"
}

detach_bridge() {
    [ -n "$BRIDGE_IFACE" ] || return 0
    ip link set dev "$TAP_IFACE" nomaster >/dev/null 2>&1 || true
    if [ "$DETACH_PHYS_ON_STOP" = "1" ]; then
        for iface in $(iface_list "$PHYS_IFACES"); do
            ip link set dev "$iface" nomaster >/dev/null 2>&1 || true
        done
    fi
    if [ "$REMOVE_MANAGED_BRIDGE_ON_STOP" = "1" ] && [ "$MANAGE_BRIDGE" = "1" ]; then
        ip link delete "$BRIDGE_IFACE" type bridge >/dev/null 2>&1 || true
    fi
}

start_tunnel() {
    need_root
    load_config
    check_env || return 1
    build_binary || return 1

    if is_running; then
        ok "Already running, pid=$(cat "$PID_FILE")"
        return 0
    fi

    mkdir -p "$(dirname "$PID_FILE")" "$(dirname "$LOG_FILE")"
    : >"$LOG_FILE"

    info "Starting user-space VXLAN..."
    "$BINARY_PATH" \
        -tap "$TAP_IFACE" \
        -vni "$VNI" \
        -listen "$LOCAL_LISTEN" \
        -peers "$PEERS" \
        -frame-size "$FRAME_SIZE" \
        >>"$LOG_FILE" 2>&1 &
    pid="$!"
    echo "$pid" >"$PID_FILE"

    sleep 1
    if ! kill -0 "$pid" >/dev/null 2>&1; then
        err "Process exited during startup. Log:"
        tail -n 50 "$LOG_FILE" >&2
        rm -f "$PID_FILE"
        return 1
    fi

    ip link set dev "$TAP_IFACE" mtu "$MTU" >/dev/null 2>&1 || warn "Failed to set MTU on $TAP_IFACE"
    ip link set dev "$TAP_IFACE" up >/dev/null 2>&1 || warn "Failed to set $TAP_IFACE up"
    attach_bridge || return 1

    ok "Started, pid=$pid"
}

stop_tunnel() {
    need_root
    load_config
    detach_bridge
    if is_running; then
        pid="$(cat "$PID_FILE")"
        info "Stopping pid=$pid..."
        kill "$pid" >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5; do
            kill -0 "$pid" >/dev/null 2>&1 || break
            sleep 1
        done
        kill -9 "$pid" >/dev/null 2>&1 || true
        ok "Stopped"
    else
        warn "Not running"
    fi
    rm -f "$PID_FILE"
    ip link delete "$TAP_IFACE" >/dev/null 2>&1 || true
}

status_tunnel() {
    load_config
    show_config
    echo
    if is_running; then
        ok "Runtime: running, pid=$(cat "$PID_FILE")"
    else
        warn "Runtime: stopped"
    fi
    if ip link show "$TAP_IFACE" >/dev/null 2>&1; then
        echo
        ip -d link show "$TAP_IFACE"
    fi
}

restart_tunnel() {
    stop_tunnel || true
    start_tunnel
}

show_logs() {
    load_config
    if [ -f "$LOG_FILE" ]; then
        tail -n 120 "$LOG_FILE"
    else
        warn "No log file: $LOG_FILE"
    fi
}

edit_config_hint() {
    load_config
    echo "Config file: $CONFIG_FILE"
    echo
    echo "Common fields to edit:"
    echo "  VNI=\"$VNI\""
    echo "  TAP_IFACE=\"$TAP_IFACE\""
    echo "  BRIDGE_IFACE=\"br-lan\""
    echo "  MANAGE_BRIDGE=\"1\""
    echo "  PHYS_IFACES=\"eth0\""
    echo "  LOCAL_LISTEN=\"0.0.0.0:${VXLAN_PORT}\""
    echo "  PEERS=\"peer-tailscale-ip:${VXLAN_PORT}\""
    echo "  DOWNLOAD_BINARY=\"1\""
    echo "  GITHUB_REPO=\"Frankzhang854/userspace-vxlan\""
    echo "  RELEASE_VERSION=\"v0.1.0\""
}

menu() {
    while true; do
        echo
        echo "User-space VXLAN over Tailscale control ($VERSION)"
        echo "1) Init default config"
        echo "2) Show config/status"
        echo "3) Check environment"
        echo "4) Build/download/install Go binary"
        echo "5) Start tunnel"
        echo "6) Stop tunnel"
        echo "7) Restart tunnel"
        echo "8) Show logs"
        echo "9) Config edit hint"
        echo "0) Exit"
        printf "Select: "
        read -r choice
        case "$choice" in
            1) write_default_config ;;
            2) status_tunnel ;;
            3) check_env ;;
            4) need_root; build_binary ;;
            5) start_tunnel ;;
            6) stop_tunnel ;;
            7) restart_tunnel ;;
            8) show_logs ;;
            9) edit_config_hint ;;
            0) exit 0 ;;
            *) warn "Unknown choice" ;;
        esac
    done
}

usage() {
    cat <<EOF
Usage: $0 COMMAND

Commands:
  init-config     Create default config at $CONFIG_FILE
  config          Show loaded config
  check           Check TAP/Tailscale/bridge environment
  build           Download or build/install tapvxlan-udp binary
  install-binary  Alias of build
  start           Start userspace VXLAN tunnel
  stop            Stop userspace VXLAN tunnel
  restart         Restart userspace VXLAN tunnel
  status          Show config and runtime status
  logs            Show recent logs
  menu            Interactive menu

Config override:
  VXLAN_TS_CONFIG=/path/to/config $0 start
EOF
}

main() {
    cmd="${1:-menu}"
    case "$cmd" in
        init-config) write_default_config ;;
        config) show_config ;;
        check) check_env ;;
        build|install-binary) need_root; build_binary ;;
        start) start_tunnel ;;
        stop) stop_tunnel ;;
        restart) restart_tunnel ;;
        status) status_tunnel ;;
        logs) show_logs ;;
        menu) menu ;;
        -h|--help|help) usage ;;
        *) err "Unknown command: $cmd"; usage; exit 1 ;;
    esac
}

main "$@"
