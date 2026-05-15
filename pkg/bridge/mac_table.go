package bridge

import (
	"net"
	"sync"
	"time"
)

type macEntry struct {
	endpoint net.Addr
	seenAt   time.Time
}

type MACTable struct {
	mu      sync.RWMutex
	ttl     time.Duration
	entries map[string]macEntry
}

func NewMACTable(ttl time.Duration) *MACTable {
	if ttl <= 0 {
		ttl = 5 * time.Minute
	}
	return &MACTable{
		ttl:     ttl,
		entries: make(map[string]macEntry),
	}
}

func (m *MACTable) Learn(mac net.HardwareAddr, endpoint net.Addr) {
	if len(mac) != 6 || endpoint == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.entries[string(mac)] = macEntry{endpoint: endpoint, seenAt: time.Now()}
}

func (m *MACTable) Lookup(mac net.HardwareAddr) (net.Addr, bool) {
	if len(mac) != 6 {
		return nil, false
	}
	m.mu.RLock()
	entry, ok := m.entries[string(mac)]
	m.mu.RUnlock()
	if !ok || time.Since(entry.seenAt) > m.ttl {
		if ok {
			m.Delete(mac)
		}
		return nil, false
	}
	return entry.endpoint, true
}

func (m *MACTable) Delete(mac net.HardwareAddr) {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.entries, string(mac))
}

func (m *MACTable) Sweep() {
	now := time.Now()
	m.mu.Lock()
	defer m.mu.Unlock()
	for mac, entry := range m.entries {
		if now.Sub(entry.seenAt) > m.ttl {
			delete(m.entries, mac)
		}
	}
}
