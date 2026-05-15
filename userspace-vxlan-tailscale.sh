#!/usr/bin/env bash
set -u

VERSION="0.5.2-userspace"

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

GLOBAL_CONFIG="${USVX_GLOBAL_CONFIG:-/etc/userspace-vxlan.conf}"
CONFIG_DIR="${USVX_CONFIG_DIR:-/etc/userspace-vxlan.d}"
CONFIG_FILE="${VXLAN_TS_CONFIG:-/etc/userspace-vxlan-tailscale.conf}"
SERVICE_NAME="userspace-vxlan-tailscale"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
INITD_SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"
SCRIPT_INSTALL_PATH="/usr/local/sbin/userspace-vxlan-tailscale.sh"
LOG_FILE_GLOBAL="/var/log/userspace-vxlan-manager.log"
DEFAULT_TUNNEL_ENABLE_MODE="exclusive-by-iface"
DEFAULT_AUTOSTART_DELAY="0"

TUNNEL_NAME="uvxlan0"
ENABLED="true"
VNI="100"
TAP_IFACE="tapvx100"
BRIDGE_IFACE=""
MANAGE_BRIDGE="0"
PHYS_IFACES=""
DETACH_PHYS_ON_STOP="1"
REMOVE_MANAGED_BRIDGE_ON_STOP="1"
VXLAN_PORT="4789"
LOCAL_LISTEN="0.0.0.0:${VXLAN_PORT}"
PEERS=""
MTU="1280"
FRAME_SIZE="1600"
BINARY_PATH="/usr/local/bin/tapvxlan-udp"
PID_FILE="/var/run/userspace-vxlan-tailscale.pid"
LOG_FILE="/var/log/userspace-vxlan-tailscale.log"
GITHUB_REPO="Frankzhang854/userspace-vxlan"
RELEASE_VERSION="latest"
DOWNLOAD_BASE_URL=""
VERIFY_DOWNLOAD="1"
DOWNLOAD_TIMEOUT="120"
GITHUB_ACCELERATOR_MODE="auto"
GITHUB_ACCELERATOR_URL="https://github.521314666.xyz"
GITHUB_DIRECT_CHECK_TIMEOUT="8"
ALLOW_IFACE_WITH_IP="1"
NETWORK_MANAGER_TYPE="none"
NM_CONNECTION_ID=""
NM_UNMANAGED_CONF=""
TUNNEL_ENABLE_MODE="$DEFAULT_TUNNEL_ENABLE_MODE"
TUNNEL_AUTO_START_DELAY="$DEFAULT_AUTOSTART_DELAY"

RED=""
GREEN=""
YELLOW=""
BLUE=""
NC=""
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

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

validate_tunnel_name() {
    case "$1" in
        ''|*[!A-Za-z0-9_-]*)
            return 1
            ;;
    esac
    [ ${#1} -le 9 ]
}

prompt_tunnel_name() {
    prompt="${1:-Tunnel name: }"
    while true; do
        printf "%s" "$prompt" >&2
        read -r name
        if validate_tunnel_name "$name"; then
            printf '%s\n' "$name"
            return 0
        fi
        warn "Use 1-9 characters: A-Z, a-z, 0-9, underscore, hyphen." >&2
    done
}

number_in_range() {
    value="$1"
    min="$2"
    max="$3"
    case "$value" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$value" -ge "$min" ] && [ "$value" -le "$max" ]
}

prompt_number_range() {
    prompt="$1"
    default="$2"
    min="$3"
    max="$4"
    while true; do
        printf "%s" "$prompt" >&2
        read -r value
        value="${value:-$default}"
        if number_in_range "$value" "$min" "$max"; then
            printf '%s\n' "$value"
            return 0
        fi
        warn "Please enter a number from $min to $max." >&2
    done
}

normalize_enabled() {
    value="${1:-true}"
    case "$value" in
        false|0|no|off|disabled) echo "false" ;;
        *) echo "true" ;;
    esac
}

ifname_for() {
    prefix="$1"
    name="$2"
    safe="$(printf '%s' "$name" | tr -c 'A-Za-z0-9_-' '_')"
    printf '%s%s' "$prefix" "$safe" | cut -c1-15
}

tunnel_config_file() {
    printf '%s/%s.conf\n' "$CONFIG_DIR" "$1"
}

ensure_manager_env() {
    need_root
    mkdir -p "$CONFIG_DIR" "$(dirname "$GLOBAL_CONFIG")" "$(dirname "$LOG_FILE_GLOBAL")"
    if [ ! -f "$GLOBAL_CONFIG" ]; then
        cat >"$GLOBAL_CONFIG" <<EOF
SCRIPT_PATH=$(config_quote "$SCRIPT_PATH")
TUNNEL_ENABLE_MODE=$(config_quote "$DEFAULT_TUNNEL_ENABLE_MODE")
TUNNEL_AUTO_START_DELAY=$(config_quote "$DEFAULT_AUTOSTART_DELAY")
GITHUB_REPO=$(config_quote "$GITHUB_REPO")
RELEASE_VERSION=$(config_quote "$RELEASE_VERSION")
GITHUB_ACCELERATOR_MODE=$(config_quote "$GITHUB_ACCELERATOR_MODE")
GITHUB_ACCELERATOR_URL=$(config_quote "$GITHUB_ACCELERATOR_URL")
EOF
    fi
    load_global_config
}

load_global_config() {
    if [ -f "$GLOBAL_CONFIG" ]; then
        # shellcheck disable=SC1090
        . "$GLOBAL_CONFIG"
    fi
    TUNNEL_ENABLE_MODE="${TUNNEL_ENABLE_MODE:-$DEFAULT_TUNNEL_ENABLE_MODE}"
    TUNNEL_AUTO_START_DELAY="${TUNNEL_AUTO_START_DELAY:-$DEFAULT_AUTOSTART_DELAY}"
    GITHUB_REPO="${GITHUB_REPO:-Frankzhang854/userspace-vxlan}"
    RELEASE_VERSION="${RELEASE_VERSION:-latest}"
    GITHUB_ACCELERATOR_MODE="${GITHUB_ACCELERATOR_MODE:-auto}"
    GITHUB_ACCELERATOR_URL="${GITHUB_ACCELERATOR_URL:-https://github.521314666.xyz}"
}

update_global_kv() {
    key="$1"
    value="$2"
    mkdir -p "$(dirname "$GLOBAL_CONFIG")"
    if grep -q "^${key}=" "$GLOBAL_CONFIG" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=$(config_quote "$value")|" "$GLOBAL_CONFIG"
    else
        printf '%s=%s\n' "$key" "$(config_quote "$value")" >>"$GLOBAL_CONFIG"
    fi
}

reset_tunnel_defaults() {
    name="${1:-uvxlan0}"
    TUNNEL_NAME="$name"
    ENABLED="true"
    VNI="100"
    TAP_IFACE="$(ifname_for tap "$name")"
    BRIDGE_IFACE=""
    MANAGE_BRIDGE="0"
    PHYS_IFACES=""
    DETACH_PHYS_ON_STOP="1"
    REMOVE_MANAGED_BRIDGE_ON_STOP="1"
    VXLAN_PORT="4789"
    LOCAL_LISTEN="0.0.0.0:4789"
    PEERS=""
    MTU="1280"
    FRAME_SIZE="1600"
    BINARY_PATH="/usr/local/bin/tapvxlan-udp"
    PID_FILE="/var/run/userspace-vxlan-${name}.pid"
    LOG_FILE="/var/log/userspace-vxlan-${name}.log"
    DOWNLOAD_BASE_URL=""
    VERIFY_DOWNLOAD="1"
    DOWNLOAD_TIMEOUT="120"
    GITHUB_DIRECT_CHECK_TIMEOUT="8"
    ALLOW_IFACE_WITH_IP="1"
    NETWORK_MANAGER_TYPE="none"
    NM_CONNECTION_ID=""
    NM_UNMANAGED_CONF=""
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
    fi
    LOCAL_LISTEN="${LOCAL_LISTEN:-0.0.0.0:${VXLAN_PORT}}"
    MANAGE_BRIDGE="${MANAGE_BRIDGE:-0}"
    PHYS_IFACES="${PHYS_IFACES:-}"
    DETACH_PHYS_ON_STOP="${DETACH_PHYS_ON_STOP:-1}"
    REMOVE_MANAGED_BRIDGE_ON_STOP="${REMOVE_MANAGED_BRIDGE_ON_STOP:-1}"
    GITHUB_REPO="${GITHUB_REPO:-Frankzhang854/userspace-vxlan}"
    RELEASE_VERSION="${RELEASE_VERSION:-latest}"
    DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL:-}"
    VERIFY_DOWNLOAD="${VERIFY_DOWNLOAD:-1}"
    DOWNLOAD_TIMEOUT="${DOWNLOAD_TIMEOUT:-120}"
    GITHUB_ACCELERATOR_MODE="${GITHUB_ACCELERATOR_MODE:-auto}"
    GITHUB_ACCELERATOR_URL="${GITHUB_ACCELERATOR_URL:-https://github.521314666.xyz}"
    GITHUB_DIRECT_CHECK_TIMEOUT="${GITHUB_DIRECT_CHECK_TIMEOUT:-8}"
    ALLOW_IFACE_WITH_IP="${ALLOW_IFACE_WITH_IP:-1}"
    NETWORK_MANAGER_TYPE="${NETWORK_MANAGER_TYPE:-none}"
    NM_CONNECTION_ID="${NM_CONNECTION_ID:-}"
    NM_UNMANAGED_CONF="${NM_UNMANAGED_CONF:-}"
    ENABLED="$(normalize_enabled "${ENABLED:-true}")"
}

