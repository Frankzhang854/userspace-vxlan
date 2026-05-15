# TAP VXLAN Module

This is a clean standalone Go module for user-space L2 forwarding:

```text
TAP device <-> VXLAN encap/decap <-> PacketTransport
```

The core bridge does not depend on Tailscale. Any tunnel can be used later as
long as it exposes packet-style `ReadFrom` and `WriteTo` behavior.

## Layout

```text
cmd/tapvxlan-udp/       runnable UDP demo
pkg/bridge/            TAP <-> VXLAN <-> transport forwarding
pkg/l2/                Ethernet frame helpers
pkg/tap/               TAP device creation
pkg/transport/         transport abstraction
pkg/transport/udp/     plain UDP example transport
pkg/vxlan/             RFC 7348 VXLAN header encode/decode
```

## Transport Boundary

To replace UDP with Tailscale, QUIC, WebSocket, raw TCP framing, or another
underlay, implement this interface:

```go
type PacketConn interface {
    ReadFrom([]byte) (int, net.Addr, error)
    WriteTo([]byte, net.Addr) (int, error)
    Close() error
}
```

For `tsnet`, the object returned by `Server.ListenPacket(ctx, "udp", ":4789")`
already has this shape, so the bridge can use it directly.

## UDP Demo

Node A:

```bash
sudo ./tapvxlan-udp -tap tapvx0 -vni 100 -listen :4789 -peers 192.0.2.20:4789
sudo ip link set tapvx0 up
sudo ip link set tapvx0 mtu 1280
```

Node B:

```bash
sudo ./tapvxlan-udp -tap tapvx0 -vni 100 -listen :4789 -peers 192.0.2.10:4789
sudo ip link set tapvx0 up
sudo ip link set tapvx0 mtu 1280
```

If the TAP is attached to a Linux bridge, put the IP address on the bridge
instead of the TAP device.

## Notes

- TAP is required for full L2 Ethernet forwarding.
- Kernel VXLAN support is not required.
- Kernel WireGuard support is not required if the underlay is user-space.
- Creating TAP usually requires `/dev/net/tun` and `CAP_NET_ADMIN`.
- Start with MTU 1280 or 1360, then increase after testing the real underlay.
- The bridge includes MAC learning with aging and flood forwarding for
  broadcast, multicast, and unknown unicast.

## GitHub Release Builds

This repository includes a GitHub Actions workflow that builds static Linux
binaries when a version tag is pushed.

Create and push a tag:

```bash
git tag v0.5.0
git push origin v0.5.0
```

The workflow publishes these release assets:

```text
userspace-vxlan-tailscale.sh
tapvxlan-udp-linux-amd64
tapvxlan-udp-linux-386
tapvxlan-udp-linux-arm64
tapvxlan-udp-linux-armv7
tapvxlan-udp-linux-armv6
tapvxlan-udp-linux-mips
tapvxlan-udp-linux-mipsle
tapvxlan-udp-linux-mips-softfloat
tapvxlan-udp-linux-mipsle-softfloat
tapvxlan-udp-linux-riscv64
checksums.txt
```

Target devices do not need Go installed if the matching binary is downloaded
to `BINARY_PATH`, usually `/usr/local/bin/tapvxlan-udp`.

The control script can download release binaries automatically:

```bash
GITHUB_REPO="Frankzhang854/userspace-vxlan"
RELEASE_VERSION="v0.5.0"
BINARY_PATH="/usr/local/bin/tapvxlan-udp"
VERIFY_DOWNLOAD="1"
```

Then run:

```bash
sudo ./userspace-vxlan-tailscale.sh install-binary
```

The script maps `uname -m` to the matching release asset and verifies it with
`checksums.txt` when `sha256sum` is available.

`build` is kept as a compatibility alias for `install-binary`; it does not
compile Go on the target device. Go is only needed in GitHub Actions.

For networks where direct GitHub downloads are unstable, the control script can
automatically fall back to a GitHub acceleration prefix:

```bash
GITHUB_ACCELERATOR_MODE="auto"
GITHUB_ACCELERATOR_URL="https://github.521314666.xyz"
GITHUB_DIRECT_CHECK_TIMEOUT="8"
```

Modes:

```text
auto    Test the direct GitHub URL first; use the accelerator only if needed.
always  Always prefix GitHub download URLs with GITHUB_ACCELERATOR_URL.
never   Never use the accelerator.
```

For example, when acceleration is needed, the script downloads from:

```text
https://github.521314666.xyz/https://github.com/Frankzhang854/userspace-vxlan/releases/download/v0.5.0/tapvxlan-udp-linux-amd64
```

## Control Script Usage

Download the control script on a target device:

```bash
wget -O userspace-vxlan-tailscale.sh \
  https://github.com/Frankzhang854/userspace-vxlan/releases/download/v0.5.0/userspace-vxlan-tailscale.sh
chmod +x userspace-vxlan-tailscale.sh
```

Use the interactive menu:

```bash
sudo ./userspace-vxlan-tailscale.sh
```

The menu follows the kernel VXLAN script style:

```text
1) Create tunnel
2) Modify tunnel
3) Show tunnel details
4) Delete tunnel
5) Apply all
6) Set manual MTU
7) Enable tunnel autostart
8) Disable tunnel autostart
9) Set tunnel autostart delay
10) Show manager status
11) Uninstall manager and helper
12) View log
13) Enable/Switch tunnels
0) Exit
```

Each tunnel is saved as an independent config:

```text
/etc/userspace-vxlan.d/<name>.conf
```

Useful direct commands:

```bash
sudo ./userspace-vxlan-tailscale.sh create NAME
sudo ./userspace-vxlan-tailscale.sh list
sudo ./userspace-vxlan-tailscale.sh enable NAME
sudo ./userspace-vxlan-tailscale.sh disable NAME
sudo ./userspace-vxlan-tailscale.sh delete NAME
sudo ./userspace-vxlan-tailscale.sh apply-all
sudo ./userspace-vxlan-tailscale.sh stop-all
sudo ./userspace-vxlan-tailscale.sh status-json
sudo ./userspace-vxlan-tailscale.sh enable-autostart
```
