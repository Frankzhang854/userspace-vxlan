package transport

import (
	"context"
	"net"
)

type Endpoint = net.Addr

type PacketConn interface {
	ReadFrom([]byte) (int, Endpoint, error)
	WriteTo([]byte, Endpoint) (int, error)
	Close() error
}

type Resolver interface {
	Resolve(context.Context, string) (Endpoint, error)
}