load_tunnel_config() {
    name="$1"
    validate_tunnel_name "$name" || return 1
    CONFIG_FILE="$(tunnel_config_file "$name")"
    reset_tunnel_defaults "$name"
    load_global_config
    [ -f "$CONFIG_FILE" ] || return 1
    load_config
}

write_default_config() {
    need_root
    if [ -f "$CONFIG_FILE" ]; then
        warn "Config already exists: $CONFIG_FILE"
        return 0
    fi

    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat >"$CONFIG_FILE" <<EOF
# User-space VXLAN over Tailscale/underlay config
# This backend does not require the kernel vxlan module.
# Target devices do not need Go installed; the binary is downloaded from GitHub Releases.

TUNNEL_NAME="uvxlan0"
ENABLED="true"
VNI="100"
TAP_IFACE="tapvx100"

# Set to br-lan, br0, or another bridge to join a LAN.
# Leave empty for standalone TAP testing.
BRIDGE_IFACE=""

# MANAGE_BRIDGE=1 creates BRIDGE_IFACE when missing.
# PHYS_IFACES is a comma/space-separated list of physical/member ports to add.
# Moving a management/uplink port into a bridge can interrupt remote access.
MANAGE_BRIDGE="0"
PHYS_IFACES=""
ALLOW_IFACE_WITH_IP="1"

# Cleanup options. Keep disabled on real devices unless this bridge is dedicated.
DETACH_PHYS_ON_STOP="1"
REMOVE_MANAGED_BRIDGE_ON_STOP="1"

VXLAN_PORT="4789"
LOCAL_LISTEN="0.0.0.0:4789"

# Comma-separated peer underlay addresses.
# For Tailscale, use peer Tailscale IPs or MagicDNS names.
PEERS=""

MTU="1280"
FRAME_SIZE="1600"

BINARY_PATH="/usr/local/bin/tapvxlan-udp"
PID_FILE="/var/run/userspace-vxlan-tailscale.pid"
LOG_FILE="/var/log/userspace-vxlan-tailscale.log"

# GitHub Release download settings.
GITHUB_REPO="Frankzhang854/userspace-vxlan"
RELEASE_VERSION="latest"
DOWNLOAD_BASE_URL=""
VERIFY_DOWNLOAD="1"
DOWNLOAD_TIMEOUT="120"
GITHUB_ACCELERATOR_MODE="auto"
GITHUB_ACCELERATOR_URL="https://github.521314666.xyz"
GITHUB_DIRECT_CHECK_TIMEOUT="8"
NETWORK_MANAGER_TYPE="none"
NM_CONNECTION_ID=""
NM_UNMANAGED_CONF=""
EOF
    ok "Created config: $CONFIG_FILE"
}

show_config() {
    load_config
    cat <<EOF
Version:       $VERSION
Config:        $CONFIG_FILE
Script path:   $SCRIPT_PATH
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
GitHub repo:   $GITHUB_REPO
Release:       $RELEASE_VERSION
Verify dl:     $VERIFY_DOWNLOAD
Dl timeout:    $DOWNLOAD_TIMEOUT
GH accel:      $GITHUB_ACCELERATOR_MODE
GH accel URL:  $GITHUB_ACCELERATOR_URL
EOF
}

config_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

config_set_kv() {
    file="$1"
    key="$2"
    value="$3"
    [ -n "$file" ] && [ -f "$file" ] || return 0
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=$(config_quote "$value")|" "$file"
    else
        printf '%s=%s\n' "$key" "$(config_quote "$value")" >>"$file"
    fi
}

ensure_tunnel_manager_keys() {
    file="$1"
    [ -n "$file" ] && [ -f "$file" ] || return 0
    grep -q '^NETWORK_MANAGER_TYPE=' "$file" 2>/dev/null || printf 'NETWORK_MANAGER_TYPE=%s\n' "$(config_quote "none")" >>"$file"
    grep -q '^NM_CONNECTION_ID=' "$file" 2>/dev/null || printf 'NM_CONNECTION_ID=%s\n' "$(config_quote "")" >>"$file"
    grep -q '^NM_UNMANAGED_CONF=' "$file" 2>/dev/null || printf 'NM_UNMANAGED_CONF=%s\n' "$(config_quote "")" >>"$file"
}

networkmanager_available() {
    command_exists nmcli || return 1
    if command_exists systemctl; then
        systemctl is-active NetworkManager >/dev/null 2>&1 || return 1
    fi
    return 0
}

nm_unmanaged_conf_path() {
    tunnel_name="$1"
    printf '/etc/NetworkManager/conf.d/userspace-vxlan-%s.conf\n' "$tunnel_name"
}

backup_manager_state_for_iface() {
    file="$1"
    iface="$2"
    tunnel_name="$3"
    [ -n "$iface" ] || return 0
    ensure_tunnel_manager_keys "$file"
    if networkmanager_available; then
        if command_exists timeout; then
            connection_id="$(timeout 3 nmcli -t -f GENERAL.CONNECTION device show "$iface" 2>/dev/null | awk 'NR==1 {sub(/^[^:]*:[[:space:]]*/, ""); print}')"
        else
            connection_id="$(nmcli -t -f GENERAL.CONNECTION device show "$iface" 2>/dev/null | awk 'NR==1 {sub(/^[^:]*:[[:space:]]*/, ""); print}')"
        fi
        connection_id="${connection_id:---}"
        config_set_kv "$file" "NETWORK_MANAGER_TYPE" "NetworkManager"
        config_set_kv "$file" "NM_CONNECTION_ID" "$connection_id"
        config_set_kv "$file" "NM_UNMANAGED_CONF" "$(nm_unmanaged_conf_path "$tunnel_name")"
    else
        config_set_kv "$file" "NETWORK_MANAGER_TYPE" "none"
        config_set_kv "$file" "NM_CONNECTION_ID" ""
        config_set_kv "$file" "NM_UNMANAGED_CONF" ""
    fi
}

disable_manager_control_for_iface() {
    file="$1"
    iface="$2"
    tunnel_name="$3"
    [ -n "$iface" ] || return 0
    backup_manager_state_for_iface "$file" "$iface" "$tunnel_name"
    if networkmanager_available; then
        unmanaged_conf="$(nm_unmanaged_conf_path "$tunnel_name")"
        nm_state="$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null | awk -F: -v dev="$iface" '$1 == dev {print $2; exit}')"
        if [ -f "$unmanaged_conf" ] && [ "$nm_state" = "unmanaged" ]; then
            info "$iface already unmanaged by NetworkManager"
            return 0
        fi
        mkdir -p "$(dirname "$unmanaged_conf")"
        cat >"$unmanaged_conf" <<EOF
[keyfile]
unmanaged-devices=interface-name:${iface}
EOF
        nmcli general reload >/dev/null 2>&1 || systemctl reload NetworkManager >/dev/null 2>&1 || true
        nmcli device set "$iface" managed no >/dev/null 2>&1 || true
        ok "Excluded $iface from NetworkManager"
    fi
}

