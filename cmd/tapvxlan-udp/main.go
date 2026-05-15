package main

import (
	"context"
	"flag"
	"log"
	"log/slog"
	"os"
	"strings"
	"time"

	"tap-vxlan-module/pkg/bridge"
	"tap-vxlan-module/pkg/tap"
	"tap-vxlan-module/pkg/transport"
	udptransport "tap-vxlan-module/pkg/transport/udp"
)

func main() {
	var (
		tapName   = flag.String("tap", "", "TAP device name, empty means auto")
		vni       = flag.Uint("vni", 100, "VXLAN VNI")
		listen    = flag.String("listen", ":4789", "local UDP listen address")
		peerCSV   = flag.String("peers", "", "comma-separated peer UDP addresses, for example 10.0.0.2:4789,10.0.0.3:4789")
		frameSize = flag.Int("frame-size", 1600, "TAP frame read buffer size")
	)
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	dev, err := tap.Open(*tapName)
	if err != nil {
		log.Fatalf("open TAP failed: %v", err)
	}
	logger.Info("tap opened", "name", dev.Name())

	conn, err := udptransport.Listen(*listen)
	if err != nil {
		log.Fatalf("listen UDP failed: %v", err)
	}

	peers, err := resolvePeers(context.Background(), *peerCSV)
	if err != nil {
		log.Fatalf("resolve peers failed: %v", err)
	}

	br, err := bridge.New(bridge.Config{
		VNI:       uint32(*vni),
		FrameSize: *frameSize,
		MACAge:    5 * time.Minute,
		Logger:    logger,
	}, dev, conn, peers)
	if err != nil {
		log.Fatalf("create bridge failed: %v", err)
	}

	logger.Info("tap vxlan bridge running", "vni", *vni, "listen", *listen, "peers", len(peers))
	if err := br.Run(context.Background()); err != nil {
		log.Fatalf("bridge stopped: %v", err)
	}
}

func resolvePeers(ctx context.Context, peerCSV string) ([]transport.Endpoint, error) {
	if strings.TrimSpace(peerCSV) == "" {
		return nil, nil
	}
	parts := strings.Split(peerCSV, ",")
	peers := make([]transport.Endpoint, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		peer, err := udptransport.Resolve(ctx, part)
		if err != nil {
			return nil, err
		}
		peers = append(peers, peer)
	}
	return peers, nil
}
