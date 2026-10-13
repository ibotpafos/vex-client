package routing

import (
	"context"
	"errors"
	"io"
	"net"
	"net/netip"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/tun"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun/netstack"
	"golang.org/x/net/dns/dnsmessage"
)

// A packet-only fixture: no OS TUN, network configuration, real sockets or VPN
// services. The real gVisor TCP/UDP frontend and AWG NetTUN are exercised.
type fixtureTUN struct {
	input     chan []byte
	output    chan []byte
	done      chan struct{}
	events    chan tun.Event
	closeOnce sync.Once
}

func newFixtureTUN() *fixtureTUN {
	t := &fixtureTUN{make(chan []byte, 128), make(chan []byte, 128), make(chan struct{}), make(chan tun.Event, 1), sync.Once{}}
	t.events <- tun.EventUp
	return t
}
func (*fixtureTUN) File() *os.File             { return nil }
func (*fixtureTUN) Name() (string, error)      { return "isolated-test", nil }
func (*fixtureTUN) MTU() (int, error)          { return 1360, nil }
func (*fixtureTUN) BatchSize() int             { return 1 }
func (t *fixtureTUN) Events() <-chan tun.Event { return t.events }
func (t *fixtureTUN) Close() error             { t.closeOnce.Do(func() { close(t.done) }); return nil }
func (t *fixtureTUN) Read(bufs [][]byte, sizes []int, offset int) (int, error) {
	if offset < 4 {
		return 0, errors.New("Darwin TUN headroom missing")
	}
	select {
	case p := <-t.input:
		sizes[0] = copy(bufs[0][offset:], p)
		return 1, nil
	case <-t.done:
		return 0, os.ErrClosed
	}
}
func (t *fixtureTUN) Write(bufs [][]byte, offset int) (int, error) {
	if offset < 4 {
		return 0, errors.New("Darwin TUN headroom missing")
	}
	for _, buf := range bufs {
		select {
		case t.output <- append([]byte(nil), buf[offset:]...):
		case <-t.done:
			return 0, os.ErrClosed
		}
	}
	return len(bufs), nil
}

func connectFixture(t *testing.T, router *Router, osTUN *fixtureTUN) *netstack.Net {
	t.Helper()
	clientTUN, client, err := netstack.CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.123.0.2"), netip.MustParseAddr("fd42:123::2")}, nil, 1360)
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		buf := make([]byte, 65536)
		for {
			sizes := []int{0}
			_, err := clientTUN.Read([][]byte{buf}, sizes, 0)
			if err != nil {
				return
			}
			select {
			case osTUN.input <- append([]byte(nil), buf[:sizes[0]]...):
			case <-osTUN.done:
				return
			}
		}
	}()
	go func() {
		for {
			select {
			case p := <-osTUN.output:
				clientTUN.Write([][]byte{p}, 0)
			case <-osTUN.done:
				return
			}
		}
	}()
	// Drain encrypted-path input without a peer. This simulates an unavailable
	// AWG server and establishes that foreign failures cannot choose DIRECT.
	go func() {
		buf := make([]byte, 65536)
		for {
			_, err := router.transport.Read([][]byte{buf}, []int{0}, 0)
			if err != nil {
				return
			}
		}
	}()
	t.Cleanup(func() { router.Close(); clientTUN.Close() })
	return client
}