make_iface_pure_l2() {
    iface="$1"
    [ -n "$iface" ] || return 0
    ip link show dev "$iface" >/dev/null 2>&1 || return 0
    ip addr flush dev "$iface" >/dev/null 2>&1 || true
    sysctl -w "net.ipv6.conf.${iface}.disable_ipv6=1" >/dev/null 2>&1 || true
    sysctl -w "net.ipv6.conf.${iface}.accept_ra=0" >/dev/null 2>&1 || true
    sysctl -w "net.ipv6.conf.${iface}.autoconf=0" >/dev/null 2>&1 || true
}

restore_iface_l3_defaults() {
    iface="$1"
    [ -n "$iface" ] || return 0
    ip link show dev "$iface" >/dev/null 2>&1 || return 0
    sysctl -w "net.ipv6.conf.${iface}.disable_ipv6=0" >/dev/null 2>&1 || true
    sysctl -w "net.ipv6.conf.${iface}.accept_ra=1" >/dev/null 2>&1 || true
    sysctl -w "net.ipv6.conf.${iface}.autoconf=1" >/dev/null 2>&1 || true
}

restore_manager_control_from_file() {
    file="$1"
    [ -n "$file" ] && [ -f "$file" ] || return 0
    (
        # shellcheck disable=SC1090
        . "$file"
        if [ "${NETWORK_MANAGER_TYPE:-none}" = "NetworkManager" ] && command_exists nmcli; then
            if [ -n "${NM_UNMANAGED_CONF:-}" ]; then
                rm -f "$NM_UNMANAGED_CONF" >/dev/null 2>&1 || true
                nmcli general reload >/dev/null 2>&1 || systemctl reload NetworkManager >/dev/null 2>&1 || true
            fi
            first_iface=""
            set -- $(iface_list "${PHYS_IFACES:-}")
            first_iface="${1:-}"
            if [ -n "$first_iface" ]; then
                nmcli device set "$first_iface" managed yes >/dev/null 2>&1 || true
                if [ -n "${NM_CONNECTION_ID:-}" ] && [ "$NM_CONNECTION_ID" != "--" ]; then
                    nmcli connection up id "$NM_CONNECTION_ID" >/dev/null 2>&1 || nmcli device connect "$first_iface" >/dev/null 2>&1 || true
                else
                    nmcli device connect "$first_iface" >/dev/null 2>&1 || true
                fi
            fi
        fi
    )
}

write_config_from_vars() {
    need_root
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat >"$CONFIG_FILE" <<EOF
# User-space VXLAN over Tailscale/underlay config
# This backend does not require the kernel vxlan module.
# Target devices do not need Go installed; the binary is downloaded from GitHub Releases.

TUNNEL_NAME=$(config_quote "$TUNNEL_NAME")
ENABLED=$(config_quote "$ENABLED")
VNI=$(config_quote "$VNI")
TAP_IFACE=$(config_quote "$TAP_IFACE")

# Set to br-lan, br0, or another bridge to join a LAN.
# Leave empty for standalone TAP testing.
BRIDGE_IFACE=$(config_quote "$BRIDGE_IFACE")

# MANAGE_BRIDGE=1 creates BRIDGE_IFACE when missing.
# PHYS_IFACES is a comma/space-separated list of physical/member ports to add.
# Moving a management/uplink port into a bridge can interrupt remote access.
MANAGE_BRIDGE=$(config_quote "$MANAGE_BRIDGE")
PHYS_IFACES=$(config_quote "$PHYS_IFACES")
ALLOW_IFACE_WITH_IP=$(config_quote "$ALLOW_IFACE_WITH_IP")

# Cleanup options. Keep disabled on real devices unless this bridge is dedicated.
DETACH_PHYS_ON_STOP=$(config_quote "$DETACH_PHYS_ON_STOP")
REMOVE_MANAGED_BRIDGE_ON_STOP=$(config_quote "$REMOVE_MANAGED_BRIDGE_ON_STOP")

VXLAN_PORT=$(config_quote "$VXLAN_PORT")
LOCAL_LISTEN=$(config_quote "$LOCAL_LISTEN")

# Comma-separated peer underlay addresses.
# For Tailscale, use peer Tailscale IPs or MagicDNS names.
PEERS=$(config_quote "$PEERS")

MTU=$(config_quote "$MTU")
FRAME_SIZE=$(config_quote "$FRAME_SIZE")

BINARY_PATH=$(config_quote "$BINARY_PATH")
PID_FILE=$(config_quote "$PID_FILE")
LOG_FILE=$(config_quote "$LOG_FILE")

# GitHub Release download settings.
GITHUB_REPO=$(config_quote "$GITHUB_REPO")
RELEASE_VERSION=$(config_quote "$RELEASE_VERSION")
DOWNLOAD_BASE_URL=$(config_quote "$DOWNLOAD_BASE_URL")
VERIFY_DOWNLOAD=$(config_quote "$VERIFY_DOWNLOAD")
DOWNLOAD_TIMEOUT=$(config_quote "$DOWNLOAD_TIMEOUT")
GITHUB_ACCELERATOR_MODE=$(config_quote "$GITHUB_ACCELERATOR_MODE")
GITHUB_ACCELERATOR_URL=$(config_quote "$GITHUB_ACCELERATOR_URL")
GITHUB_DIRECT_CHECK_TIMEOUT=$(config_quote "$GITHUB_DIRECT_CHECK_TIMEOUT")
NETWORK_MANAGER_TYPE=$(config_quote "$NETWORK_MANAGER_TYPE")
NM_CONNECTION_ID=$(config_quote "$NM_CONNECTION_ID")
NM_UNMANAGED_CONF=$(config_quote "$NM_UNMANAGED_CONF")
EOF
    ok "Saved config: $CONFIG_FILE"
}

read_value() {
    prompt="$1"
    default="$2"
    var_name="$3"
    if [ -n "$default" ]; then
        printf "%s [%s]: " "$prompt" "$default"
    else
        printf "%s: " "$prompt"
    fi
    if read -r value; then
        :
    else
        value=""
    fi
    if [ -z "$value" ]; then
        value="$default"
    fi
    printf -v "$var_name" '%s' "$value"
}

ask_yes_no() {
    prompt="$1"
    default="$2"
    while true; do
        case "$default" in
            y|Y) suffix="Y/n" ;;
            *) suffix="y/N" ;;
        esac
        printf "%s [%s]: " "$prompt" "$suffix"
        if read -r answer; then
            :
        else
            answer=""
        fi
        if [ -z "$answer" ]; then
            answer="$default"
        fi
        case "$answer" in
            y|Y|yes|YES|Yes) return 0 ;;
            n|N|no|NO|No) return 1 ;;
            *) warn "Please answer y or n." ;;
        esac
    done
}

validate_uint() {
    name="$1"
    value="$2"
    max="$3"
    case "$value" in
        ''|*[!0-9]*)
            err "$name must be a number"
            return 1
            ;;
    esac
    if [ "$value" -gt "$max" ]; then
        err "$name must be <= $max"
        return 1
    fi
}

