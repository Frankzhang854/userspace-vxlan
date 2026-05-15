package udp

import (
	"context"
	"net"

	"tap-vxlan-module/pkg/transport"
)

type Conn struct {
	*net.UDPConn
}

func Listen(address string) (*Conn, error) {
	addr, err := net.ResolveUDPAddr("udp", address)
	if err != nil {
		return nil, err
	}
	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		return nil, err
	}
	return &Conn{UDPConn: conn}, nil
}

func Resolve(_ context.Context, address string) (transport.Endpoint, error) {
	return net.ResolveUDPAddr("udp", address)
}