func TestPacketUDPIPv6QUICAndRetainedCapture(t *testing.T) {
	now := time.Now()
	policy, err := CompilePolicy(testPolicy(now), now)
	if err != nil {
		t.Fatal(err)
	}
	var calls atomic.Int32
	osTUN := newFixtureTUN()
	router, transport, err := Attach(osTUN, Options{Addresses: []netip.Addr{netip.MustParseAddr("10.64.0.2"), netip.MustParseAddr("fd42:64::2")}, DNS: []netip.Addr{netip.MustParseAddr("1.1.1.1")}, Policy: policy,
		PreserveCaptureOnTransportClose: true, DirectDial: func(_ context.Context, protocol, address string) (net.Conn, error) {
			if protocol != "udp" {
				return nil, errors.New("unexpected TCP")
			}
			calls.Add(1)
			client, server := net.Pipe()
			go func() { defer server.Close(); io.Copy(server, server) }()
			return client, nil
		}})
	if err != nil {
		t.Fatal(err)
	}
	client := connectFixture(t, router, osTUN)
	for _, target := range []string{"77.88.8.8:443", "[2a02:6b8::1]:443"} {
		connection, err := client.DialUDPAddrPort(netip.AddrPort{}, netip.MustParseAddrPort(target))
		if err != nil {
			t.Fatal(err)
		}
		connection.SetDeadline(time.Now().Add(5 * time.Second))
		payload := []byte{0xc0, 0, 0, 0, 1, 0, 0} // QUIC is transported as an opaque UDP datagram.
		if _, err := connection.Write(payload); err != nil {
			t.Fatal(err)
		}
		buf := make([]byte, 128)
		if n, err := connection.Read(buf); err != nil || string(buf[:n]) != string(payload) {
			t.Fatalf("UDP %s: %v", target, err)
		}
		connection.Close()
	}
	for _, target := range []string{"104.16.10.10:443", "[2606:4700::1111]:443"} {
		connection, direct, err := router.dial(context.Background(), "udp", netip.MustParseAddrPort(target))
		if err != nil {
			t.Fatal(err)
		}
		if direct {
			t.Fatal("foreign UDP escaped physically")
		}
		connection.Close()
	}
	if calls.Load() != 2 {
		t.Fatalf("unexpected physical calls: %d", calls.Load())
	}
	transport.Close()
	if !router.CaptureActive() {
		t.Fatal("AWG loss released capture")
	}
	connection, direct, err := router.dial(context.Background(), "udp", netip.MustParseAddrPort("77.88.8.8:443"))
	if err != nil || !direct {
		t.Fatalf("retained Russian DIRECT: %v", err)
	}
	connection.Close()
	router.UpdatePolicy(nil)
	if !router.CaptureActive() || router.DirectPolicyActive() {
		t.Fatal("expiry/revocation did not preserve full capture")
	}
	if _, _, err := router.dial(context.Background(), "udp", netip.MustParseAddrPort("198.18.22.22:443")); err == nil {
		t.Fatal("unknown cached FakeIP admitted")
	}
}

