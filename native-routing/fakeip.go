package routing

import (
	"encoding/binary"
	"errors"
	"net/netip"
	"sync"
	"time"
)

const maxFakeMappings = 8192
const controlMappingVersion = "vex-control/v1"

// Android retains application/OS DNS answers while a new AWG peer replaces its
// router. Reuse hostname identities for the process lifetime, so a cached fake
// address cannot disappear or become a different origin after that replacement.
// Only mappings are shared: each router still checks its current policy,
// expiry, control TCP/443 restriction and qualified physical network.
var androidFakeMappings = newFakeTable()

func fakeTableForPlatform(platform string) *fakeTable {
	if platform == "android" {
		return androidFakeMappings
	}
	return newFakeTable()
}

// These are the first-party recovery origins, provisioned by the distribution.
// A hostname identity grants only TCP/443; its shared real IP is never allowed.
func controlDomain(name string) bool { return name == "vexguard.app" || name == "www.vexguard.app" }

var fakeV4 = netip.MustParsePrefix("198.18.0.0/15")
var fakeV6 = netip.MustParsePrefix("fd7a:115c:a1e0::/96")

type fakeMapping struct {
	name    string
	actual  netip.Addr
	expires time.Time
	version string
}

// Fake addresses identify a hostname, not an entire real CDN address. IDs are
// never reassigned during a tunnel lifetime: stale application DNS caches
// cannot authorize a different domain through an old fake address.
type fakeTable struct {
	mu    sync.Mutex
	next  uint32
	byIP  map[netip.Addr]fakeMapping
	byKey map[string]netip.Addr
}

func newFakeTable() *fakeTable {
	return &fakeTable{next: 1, byIP: make(map[netip.Addr]fakeMapping), byKey: make(map[string]netip.Addr)}
}

func (f *fakeTable) put(name string, actual netip.Addr, expires time.Time, version string, now time.Time) (netip.Addr, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	key := name + "/" + actual.String() + "/" + version
	if old, ok := f.byKey[key]; ok {
		f.byIP[old] = fakeMapping{name, actual, expires, version}
		return old, nil
	}
	if len(f.byIP) >= maxFakeMappings {
		for ip, mapping := range f.byIP {
			if !now.Before(mapping.expires) {
				delete(f.byIP, ip)
				delete(f.byKey, mapping.name+"/"+mapping.actual.String()+"/"+mapping.version)
			}
		}
	}
	if len(f.byIP) >= maxFakeMappings {
		return netip.Addr{}, errors.New("routing DNS mapping limit")
	}
	id := f.next
	// Reclaimed entries free memory, never identities. Refuse exhaustion rather
	// than leave the reserved range or assign an old application's IP again.
	if id == 0 || (actual.Is4() && id >= 1<<17) {
		return netip.Addr{}, errors.New("routing DNS identity space exhausted")
	}
	f.next++
	var ip netip.Addr
	if actual.Is4() {
		ip = netip.AddrFrom4([4]byte{198, byte(18 + id/65536), byte(id >> 8), byte(id)})
	} else {
		v6 := fakeV6.Addr().As16()
		binary.BigEndian.PutUint32(v6[12:], id)
		ip = netip.AddrFrom16(v6)
	}
	f.byIP[ip] = fakeMapping{name, actual, expires, version}
	f.byKey[key] = ip
	return ip, nil
}

func (f *fakeTable) get(ip netip.Addr, policy *CompiledPolicy, now time.Time) (netip.Addr, bool) {
	f.mu.Lock()
	mapping, ok := f.byIP[ip]
	f.mu.Unlock()
	if !ok || !now.Before(mapping.expires) {
		return netip.Addr{}, false
	}
	if mapping.version == controlMappingVersion && controlDomain(mapping.name) {
		return mapping.actual, publicDestination(mapping.actual)
	}
	if !policy.valid(now) || mapping.version != policy.Version() || !policy.DirectDomain(mapping.name, now) {
		return netip.Addr{}, false
	}
	return mapping.actual, publicDestination(mapping.actual)
}

func (f *fakeTable) isControl(ip netip.Addr) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	mapping, ok := f.byIP[ip]
	return ok && mapping.version == controlMappingVersion && controlDomain(mapping.name)
}

func isFake(ip netip.Addr) bool { return fakeV4.Contains(ip) || fakeV6.Contains(ip) }