create_tunnel_wizard() {
    need_root
    load_config

    echo "Create a user-space VXLAN tunnel"
    echo "Config file: $CONFIG_FILE"
    echo

    if [ -f "$CONFIG_FILE" ]; then
        warn "Config already exists: $CONFIG_FILE"
        if ! ask_yes_no "Overwrite it and create a backup first?" "n"; then
            warn "Canceled"
            return 0
        fi
        backup="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp -p "$CONFIG_FILE" "$backup"
        ok "Backup saved: $backup"
    fi

    read_value "Tunnel name" "${TUNNEL_NAME:-uvxlan0}" TUNNEL_NAME
    read_value "VNI" "${VNI:-100}" VNI
    validate_uint "VNI" "$VNI" 16777215 || return 1

    default_tap="$TAP_IFACE"
    if [ -z "$default_tap" ] || [ "$default_tap" = "tapvx100" ]; then
        default_tap="tapvx${VNI}"
    fi
    read_value "TAP interface name" "$default_tap" TAP_IFACE

    read_value "Local UDP listen address" "${LOCAL_LISTEN:-0.0.0.0:4789}" LOCAL_LISTEN
    read_value "Peer list, comma-separated host:port" "$PEERS" PEERS
    if [ -z "$PEERS" ]; then
        warn "PEERS is empty. The tunnel can start, but it will not send flooded frames to remote nodes."
    fi

    read_value "MTU" "${MTU:-1280}" MTU
    validate_uint "MTU" "$MTU" 9000 || return 1
    read_value "Frame buffer size" "${FRAME_SIZE:-1600}" FRAME_SIZE
    validate_uint "Frame buffer size" "$FRAME_SIZE" 65535 || return 1

    if [ -n "$BRIDGE_IFACE" ]; then
        default_bridge_answer="y"
    else
        default_bridge_answer="n"
    fi
    if ask_yes_no "Attach TAP to a Linux bridge/LAN?" "$default_bridge_answer"; then
        read_value "Bridge interface" "${BRIDGE_IFACE:-br-lan}" BRIDGE_IFACE
        if [ "${MANAGE_BRIDGE:-0}" = "1" ]; then
            default_manage_bridge="y"
        else
            default_manage_bridge="n"
        fi
        if ask_yes_no "Create bridge if it does not exist?" "$default_manage_bridge"; then
            MANAGE_BRIDGE="1"
        else
            MANAGE_BRIDGE="0"
        fi
        read_value "Physical/member interfaces to add, comma or space separated" "$PHYS_IFACES" PHYS_IFACES
        if [ -n "$PHYS_IFACES" ]; then
            warn "Adding a management/uplink interface to a bridge can interrupt remote access."
            if [ "${ALLOW_IFACE_WITH_IP:-1}" = "1" ]; then
                default_allow_ip="y"
            else
                default_allow_ip="n"
            fi
            if ask_yes_no "Allow adding interfaces that already have IP addresses?" "$default_allow_ip"; then
                ALLOW_IFACE_WITH_IP="1"
            else
                ALLOW_IFACE_WITH_IP="0"
            fi
        fi
    else
        BRIDGE_IFACE=""
        MANAGE_BRIDGE="0"
        PHYS_IFACES=""
    fi

    read_value "Binary path" "${BINARY_PATH:-/usr/local/bin/tapvxlan-udp}" BINARY_PATH
    read_value "GitHub repo owner/name" "${GITHUB_REPO:-Frankzhang854/userspace-vxlan}" GITHUB_REPO
    read_value "Release version for binary download" "${RELEASE_VERSION:-latest}" RELEASE_VERSION
    read_value "GitHub accelerator mode (auto/always/never)" "${GITHUB_ACCELERATOR_MODE:-auto}" GITHUB_ACCELERATOR_MODE
    if [ "$GITHUB_ACCELERATOR_MODE" != "never" ] && [ "$GITHUB_ACCELERATOR_MODE" != "off" ]; then
        read_value "GitHub accelerator URL" "${GITHUB_ACCELERATOR_URL:-https://github.521314666.xyz}" GITHUB_ACCELERATOR_URL
    fi

    VXLAN_PORT="${VXLAN_PORT:-4789}"
    VERIFY_DOWNLOAD="${VERIFY_DOWNLOAD:-1}"
    DOWNLOAD_TIMEOUT="${DOWNLOAD_TIMEOUT:-120}"
    GITHUB_ACCELERATOR_URL="${GITHUB_ACCELERATOR_URL:-https://github.521314666.xyz}"
    GITHUB_DIRECT_CHECK_TIMEOUT="${GITHUB_DIRECT_CHECK_TIMEOUT:-8}"
    PID_FILE="${PID_FILE:-/var/run/userspace-vxlan-tailscale.pid}"
    LOG_FILE="${LOG_FILE:-/var/log/userspace-vxlan-tailscale.log}"
    DETACH_PHYS_ON_STOP="${DETACH_PHYS_ON_STOP:-1}"
    REMOVE_MANAGED_BRIDGE_ON_STOP="${REMOVE_MANAGED_BRIDGE_ON_STOP:-1}"
    DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL:-}"

    write_config_from_vars
    echo
    view_tunnel

    if ask_yes_no "Install/download the matching binary now?" "y"; then
        install_binary || return 1
    fi
    if ask_yes_no "Start this tunnel now?" "y"; then
        start_tunnel || return 1
    fi
    if ask_yes_no "Enable autostart on boot?" "n"; then
        enable_autostart || return 1
    fi
}

view_tunnel() {
    load_config
    echo "Tunnel summary"
    echo "  Name:       $TUNNEL_NAME"
    echo "  VNI:        $VNI"
    echo "  TAP:        $TAP_IFACE"
    echo "  Bridge:     ${BRIDGE_IFACE:-<none>}"
    echo "  Listen:     $LOCAL_LISTEN"
    echo "  Peers:      ${PEERS:-<empty>}"
    echo "  MTU:        $MTU"
    echo "  Config:     $CONFIG_FILE"
    echo "  Binary:     $BINARY_PATH"
    if is_running; then
        echo "  Runtime:    running, pid=$(cat "$PID_FILE")"
    else
        echo "  Runtime:    stopped"
    fi

    if command_exists ip; then
        if ip link show "$TAP_IFACE" >/dev/null 2>&1; then
            echo
            ip -br link show "$TAP_IFACE"
        fi
        if [ -n "$BRIDGE_IFACE" ] && ip link show "$BRIDGE_IFACE" >/dev/null 2>&1; then
            ip -br link show "$BRIDGE_IFACE"
        fi
    fi
}

iface_list() {
    printf '%s\n' "$1" | tr ',' ' '
}

detect_binary_asset() {
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) echo "tapvxlan-udp-linux-amd64" ;;
        i386|i486|i586|i686) echo "tapvxlan-udp-linux-386" ;;
        aarch64|arm64) echo "tapvxlan-udp-linux-arm64" ;;
        armv7l|armv7*) echo "tapvxlan-udp-linux-armv7" ;;
        armv6l|armv6*) echo "tapvxlan-udp-linux-armv6" ;;
        mipsel|mipsle) echo "tapvxlan-udp-linux-mipsle" ;;
        mips) echo "tapvxlan-udp-linux-mips" ;;
        riscv64) echo "tapvxlan-udp-linux-riscv64" ;;
        mips64*)
            err "mips64 is not included in the current release matrix"
            return 1
            ;;
        *)
            err "Unsupported architecture: $arch"
            return 1
            ;;
    esac
}

is_github_url() {
    case "$1" in
        https://github.com/*) return 0 ;;
        http://github.com/*) return 0 ;;
        *) return 1 ;;
    esac
}

accelerated_url() {
    url="$1"
    prefix="${GITHUB_ACCELERATOR_URL%/}"
    printf '%s/%s\n' "$prefix" "$url"
}

run_download() {
    url="$1"
    dest="$2"
    if command_exists curl; then
        curl -fL --connect-timeout 15 --max-time "$DOWNLOAD_TIMEOUT" --retry 2 --retry-delay 1 "$url" -o "$dest"
    elif command_exists wget; then
        wget -T "$DOWNLOAD_TIMEOUT" -O "$dest" "$url"
    else
        err "curl or wget is required"
        return 1
    fi
}

github_direct_available() {
    url="$1"
    if command_exists curl; then
        curl -fsIL --connect-timeout 5 --max-time "$GITHUB_DIRECT_CHECK_TIMEOUT" "$url" >/dev/null 2>&1
    elif command_exists wget; then
        wget --spider -T "$GITHUB_DIRECT_CHECK_TIMEOUT" "$url" >/dev/null 2>&1
    else
        return 1
    fi
}

select_download_url() {
    url="$1"
    if ! is_github_url "$url"; then
        printf '%s\n' "$url"
        return 0
    fi

    case "$GITHUB_ACCELERATOR_MODE" in
        never|off|0|false)
            printf '%s\n' "$url"
            ;;
        always|on|1|true)
            accelerated_url "$url"
            ;;
        auto|'')
            if github_direct_available "$url"; then
                info "GitHub direct download is reachable" >&2
                printf '%s\n' "$url"
            else
                warn "GitHub direct download is not reachable; using accelerator" >&2
                accelerated_url "$url"
            fi
            ;;
        *)
            warn "Unknown GITHUB_ACCELERATOR_MODE=$GITHUB_ACCELERATOR_MODE; using auto" >&2
            if github_direct_available "$url"; then
                printf '%s\n' "$url"
            else
                accelerated_url "$url"
            fi
            ;;
    esac
}

