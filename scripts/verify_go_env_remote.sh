#!/usr/bin/env sh
set -e

echo "==passwd=="
getent passwd aiden

echo "==home=="
ls -ld /home /home/aiden

echo "==profile=="
cat /etc/profile.d/go-env.sh

echo "==root-go=="
command -v go
go version
go env GOPROXY GOMODCACHE GOCACHE

echo "==aiden-go=="
cd /home/aiden
sudo -u aiden HOME=/home/aiden sh -lc 'pwd; command -v go; go version; go env GOPROXY GOMODCACHE GOCACHE'
