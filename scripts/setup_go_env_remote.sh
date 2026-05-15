#!/usr/bin/env sh
set -e

if [ ! -d /home/aiden ]; then
    mkdir -p /home/aiden
    chown aiden:Users /home/aiden
    chmod 755 /home/aiden
fi

cat >/etc/profile.d/go-env.sh <<'EOF'
# Go environment defaults.
case ":$PATH:" in
  *:/usr/local/go/bin:*) ;;
  *) [ -d /usr/local/go/bin ] && export PATH="$PATH:/usr/local/go/bin" ;;
esac
case ":$PATH:" in
  *:$HOME/go/bin:*) ;;
  *) export PATH="$PATH:$HOME/go/bin" ;;
esac
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
EOF
chmod 644 /etc/profile.d/go-env.sh

go env -w GOPROXY=https://goproxy.cn,direct
sudo -u aiden HOME=/home/aiden go env -w GOPROXY=https://goproxy.cn,direct

echo "==root=="
command -v go
go version
go env GOPROXY GOMODCACHE GOCACHE

echo "==aiden=="
sudo -u aiden HOME=/home/aiden sh -lc 'command -v go; go version; go env GOPROXY GOMODCACHE GOCACHE'