download_file() {
    url="$1"
    dest="$2"
    selected_url="$(select_download_url "$url")"

    if run_download "$selected_url" "$dest"; then
        return 0
    fi

    if is_github_url "$url"; then
        accel_url="$(accelerated_url "$url")"
        if [ "$selected_url" != "$accel_url" ] && [ "$GITHUB_ACCELERATOR_MODE" != "never" ] && [ "$GITHUB_ACCELERATOR_MODE" != "off" ]; then
            warn "Direct download failed; retrying with GitHub accelerator"
            run_download "$accel_url" "$dest"
            return $?
        fi
    fi

    return 1
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

install_binary() {
    need_root
    load_config
    if [ -x "$BINARY_PATH" ]; then
        ok "Binary already exists: $BINARY_PATH"
        return 0
    fi
    download_binary
}

update_binary() {
    need_root
    load_config
    rm -f "$BINARY_PATH"
    download_binary
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
            info "Downloading checksums.txt"
            download_file "$base_url/checksums.txt" "$tmp_checksums" || {
                rm -rf "$tmp_dir"
                return 1
            }
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
            warn "sha256sum not found; skipping checksum verification"
        fi
    fi

    mkdir -p "$(dirname "$BINARY_PATH")"
    cp "$tmp_bin" "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
    rm -rf "$tmp_dir"
    ok "Installed binary: $BINARY_PATH"
}

update_script() {
    need_root
    load_config
    base_url="$(release_base_url)" || return 1
    tmp_file="$(mktemp)"
    info "Downloading userspace-vxlan-tailscale.sh from $base_url"
    download_file "$base_url/userspace-vxlan-tailscale.sh" "$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }
    chmod +x "$tmp_file"
    mkdir -p "$(dirname "$SCRIPT_INSTALL_PATH")"
    cp "$tmp_file" "$SCRIPT_INSTALL_PATH"
    rm -f "$tmp_file"
    ok "Installed script: $SCRIPT_INSTALL_PATH"
}

ensure_binary() {
    load_config
    if [ -x "$BINARY_PATH" ]; then
        return 0
    fi
    warn "Binary missing: $BINARY_PATH"
    download_binary
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

    if [ -x "$BINARY_PATH" ]; then
        ok "Binary exists: $BINARY_PATH"
    else
        warn "Binary missing and will be downloaded: $BINARY_PATH"
    fi

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
                    msg="$iface has IP addresses. Adding it to a bridge can interrupt network access."
                    if [ "$ALLOW_IFACE_WITH_IP" = "1" ]; then
                        warn "$msg"
                    else
                        err "$msg Set ALLOW_IFACE_WITH_IP=1 to allow."
                        return 1
                    fi
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

    if command_exists ss; then
        port="${LOCAL_LISTEN##*:}"
        if ss -lun 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}\$"; then
            warn "UDP port appears in use: $port"
        fi
    fi
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
    ip link set dev "$member" nomaster >/dev/null 2>&1 || true
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
        disable_manager_control_for_iface "$CONFIG_FILE" "$iface" "$TUNNEL_NAME"
        ip link set dev "$iface" down >/dev/null 2>&1 || true
        add_iface_to_bridge "$iface" "$BRIDGE_IFACE" || return 1
        make_iface_pure_l2 "$iface"
    done
    make_iface_pure_l2 "$BRIDGE_IFACE"
    ip link set dev "$BRIDGE_IFACE" up >/dev/null 2>&1 || true
}

attach_bridge() {
    [ -n "$BRIDGE_IFACE" ] || return 0
    prepare_bridge || return 1
    add_iface_to_bridge "$TAP_IFACE" "$BRIDGE_IFACE"
    make_iface_pure_l2 "$TAP_IFACE"
    make_iface_pure_l2 "$BRIDGE_IFACE"
}

detach_bridge() {
    [ -n "$BRIDGE_IFACE" ] || return 0
    ip link set dev "$TAP_IFACE" nomaster >/dev/null 2>&1 || true
    if [ "$DETACH_PHYS_ON_STOP" = "1" ]; then
        for iface in $(iface_list "$PHYS_IFACES"); do
            ip link set dev "$iface" nomaster >/dev/null 2>&1 || true
            restore_iface_l3_defaults "$iface"
            ip link set dev "$iface" up >/dev/null 2>&1 || true
        done
        restore_manager_control_from_file "$CONFIG_FILE"
    fi
    if [ "$REMOVE_MANAGED_BRIDGE_ON_STOP" = "1" ] && [ "$MANAGE_BRIDGE" = "1" ]; then
        ip link set dev "$BRIDGE_IFACE" down >/dev/null 2>&1 || true
        ip link delete dev "$BRIDGE_IFACE" type bridge >/dev/null 2>&1 || \
            ip link delete dev "$BRIDGE_IFACE" >/dev/null 2>&1 || \
            ip link delete "$BRIDGE_IFACE" >/dev/null 2>&1 || true
    fi
}

