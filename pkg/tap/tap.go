package tap

import "github.com/songgao/water"

type Device interface {
	Read([]byte) (int, error)
	Write([]byte) (int, error)
	Name() string
}

func Open(name string) (Device, error) {
	cfg := water.Config{DeviceType: water.TAP}
	if name != "" {
		cfg.Name = name
	}
	return water.New(cfg)
}
