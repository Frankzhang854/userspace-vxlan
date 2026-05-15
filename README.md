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
git tag v0.2.0
git push origin v0.2.0
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
RELEASE_VERSION="v0.2.0"
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
