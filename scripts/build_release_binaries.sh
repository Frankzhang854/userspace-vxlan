#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

DIST_DIR="${DIST_DIR:-dist}"
mkdir -p "$DIST_DIR"

build_one() {
    local name="$1"
    local goos="$2"
    local goarch="$3"
    local goarm="${4:-}"
    local gomips="${5:-}"

    echo "building ${name}"
    (
        export CGO_ENABLED=0
        export GOOS="$goos"
        export GOARCH="$goarch"
        if [ -n "$goarm" ]; then
            export GOARM="$goarm"
        fi
        if [ -n "$gomips" ]; then
            export GOMIPS="$gomips"
        fi
        go build \
            -trimpath \
            -ldflags="-s -w" \
            -o "${DIST_DIR}/tapvxlan-udp-${name}" \
            ./cmd/tapvxlan-udp
    )
}

build_one linux-amd64 linux amd64
build_one linux-386 linux 386
build_one linux-arm64 linux arm64
build_one linux-armv7 linux arm 7
build_one linux-armv6 linux arm 6
build_one linux-mips linux mips
build_one linux-mipsle linux mipsle
build_one linux-mips-softfloat linux mips "" softfloat
build_one linux-mipsle-softfloat linux mipsle "" softfloat
build_one linux-riscv64 linux riscv64

(
    cd "$DIST_DIR"
    sha256sum tapvxlan-udp-* | sort -k2 > checksums.txt
)

echo "release binaries written to ${DIST_DIR}"
