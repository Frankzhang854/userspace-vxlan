#!/usr/bin/env sh
set -e

GO_VERSION="${GO_VERSION:-1.26.3}"
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64) GO_ARCH="amd64" ;;
    aarch64|arm64) GO_ARCH="arm64" ;;
    armv7l) GO_ARCH="armv6l" ;;
    *)
        echo "unsupported arch: $ARCH" >&2
        exit 1
        ;;
esac

TARBALL="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
URL_PRIMARY="https://go.dev/dl/${TARBALL}"
URL_FALLBACK="https://dl.google.com/go/${TARBALL}"

echo "Installing Go ${GO_VERSION} for linux/${GO_ARCH}"
rm -f "/tmp/${TARBALL}"

if command -v curl >/dev/null 2>&1; then
    curl -fL "$URL_PRIMARY" -o "/tmp/${TARBALL}" ||
        curl -fL "$URL_FALLBACK" -o "/tmp/${TARBALL}"
elif command -v wget >/dev/null 2>&1; then
    wget -O "/tmp/${TARBALL}" "$URL_PRIMARY" ||
        wget -O "/tmp/${TARBALL}" "$URL_FALLBACK"
else
    echo "curl or wget is required" >&2
    exit 1
fi

rm -rf /usr/local/go
tar -C /usr/local -xzf "/tmp/${TARBALL}"
ln -sfn /usr/local/go/bin/go /usr/local/bin/go
ln -sfn /usr/local/go/bin/gofmt /usr/local/bin/gofmt

cat >/etc/profile.d/go-env.sh <<'EOF'
# Go environment defaults.
case ":$PATH:" in
  *:/usr/local/go/bin:*) ;;
  *) export PATH="/usr/local/go/bin:$PATH" ;;
esac
case ":$PATH:" in
  *:$HOME/go/bin:*) ;;
  *) export PATH="$PATH:$HOME/go/bin" ;;
esac
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
EOF
chmod 644 /etc/profile.d/go-env.sh

/usr/local/bin/go env -w GOPROXY=https://goproxy.cn,direct
if id aiden >/dev/null 2>&1; then
    mkdir -p /home/aiden
    chown aiden:Users /home/aiden 2>/dev/null || chown aiden:aiden /home/aiden
    sudo -u aiden HOME=/home/aiden /usr/local/bin/go env -w GOPROXY=https://goproxy.cn,direct
fi

echo "==go=="
command -v go
go version
go env GOPROXY
