package vxlan

import (
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	HeaderLen = 8
	IFlag     = 0x08
	MaxVNI    = 0xFFFFFF
)

var (
	ErrPacketTooShort = errors.New("vxlan packet too short")
	ErrInvalidIFlag   = errors.New("vxlan I flag is not set")
	ErrInvalidVNI     = errors.New("vxlan VNI must be in range 0..16777215")
)

func Encapsulate(vni uint32, ethernetFrame []byte) ([]byte, error) {
	if vni > MaxVNI {
		return nil, ErrInvalidVNI
	}
	packet := make([]byte, HeaderLen+len(ethernetFrame))
	packet[0] = IFlag
	packet[4] = byte(vni >> 16)
	packet[5] = byte(vni >> 8)
	packet[6] = byte(vni)
	copy(packet[HeaderLen:], ethernetFrame)
	return packet, nil
}

func Decapsulate(packet []byte) (uint32, []byte, error) {
	if len(packet) < HeaderLen {
		return 0, nil, fmt.Errorf("%w: %d", ErrPacketTooShort, len(packet))
	}
	if packet[0]&IFlag == 0 {
		return 0, nil, ErrInvalidIFlag
	}
	vni := uint32(packet[4])<<16 | uint32(packet[5])<<8 | uint32(packet[6])
	frame := packet[HeaderLen:]
	return vni, frame, nil
}

func PutVNI(dst []byte, vni uint32) error {
	if len(dst) < HeaderLen {
		return ErrPacketTooShort
	}
	if vni > MaxVNI {
		return ErrInvalidVNI
	}
	binary.BigEndian.PutUint32(dst[0:4], uint32(IFlag)<<24)
	dst[4] = byte(vni >> 16)
	dst[5] = byte(vni >> 8)
	dst[6] = byte(vni)
	dst[7] = 0
	return nil
}