start_tunnel() {
    need_root
    load_config
    check_env || return 1
    ensure_binary || return 1

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
        tail -n 80 "$LOG_FILE" >&2
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

restart_tunnel() {
    stop_tunnel || true
    start_tunnel
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
    if [ -n "$BRIDGE_IFACE" ] && ip link show "$BRIDGE_IFACE" >/dev/null 2>&1; then
        echo
        ip -d link show "$BRIDGE_IFACE"
    fi
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

status_json() {
    load_global_config
    printf '{'
    printf '"version":"%s",' "$(json_escape "$VERSION")"
    printf '"config_dir":"%s",' "$(json_escape "$CONFIG_DIR")"
    printf '"enable_mode":"%s",' "$(json_escape "${TUNNEL_ENABLE_MODE:-$DEFAULT_TUNNEL_ENABLE_MODE}")"
    printf '"tunnels":['
    first=1
    for conf in "$CONFIG_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        name="$(basename "$conf" .conf)"
        reset_tunnel_defaults "$name"
        CONFIG_FILE="$conf"
        load_config
        running=false
        pid=""
        if is_running; then
            running=true
            pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        fi
        [ "$first" = "0" ] && printf ','
        first=0
        printf '{'
        printf '"name":"%s",' "$(json_escape "$name")"
        printf '"enabled":%s,' "$(normalize_enabled "$ENABLED")"
        printf '"running":%s,' "$running"
        printf '"pid":"%s",' "$(json_escape "$pid")"
        printf '"tap":"%s",' "$(json_escape "$TAP_IFACE")"
        printf '"bridge":"%s",' "$(json_escape "$BRIDGE_IFACE")"
        printf '"phys_ifaces":"%s",' "$(json_escape "$PHYS_IFACES")"
        printf '"vni":"%s",' "$(json_escape "$VNI")"
        printf '"listen":"%s",' "$(json_escape "$LOCAL_LISTEN")"
        printf '"peers":"%s",' "$(json_escape "$PEERS")"
        printf '"binary":"%s",' "$(json_escape "$BINARY_PATH")"
        printf '"release":"%s"' "$(json_escape "$RELEASE_VERSION")"
        printf '}'
    done
    printf ']'
    printf '}\n'
}

show_logs() {
    load_config
    if [ -f "$LOG_FILE" ]; then
        tail -n 160 "$LOG_FILE"
    else
        warn "No log file: $LOG_FILE"
    fi
}

doctor() {
    load_config
    show_config
    echo
    check_env || true
    echo
    info "Detected asset: $(detect_binary_asset 2>/dev/null || echo unknown)"
    if [ -x "$BINARY_PATH" ]; then
        "$BINARY_PATH" -h >/dev/null 2>&1 && ok "Binary is executable"
    fi
    if is_running; then
        ok "Process running: $(cat "$PID_FILE")"
    else
        warn "Process not running"
    fi
    if [ -f "$LOG_FILE" ]; then
        info "Recent log:"
        tail -n 30 "$LOG_FILE"
    fi
}

install_systemd_service() {
    need_root
    ensure_manager_env
    mkdir -p "$(dirname "$SCRIPT_INSTALL_PATH")"
    if [ "$SCRIPT_PATH" != "$SCRIPT_INSTALL_PATH" ]; then
        cp "$SCRIPT_PATH" "$SCRIPT_INSTALL_PATH"
        chmod +x "$SCRIPT_INSTALL_PATH"
    fi

    cat >"$SYSTEMD_SERVICE_FILE" <<EOF
[Unit]
Description=User-space VXLAN over Tailscale
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep ${TUNNEL_AUTO_START_DELAY:-0}
ExecStart=$SCRIPT_INSTALL_PATH apply-all
ExecStop=$SCRIPT_INSTALL_PATH stop-all
TimeoutStartSec=60
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$(basename "$SYSTEMD_SERVICE_FILE")"
    ok "Installed systemd service: $SYSTEMD_SERVICE_FILE"
}

install_initd_service() {
    need_root
    ensure_manager_env
    mkdir -p "$(dirname "$SCRIPT_INSTALL_PATH")"
    if [ "$SCRIPT_PATH" != "$SCRIPT_INSTALL_PATH" ]; then
        cp "$SCRIPT_PATH" "$SCRIPT_INSTALL_PATH"
        chmod +x "$SCRIPT_INSTALL_PATH"
    fi

    cat >"$INITD_SERVICE_FILE" <<EOF
#!/bin/sh /etc/rc.common
START=99
STOP=10

start() {
    sleep ${TUNNEL_AUTO_START_DELAY:-0}
    $SCRIPT_INSTALL_PATH apply-all
}

stop() {
    $SCRIPT_INSTALL_PATH stop-all
}

restart() {
    $SCRIPT_INSTALL_PATH stop-all
    sleep ${TUNNEL_AUTO_START_DELAY:-0}
    $SCRIPT_INSTALL_PATH apply-all
}
EOF
    chmod +x "$INITD_SERVICE_FILE"
    "$INITD_SERVICE_FILE" enable >/dev/null 2>&1 || true
    ok "Installed init.d service: $INITD_SERVICE_FILE"
}

enable_autostart() {
    need_root
    if command_exists systemctl && [ -d /etc/systemd/system ]; then
        install_systemd_service
    elif [ -d /etc/init.d ]; then
        install_initd_service
    else
        err "No supported service manager found"
        return 1
    fi
}

disable_autostart() {
    need_root
    if command_exists systemctl && [ -f "$SYSTEMD_SERVICE_FILE" ]; then
        systemctl disable "$(basename "$SYSTEMD_SERVICE_FILE")" >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_SERVICE_FILE"
        systemctl daemon-reload >/dev/null 2>&1 || true
        ok "Removed systemd service"
    fi
    if [ -f "$INITD_SERVICE_FILE" ]; then
        "$INITD_SERVICE_FILE" disable >/dev/null 2>&1 || true
        rm -f "$INITD_SERVICE_FILE"
        ok "Removed init.d service"
    fi
}

uninstall() {
    need_root
    stop_all_tunnels || stop_tunnel || true
    disable_autostart || true
    rm -f "$BINARY_PATH"
    ok "Removed binary: $BINARY_PATH"
    warn "Configs kept: $CONFIG_DIR and $GLOBAL_CONFIG"
}

get_ifs() {
    if ! command_exists ip; then
        return 0
    fi
    ip -br link show | awk 'NF==0{next} $1!~/^(lo|ts|tail|dock|veth|br-|wg|vxlan|tun|tap|ppp)/ && $1!~/\.[0-9]+$/ {print $1}'
}

get_tailscale_peers() {
    command_exists tailscale || return 1
    command_exists jq || return 1
    tailscale status --json 2>/dev/null | jq -r '.Peer[]? | select(.ExitNode==false) | "\(.HostName):\(.TailscaleIPs[0])"' 2>/dev/null
}

set_config_enabled_state() {
    file="$1"
    state="$(normalize_enabled "$2")"
    if grep -q '^ENABLED=' "$file" 2>/dev/null; then
        sed -i "s|^ENABLED=.*|ENABLED=$(config_quote "$state")|" "$file"
    else
        printf 'ENABLED=%s\n' "$(config_quote "$state")" >>"$file"
    fi
}

tunnel_runtime_pid() {
    name="$1"
    file="$(tunnel_config_file "$name")"
    [ -f "$file" ] || return 1
    (
        reset_tunnel_defaults "$name"
        CONFIG_FILE="$file"
        load_config
        if [ -f "$PID_FILE" ]; then
            pid="$(cat "$PID_FILE" 2>/dev/null || true)"
            if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
                printf '%s\n' "$pid"
                exit 0
            fi
        fi
        exit 1
    )
}

list_tunnels() {
    ensure_manager_env
    echo
    echo "--- Configured tunnels ---"
    set -- "$CONFIG_DIR"/*.conf
    if [ ! -e "$1" ]; then
        echo "No config."
        return 0
    fi

    printf "%-4s %-12s %-8s %-12s %-6s %-16s %-18s %-8s\n" \
        "No." "Tunnel" "Enabled" "Iface" "VNI" "Listen" "Peers" "Runtime"

    idx=1
    for conf in "$CONFIG_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        name="$(basename "$conf" .conf)"
        (
            reset_tunnel_defaults "$name"
            CONFIG_FILE="$conf"
            load_config
            iface="${PHYS_IFACES:-${BRIDGE_IFACE:-standalone}}"
            peers_short="${PEERS:-<empty>}"
            [ ${#peers_short} -gt 18 ] && peers_short="$(printf '%s' "$peers_short" | cut -c1-15)..."
            if tunnel_runtime_pid "$name" >/dev/null 2>&1; then
                runtime="running"
            else
                runtime="stopped"
            fi
            printf "%-4s %-12s %-8s %-12s %-6s %-16s %-18s %-8s\n" \
                "$idx)" "$name" "$(normalize_enabled "$ENABLED")" "$iface" "$VNI" "$LOCAL_LISTEN" "$peers_short" "$runtime"
        )
        idx=$((idx + 1))
    done
}

choose_tunnel_name() {
    list_tunnels
    name="$(prompt_tunnel_name "Tunnel name: ")"
    if [ ! -f "$(tunnel_config_file "$name")" ]; then
        err "Tunnel config not found: $name"
        return 1
    fi
    SELECTED_TUNNEL="$name"
}

prompt_tunnel_index_selection() {
    prompt="${1:-Tunnel index(es), comma separated: }"
    names=""
    idx=1
    list_tunnels >&2
    for conf in "$CONFIG_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        name="$(basename "$conf" .conf)"
        names="${names}${idx}:${name} "
        idx=$((idx + 1))
    done
    [ -n "$names" ] || return 1
    printf "%s" "$prompt" >&2
    read -r input
    selected=""
    for item in $(printf '%s\n' "$input" | tr ',' ' '); do
        case "$item" in
            ''|*[!0-9]*)
                err "Invalid tunnel index: $item"
                return 1
                ;;
        esac
        found=""
        for pair in $names; do
            nidx="${pair%%:*}"
            nname="${pair#*:}"
            if [ "$nidx" = "$item" ]; then
                found="$nname"
                break
            fi
        done
        [ -n "$found" ] || { err "Invalid tunnel index: $item"; return 1; }
        if [ -z "$selected" ]; then
            selected="$found"
        else
            selected="${selected},${found}"
        fi
    done
    [ -n "$selected" ] || { err "No tunnel selected"; return 1; }
    printf '%s\n' "$selected"
}

first_phys_iface_for_tunnel() {
    file="$1"
    (
        # shellcheck disable=SC1090
        . "$file"
        set -- $(iface_list "${PHYS_IFACES:-}")
        printf '%s\n' "${1:-${BRIDGE_IFACE:-}}"
    )
}

disable_conflicting_tunnels() {
    target="$1"
    target_file="$(tunnel_config_file "$target")"
    mode="${TUNNEL_ENABLE_MODE:-$DEFAULT_TUNNEL_ENABLE_MODE}"
    target_iface="$(first_phys_iface_for_tunnel "$target_file")"
    [ "$mode" = "free" ] && return 0
    for conf in "$CONFIG_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        name="$(basename "$conf" .conf)"
        [ "$name" = "$target" ] && continue
        other_iface="$(first_phys_iface_for_tunnel "$conf")"
        if [ "$mode" = "single" ] || { [ "$mode" = "exclusive-by-iface" ] && [ -n "$target_iface" ] && [ "$target_iface" = "$other_iface" ]; }; then
            set_config_enabled_state "$conf" "false"
            stop_tunnel_by_name "$name" >/dev/null 2>&1 || true
            echo "Auto disabled conflicting tunnel [$name]."
        fi
    done
}

enable_tunnel_config() {
    name="$1"
    validate_tunnel_name "$name" || { err "Invalid tunnel name"; return 1; }
    file="$(tunnel_config_file "$name")"
    [ -f "$file" ] || { err "Tunnel config not found: $name"; return 1; }
    load_global_config
    disable_conflicting_tunnels "$name" || return 1
    set_config_enabled_state "$file" "true"
    ok "Tunnel [$name] enabled."
}

disable_tunnel_config() {
    name="$1"
    validate_tunnel_name "$name" || { err "Invalid tunnel name"; return 1; }
    file="$(tunnel_config_file "$name")"
    [ -f "$file" ] || { err "Tunnel config not found: $name"; return 1; }
    set_config_enabled_state "$file" "false"
    stop_tunnel_by_name "$name" || true
    ok "Tunnel [$name] disabled."
}

start_tunnel_by_name() {
    name="$1"
    load_tunnel_config "$name" || { err "Tunnel config not found: $name"; return 1; }
    start_tunnel
}

stop_tunnel_by_name() {
    name="$1"
    load_tunnel_config "$name" || { err "Tunnel config not found: $name"; return 1; }
    stop_tunnel
}

sync_apply_all() {
    ensure_manager_env
    rc=0
    for conf in "$CONFIG_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        name="$(basename "$conf" .conf)"
        load_tunnel_config "$name" || { rc=1; continue; }
        if [ "$(normalize_enabled "$ENABLED")" = "true" ]; then
            echo "Applying tunnel [$name]..."
            start_tunnel || rc=1
        else
            stop_tunnel || true
        fi
    done
    return "$rc"
}

stop_all_tunnels() {
    ensure_manager_env
    for conf in "$CONFIG_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        name="$(basename "$conf" .conf)"
        stop_tunnel_by_name "$name" || true
    done
}

save_config_logic() {
    name="$1"
    validate_tunnel_name "$name" || { err "Invalid tunnel name"; return 1; }
    ensure_manager_env
    file="$(tunnel_config_file "$name")"
    is_existing="false"
    if [ -f "$file" ]; then
        is_existing="true"
        load_tunnel_config "$name" || reset_tunnel_defaults "$name"
    else
        reset_tunnel_defaults "$name"
        CONFIG_FILE="$file"
    fi

    echo
    echo "Configure tunnel [$name]"
    read_value "Tunnel name" "$name" TUNNEL_NAME
    if [ "$TUNNEL_NAME" != "$name" ]; then
        validate_tunnel_name "$TUNNEL_NAME" || { err "Invalid tunnel name"; return 1; }
        name="$TUNNEL_NAME"
        file="$(tunnel_config_file "$name")"
        CONFIG_FILE="$file"
    fi

    mapfile -t ifs < <(get_ifs)
    echo "Choose physical/member interface:"
    echo "0) Standalone TAP only"
    idx=1
    for iface in "${ifs[@]}"; do
        echo "$idx) $iface"
        idx=$((idx + 1))
    done
    max_idx="${#ifs[@]}"
    iface_idx="$(prompt_number_range "Index: " "0" 0 "$max_idx")"
    if [ "$iface_idx" = "0" ]; then
        BRIDGE_IFACE=""
        PHYS_IFACES=""
        MANAGE_BRIDGE="0"
    else
        chosen_iface="${ifs[$((iface_idx - 1))]}"
        BRIDGE_IFACE="$(ifname_for br- "$name")"
        PHYS_IFACES="$chosen_iface"
        MANAGE_BRIDGE="1"
        warn "Adding $chosen_iface to a bridge can interrupt remote access."
        if ask_yes_no "Allow adding interfaces that already have IP addresses?" "y"; then
            ALLOW_IFACE_WITH_IP="1"
        else
            ALLOW_IFACE_WITH_IP="0"
        fi
    fi

    read_value "Bridge interface" "$BRIDGE_IFACE" BRIDGE_IFACE
    read_value "TAP interface name" "${TAP_IFACE:-$(ifname_for tap "$name")}" TAP_IFACE
    VNI="$(prompt_number_range "VNI (default ${VNI:-100}): " "${VNI:-100}" 1 16777215)"
    local_port="$(printf '%s' "${LOCAL_LISTEN##*:}")"
    local_port="$(prompt_number_range "Local UDP port (default ${local_port:-4789}): " "${local_port:-4789}" 1 65535)"
    LOCAL_LISTEN="0.0.0.0:${local_port}"

    echo "Reading Tailscale peers..."
    mapfile -t ts_peers < <(get_tailscale_peers || true)
    if [ "${#ts_peers[@]}" -gt 0 ]; then
        idx=1
        for peer in "${ts_peers[@]}"; do
            host="${peer%%:*}"
            ip="${peer#*:}"
            printf "%2d) %-20s [%s]\n" "$idx" "$host" "$ip"
            idx=$((idx + 1))
        done
        printf "Peer indexes, comma separated (empty for manual): "
        read -r peer_indexes
        if [ -n "$peer_indexes" ]; then
            echo "Peer mode:"
            echo "1) IP(static)"
            echo "2) Hostname(dynamic)"
            peer_mode="$(prompt_number_range "Choose [1-2]: " "1" 1 2)"
            peer_port="$(prompt_number_range "Peer UDP port (default ${VXLAN_PORT:-4789}): " "${VXLAN_PORT:-4789}" 1 65535)"
            PEERS=""
            for item in $(printf '%s\n' "$peer_indexes" | tr ',' ' '); do
                number_in_range "$item" 1 "${#ts_peers[@]}" || { err "Invalid peer index: $item"; return 1; }
                peer="${ts_peers[$((item - 1))]}"
                host="${peer%%:*}"
                ip="${peer#*:}"
                if [ "$peer_mode" = "2" ]; then
                    endpoint="${host}:${peer_port}"
                else
                    endpoint="${ip}:${peer_port}"
                fi
                if [ -z "$PEERS" ]; then
                    PEERS="$endpoint"
                else
                    PEERS="${PEERS},${endpoint}"
                fi
            done
        else
            read_value "Peer list, comma-separated host:port" "$PEERS" PEERS
        fi
    else
        warn "Could not read Tailscale peers automatically. Enter peers manually."
        read_value "Peer list, comma-separated host:port" "$PEERS" PEERS
    fi

    MTU="$(prompt_number_range "TAP MTU (default ${MTU:-1280}): " "${MTU:-1280}" 576 9000)"
    FRAME_SIZE="$(prompt_number_range "Frame buffer size (default ${FRAME_SIZE:-1600}): " "${FRAME_SIZE:-1600}" 576 65535)"
    read_value "Binary path" "${BINARY_PATH:-/usr/local/bin/tapvxlan-udp}" BINARY_PATH
    read_value "Release version for binary download" "${RELEASE_VERSION:-latest}" RELEASE_VERSION
    read_value "GitHub accelerator mode (auto/always/never)" "${GITHUB_ACCELERATOR_MODE:-auto}" GITHUB_ACCELERATOR_MODE

    PID_FILE="/var/run/userspace-vxlan-${name}.pid"
    LOG_FILE="/var/log/userspace-vxlan-${name}.log"
    VXLAN_PORT="$local_port"
    if [ "$is_existing" = "false" ]; then
        if ask_yes_no "Activate and switch to this tunnel now?" "y"; then
            ENABLED="true"
        else
            ENABLED="false"
        fi
    fi

    CONFIG_FILE="$file"
    write_config_from_vars
    ok "Tunnel [$name] saved."
    if [ "$ENABLED" = "true" ]; then
        enable_tunnel_config "$name" && sync_apply_all
    else
        echo "Tunnel [$name] saved as disabled. Use Enable/Switch tunnels when needed."
    fi
}

delete_tunnel_config() {
    if [ -n "${1:-}" ]; then
        SELECTED_TUNNEL="$1"
    else
        choose_tunnel_name || return 1
    fi
    validate_tunnel_name "$SELECTED_TUNNEL" || return 1
    file="$(tunnel_config_file "$SELECTED_TUNNEL")"
    [ -f "$file" ] || { err "Tunnel config not found."; return 1; }
    stop_tunnel_by_name "$SELECTED_TUNNEL" || true
    rm -f "$file"
    ok "Tunnel [$SELECTED_TUNNEL] deleted."
}

manage_tunnel_enable_menu() {
    while true; do
        load_global_config
        list_tunnels
        echo
        echo "Enable mode: ${TUNNEL_ENABLE_MODE:-$DEFAULT_TUNNEL_ENABLE_MODE}"
        echo "1) Enable/Switch selected tunnel(s)"
        echo "2) Disable selected tunnel(s)"
        echo "3) Enable only selected tunnel(s)"
        echo "4) Set enable mode"
        echo "0) Back"
        printf "Menu: "
        read -r opt
        case "$opt" in
            1)
                names="$(prompt_tunnel_index_selection "Tunnel index(es) to enable/switch, comma separated: ")" || continue
                for n in $(printf '%s\n' "$names" | tr ',' ' '); do
                    enable_tunnel_config "$n" || break
                done
                sync_apply_all
                ;;
            2)
                names="$(prompt_tunnel_index_selection "Tunnel index(es) to disable, comma separated: ")" || continue
                for n in $(printf '%s\n' "$names" | tr ',' ' '); do
                    disable_tunnel_config "$n" || break
                done
                ;;
            3)
                names="$(prompt_tunnel_index_selection "Tunnel index(es) to keep enabled, comma separated: ")" || continue
                for conf in "$CONFIG_DIR"/*.conf; do
                    [ -e "$conf" ] || continue
                    n="$(basename "$conf" .conf)"
                    case ",$names," in
                        *",$n,"*) set_config_enabled_state "$conf" "true" ;;
                        *) set_config_enabled_state "$conf" "false"; stop_tunnel_by_name "$n" >/dev/null 2>&1 || true ;;
                    esac
                done
                sync_apply_all
                ;;
            4)
                echo "Tunnel enable modes:"
                echo "1) exclusive-by-iface"
                echo "2) single"
                echo "3) free"
                mode_idx="$(prompt_number_range "Choose [1-3]: " "1" 1 3)"
                case "$mode_idx" in
                    1) mode="exclusive-by-iface" ;;
                    2) mode="single" ;;
                    3) mode="free" ;;
                esac
                update_global_kv "TUNNEL_ENABLE_MODE" "$mode"
                ok "Tunnel enable mode set to: $mode"
                ;;
            0) return 0 ;;
        esac
    done
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
    echo "  RELEASE_VERSION=\"v0.4.0\""
    echo "  GITHUB_ACCELERATOR_MODE=\"auto\""
}

show_menu() {
    load_global_config
    echo
    echo "========================================================"
    echo "    User-space VXLAN over Tailscale Manager v$VERSION"
    echo "    Flow: TAP <-> user-space VXLAN UDP <-> underlay"
    echo "    Config dir: $CONFIG_DIR"
    echo "    Tunnel autostart: $([ -f "$SYSTEMD_SERVICE_FILE" ] || [ -f "$INITD_SERVICE_FILE" ] && echo enabled || echo disabled)"
    echo "    Tunnel autostart delay: ${TUNNEL_AUTO_START_DELAY:-$DEFAULT_AUTOSTART_DELAY}s"
    echo "    Tunnel enable mode: ${TUNNEL_ENABLE_MODE:-$DEFAULT_TUNNEL_ENABLE_MODE}"
    echo "    GitHub accelerator: ${GITHUB_ACCELERATOR_MODE:-auto}"
    echo "========================================================"
}

menu() {
    ensure_manager_env
    while true; do
        show_menu
        echo "1) Create tunnel"
        echo "2) Modify tunnel"
        echo "3) Show tunnel details"
        echo "4) Delete tunnel"
        echo "5) Apply all"
        echo "6) Set manual MTU"
        echo "7) Enable tunnel autostart"
        echo "8) Disable tunnel autostart"
        echo "9) Set tunnel autostart delay"
        echo "10) Show manager status"
        echo "11) Uninstall manager and helper"
        echo "12) View log"
        echo "13) Enable/Switch tunnels"
        echo "0) Exit"
        printf "Menu: "
        read -r choice
        case "$choice" in
            1)
                n="$(prompt_tunnel_name "Tunnel name: ")"
                save_config_logic "$n"
                ;;
            2)
                list_tunnels
                n="$(prompt_tunnel_name "Tunnel name to modify: ")"
                if [ -f "$(tunnel_config_file "$n")" ]; then
                    save_config_logic "$n"
                else
                    warn "Tunnel config not found."
                fi
                ;;
            3) list_tunnels ;;
            4) delete_tunnel_config ;;
            5) sync_apply_all ;;
            6)
                choose_tunnel_name || continue
                load_tunnel_config "$SELECTED_TUNNEL" || continue
                MTU="$(prompt_number_range "TAP MTU (default $MTU): " "$MTU" 576 9000)"
                FRAME_SIZE="$(prompt_number_range "Frame buffer size (default $FRAME_SIZE): " "$FRAME_SIZE" 576 65535)"
                write_config_from_vars
                [ -d "/sys/class/net/$TAP_IFACE" ] && ip link set dev "$TAP_IFACE" mtu "$MTU" >/dev/null 2>&1 || true
                ok "Tunnel [$SELECTED_TUNNEL] MTU updated."
                ;;
            7) enable_autostart ;;
            8) disable_autostart ;;
            9)
                delay="$(prompt_number_range "Autostart delay seconds (default ${TUNNEL_AUTO_START_DELAY:-0}): " "${TUNNEL_AUTO_START_DELAY:-0}" 0 3600)"
                update_global_kv "TUNNEL_AUTO_START_DELAY" "$delay"
                ok "Tunnel autostart delay set to ${delay}s"
                ;;
            10)
                show_menu
                list_tunnels
                ;;
            11) uninstall ;;
            12)
                if [ -f "$LOG_FILE_GLOBAL" ]; then
                    tail -n 80 "$LOG_FILE_GLOBAL"
                else
                    warn "No manager log file: $LOG_FILE_GLOBAL"
                fi
                ;;
            13) manage_tunnel_enable_menu ;;
            0) exit 0 ;;
            *) warn "Unknown choice" ;;
        esac
    done
}

usage() {
    cat <<EOF
Usage: $0 COMMAND

Commands:
  create NAME       Create or modify one named tunnel
  modify NAME       Alias of create
  list              Show configured tunnels
  apply-all         Apply/start all enabled tunnels
  stop-all          Stop all configured tunnels
  enable NAME       Enable/switch one tunnel and apply enabled tunnels
  disable NAME      Disable one tunnel and stop its runtime
  delete NAME       Delete one tunnel config and stop its runtime
  new-tunnel        Interactive wizard: create config, install binary, start
  create-tunnel     Alias of new-tunnel
  view-tunnel       Show concise tunnel summary for legacy single config
  init-config       Create default config at $CONFIG_FILE
  config            Show loaded config
  check             Check TAP/Tailscale/bridge environment
  doctor            Detailed diagnostics
  install-binary    Download matching tapvxlan-udp binary from GitHub Release
  update-binary     Force re-download matching binary
  update-script     Download this control script from GitHub Release
  start             Start userspace VXLAN tunnel
  stop              Stop userspace VXLAN tunnel
  restart           Restart userspace VXLAN tunnel
  status            Show config and runtime status
  status-json       Print machine-readable status JSON
  logs              Show recent logs
  enable-autostart  Install and enable systemd/init.d autostart
  disable-autostart Disable and remove systemd/init.d autostart
  uninstall         Stop tunnel, remove service and binary; keep config
  menu              Interactive menu

Compatibility aliases:
  build             Alias of install-binary; no local Go build is performed

Config override:
  VXLAN_TS_CONFIG=/path/to/config $0 start
EOF
}

main() {
    cmd="${1:-menu}"
    case "$cmd" in
        create|modify) save_config_logic "${2:-$(prompt_tunnel_name "Tunnel name: ")}" ;;
        list|show-tunnels|list-tunnels) list_tunnels ;;
        apply-all) sync_apply_all ;;
        stop-all) stop_all_tunnels ;;
        enable) enable_tunnel_config "${2:-}" && sync_apply_all ;;
        disable) disable_tunnel_config "${2:-}" ;;
        delete) delete_tunnel_config "${2:-}" ;;
        new-tunnel|create-tunnel) save_config_logic "$(prompt_tunnel_name "Tunnel name: ")" ;;
        view-tunnel|show-tunnel) view_tunnel ;;
        init-config) write_default_config ;;
        config) show_config ;;
        check) check_env ;;
        doctor) doctor ;;
        build|install-binary) install_binary ;;
        update-binary) update_binary ;;
        update-script) update_script ;;
        start) start_tunnel ;;
        stop) stop_tunnel ;;
        restart) restart_tunnel ;;
        status) status_tunnel ;;
        status-json) status_json ;;
        logs) show_logs ;;
        enable-autostart) enable_autostart ;;
        disable-autostart) disable_autostart ;;
        uninstall) uninstall ;;
        menu) menu ;;
        -h|--help|help) usage ;;
        *) err "Unknown command: $cmd"; usage; exit 1 ;;
    esac
}

main "$@"
