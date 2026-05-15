package l2

import "net"

const (
	EthernetHeaderLen = 14
	DefaultMTU        = 1280
	DefaultFrameSize  = 1600
)

func DestinationMAC(frame []byte) (net.HardwareAddr, bool) {
	if len(frame) < EthernetHeaderLen {
		return nil, false
	}
	mac := make(net.HardwareAddr, 6)
	copy(mac, frame[0:6])
	return mac, true
}

func SourceMAC(frame []byte) (net.HardwareAddr, bool) {
	if len(frame) < EthernetHeaderLen {
		return nil, false
	}
	mac := make(net.HardwareAddr, 6)
	copy(mac, frame[6:12])
	return mac, true
}

func IsBroadcast(mac net.HardwareAddr) bool {
	return len(mac) == 6 &&
		mac[0] == 0xff &&
		mac[1] == 0xff &&
		mac[2] == 0xff &&
		mac[3] == 0xff &&
		mac[4] == 0xff &&
		mac[5] == 0xff
}

func IsMulticast(mac net.HardwareAddr) bool {
	return len(mac) == 6 && mac[0]&0x01 == 0x01
}
