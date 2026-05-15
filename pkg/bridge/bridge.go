package bridge

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"sync"
	"time"

	"tap-vxlan-module/pkg/l2"
	"tap-vxlan-module/pkg/transport"
	"tap-vxlan-module/pkg/vxlan"
)

type Device interface {
	Read([]byte) (int, error)
	Write([]byte) (int, error)
	Name() string
}

type Config struct {
	VNI       uint32
	FrameSize int
	MACAge    time.Duration
	Logger    *slog.Logger
}

type Bridge struct {
	cfg      Config
	tap      Device
	conn     transport.PacketConn
	peers    []transport.Endpoint
	macTable *MACTable
	log      *slog.Logger
}

func New(cfg Config, tap Device, conn transport.PacketConn, peers []transport.Endpoint) (*Bridge, error) {
	if tap == nil {
		return nil, errors.New("tap device is nil")
	}
	if conn == nil {
		return nil, errors.New("transport packet conn is nil")
	}
	if cfg.VNI > vxlan.MaxVNI {
		return nil, vxlan.ErrInvalidVNI
	}
	if cfg.FrameSize <= 0 {
		cfg.FrameSize = l2.DefaultFrameSize
	}
	logger := cfg.Logger
	if logger == nil {
		logger = slog.Default()
	}
	return &Bridge{
		cfg:      cfg,
		tap:      tap,
		conn:     conn,
		peers:    uniqueEndpoints(peers),
		macTable: NewMACTable(cfg.MACAge),
		log:      logger,
	}, nil
}

func (b *Bridge) Run(ctx context.Context) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	errCh := make(chan error, 2)
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		errCh <- b.tapToNetwork(ctx)
	}()
	go func() {
		defer wg.Done()
		errCh <- b.networkToTap(ctx)
	}()

	var err error
	select {
	case <-ctx.Done():
		err = ctx.Err()
	case err = <-errCh:
		cancel()
	}
	_ = b.conn.Close()
	wg.Wait()
	return err
}

func (b *Bridge) tapToNetwork(ctx context.Context) error {
	buf := make([]byte, b.cfg.FrameSize)
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		n, err := b.tap.Read(buf)
		if err != nil {
			return err
		}
		frame := make([]byte, n)
		copy(frame, buf[:n])

		dst, ok := l2.DestinationMAC(frame)
		if !ok {
			continue
		}
		packet, err := vxlan.Encapsulate(b.cfg.VNI, frame)
		if err != nil {
			return err
		}

		if l2.IsBroadcast(dst) || l2.IsMulticast(dst) {
			b.flood(packet, nil)
			continue
		}
		if endpoint, ok := b.macTable.Lookup(dst); ok {
			if _, err := b.conn.WriteTo(packet, endpoint); err != nil {
				b.log.Warn("unicast write failed", "endpoint", endpoint.String(), "error", err)
			}
			continue
		}
		b.flood(packet, nil)
	}
}

func (b *Bridge) networkToTap(ctx context.Context) error {
	buf := make([]byte, b.cfg.FrameSize+vxlan.HeaderLen)
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		n, src, err := b.conn.ReadFrom(buf)
		if err != nil {
			return err
		}
		vni, frame, err := vxlan.Decapsulate(buf[:n])
		if err != nil || vni != b.cfg.VNI {
			continue
		}
		srcMAC, ok := l2.SourceMAC(frame)
		if ok {
			b.macTable.Learn(srcMAC, src)
		}
		if _, err := b.tap.Write(frame); err != nil {
			b.log.Warn("tap write failed", "device", b.tap.Name(), "error", err)
		}
	}
}

func (b *Bridge) flood(packet []byte, skip net.Addr) {
	for _, peer := range b.peers {
		if sameEndpoint(peer, skip) {
			continue
		}
		if _, err := b.conn.WriteTo(packet, peer); err != nil {
			b.log.Warn("flood write failed", "endpoint", peer.String(), "error", err)
		}
	}
}

func uniqueEndpoints(endpoints []transport.Endpoint) []transport.Endpoint {
	seen := make(map[string]bool)
	out := make([]transport.Endpoint, 0, len(endpoints))
	for _, endpoint := range endpoints {
		if endpoint == nil {
			continue
		}
		key := endpoint.Network() + "/" + endpoint.String()
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, endpoint)
	}
	return out
}

func sameEndpoint(a, b net.Addr) bool {
	if a == nil || b == nil {
		return false
	}
	return a.Network() == b.Network() && a.String() == b.String()
}