func TestControlRecoveryIsLimitedToHTTPSHostnameIdentity(t *testing.T) {
	var queries, physical atomic.Int32
	osTUN := newFixtureTUN()
	router, _, err := Attach(osTUN, Options{Addresses: []netip.Addr{netip.MustParseAddr("10.64.0.2")}, DNS: []netip.Addr{netip.MustParseAddr("1.1.1.1")},
		DirectDial: func(context.Context, string, string) (net.Conn, error) {
			physical.Add(1)
			client, server := net.Pipe()
			go server.Close()
			return client, nil
		}, DirectDNS: func(_ context.Context, query []byte) ([]byte, error) {
			queries.Add(1)
			var message dnsmessage.Message
			message.Unpack(query)
			message.Response = true
			message.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: message.Questions[0].Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 60}, Body: &dnsmessage.AResource{A: [4]byte{104, 16, 10, 10}}}}
			return message.Pack()
		}})
	if err != nil {
		t.Fatal(err)
	}
	connectFixture(t, router, osTUN)
	name, _ := dnsmessage.NewName("vexguard.app.")
	query := dnsmessage.Message{Header: dnsmessage.Header{ID: 1}, Questions: []dnsmessage.Question{{Name: name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}}}
	wire, _ := query.Pack()
	answer, err := router.dnsExchange(wire)
	if err != nil {
		t.Fatal(err)
	}
	var response dnsmessage.Message
	response.Unpack(answer)
	fake := netip.AddrFrom4(response.Answers[0].Body.(*dnsmessage.AResource).A)
	connection, direct, err := router.dial(context.Background(), "tcp", netip.AddrPortFrom(fake, 443))
	if err != nil || !direct {
		t.Fatalf("control recovery: %v", err)
	}
	connection.Close()
	for _, protocol := range []string{"tcp", "udp"} {
		if _, _, err := router.dial(context.Background(), protocol, netip.AddrPortFrom(fake, 22)); err == nil {
			t.Fatal("control exception widened")
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	if _, _, err := router.dial(ctx, "tcp", netip.MustParseAddrPort("104.16.10.10:443")); err == nil {
		t.Fatal("shared IP escaped physically")
	}
	if queries.Load() != 1 || physical.Load() != 1 || controlDomain("evil.vexguard.app") {
		t.Fatal("control scope widened")
	}
}

func TestPacketTCPDirectAndForeignFailureWithoutPhysicalFallback(t *testing.T) {
	now := time.Now()
	policy, _ := CompilePolicy(testPolicy(now), now)
	var mu sync.Mutex
	var targets []string
	osTUN := newFixtureTUN()
	router, _, err := Attach(osTUN, Options{Addresses: []netip.Addr{netip.MustParseAddr("10.64.0.2")}, DNS: []netip.Addr{netip.MustParseAddr("1.1.1.1")}, Policy: policy,
		DirectDial: func(_ context.Context, protocol, address string) (net.Conn, error) {
			mu.Lock()
			targets = append(targets, protocol+"/"+address)
			mu.Unlock()
			client, server := net.Pipe()
			go func() { defer server.Close(); io.Copy(server, server) }()
			return client, nil
		}})
	if err != nil {
		t.Fatal(err)
	}
	client := connectFixture(t, router, osTUN)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	connection, err := client.DialContextTCPAddrPort(ctx, netip.MustParseAddrPort("77.88.8.8:443"))
	if err != nil {
		t.Fatal(err)
	}
	connection.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := connection.Write([]byte("DIRECT")); err != nil {
		t.Fatal(err)
	}
	response := make([]byte, 6)
	if _, err := io.ReadFull(connection, response); err != nil || string(response) != "DIRECT" {
		t.Fatalf("direct forwarding failed: %q %v", response, err)
	}
	connection.Close()
	// Real packet forwarding also protects Russian-domain flows on a foreign CDN.
	fake, err := router.fakes.put("shop.ru", netip.MustParseAddr("104.16.10.10"), time.Now().Add(time.Minute), policy.Version(), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	cdn, err := client.DialContextTCPAddrPort(ctx, netip.AddrPortFrom(fake, 443))
	if err != nil {
		t.Fatal(err)
	}
	cdn.SetDeadline(time.Now().Add(5 * time.Second))
	cdn.Write([]byte("CDN"))
	buf := make([]byte, 3)
	if _, err := io.ReadFull(cdn, buf); err != nil || string(buf) != "CDN" {
		t.Fatalf("domain forwarding failed: %v", err)
	}
	cdn.Close()
	// The same real address, without the Russian DNS identity, stays on AWG.
	foreignCtx, foreignCancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer foreignCancel()
	foreign, _, err := router.dial(foreignCtx, "tcp", netip.MustParseAddrPort("104.16.10.10:443"))
	if err == nil {
		foreign.Close()
		t.Fatal("unavailable AWG unexpectedly connected")
	}
	mu.Lock()
	defer mu.Unlock()
	if len(targets) != 2 || targets[0] != "tcp/77.88.8.8:443" || targets[1] != "tcp/104.16.10.10:443" {
		t.Fatalf("foreign physical fallback: %v", targets)
	}
}

func TestDNSFakeIdentityAndExpiryKeepFullCapture(t *testing.T) {
	now := time.Now()
	policy, _ := CompilePolicy(testPolicy(now), now)
	var directQueries int
	osTUN := newFixtureTUN()
	router, _, err := Attach(osTUN, Options{Addresses: []netip.Addr{netip.MustParseAddr("10.64.0.2")}, DNS: []netip.Addr{netip.MustParseAddr("1.1.1.1")}, Policy: policy,
		DirectDNS: func(_ context.Context, query []byte) ([]byte, error) {
			directQueries++
			var message dnsmessage.Message
			message.Unpack(query)
			message.Response = true
			message.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: message.Questions[0].Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 60}, Body: &dnsmessage.AResource{A: [4]byte{104, 16, 10, 10}}}}
			return message.Pack()
		}})
	if err != nil {
		t.Fatal(err)
	}
	defer router.Close()
	name, _ := dnsmessage.NewName("shop.ru.")
	queryMessage := dnsmessage.Message{Header: dnsmessage.Header{ID: 42, RecursionDesired: true}, Questions: []dnsmessage.Question{{Name: name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}}}
	query, _ := queryMessage.Pack()
	answer, err := router.dnsExchange(query)
	if err != nil {
		t.Fatal(err)
	}
	var response dnsmessage.Message
	response.Unpack(answer)
	fake := netip.AddrFrom4(response.Answers[0].Body.(*dnsmessage.AResource).A)
	if !isFake(fake) || directQueries != 1 {
		t.Fatal("DNS did not retain per-domain identity")
	}
	router.UpdatePolicy(nil)
	if _, _, err := router.dial(context.Background(), "tcp", netip.AddrPortFrom(fake, 443)); err == nil {
		t.Fatal("revoked direct mapping survived")
	}
	select {
	case <-osTUN.done:
		t.Fatal("policy update destroyed capture interface")
	default:
	}
}
