package routing

// Scenario design follows Mullvad's state/DNS test approach. The implementation
// is VEX-specific: real in-memory TCP/IP packets, synthetic peers and observable
// physical callbacks. No host socket, TUN, route, DNS or firewall is changed.

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/netip"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

func TestLeakScenariosPacketsKeepCapture(t *testing.T) {
	for _, state := range []string{"connecting", "transport_failed", "policy_revoked", "policy_expired", "network_changed", "flow_budget_exhausted"} {
		t.Run(state, func(t *testing.T) {
			started := time.Now()
			var clock atomic.Int64
			clock.Store(started.UnixNano())
			policy, err := CompilePolicy(testPolicy(started), started)
			if err != nil {
				t.Fatal(err)
			}
			var physical atomic.Int32
			osTUN := newFixtureTUN()
			router, transport, err := Attach(osTUN, Options{
				Addresses: []netip.Addr{netip.MustParseAddr("10.64.0.2"), netip.MustParseAddr("fd42:64::2")},
				DNS:       []netip.Addr{netip.MustParseAddr("1.1.1.1")}, Policy: policy, MaxFlows: 8,
				PreserveCaptureOnTransportClose: true,
				Now:                             func() time.Time { return time.Unix(0, clock.Load()) },
				DirectDial: func(context.Context, string, string) (net.Conn, error) {
					physical.Add(1)
					client, peer := net.Pipe()
					go func() { defer peer.Close(); io.Copy(peer, peer) }()
					return client, nil
				},
			})
			if err != nil {
				t.Fatal(err)
			}
			client := connectFixture(t, router, osTUN)
			// A positive control proves actual packets reach the observed egress.
			control, err := client.DialUDPAddrPort(netip.AddrPort{}, netip.MustParseAddrPort("77.88.8.8:443"))
			if err != nil {
				t.Fatal(err)
			}
			control.SetDeadline(time.Now().Add(3 * time.Second))
			if _, err = control.Write([]byte("observer-control")); err != nil {
				t.Fatal(err)
			}
			buf := make([]byte, 64)
			if n, err := control.Read(buf); err != nil || string(buf[:n]) != "observer-control" {
				t.Fatalf("physical observer control failed: %v", err)
			}
			control.Close()
			if physical.Load() != 1 {
				t.Fatal("physical observer did not see control")
			}
			switch state {
			case "connecting", "policy_revoked":
				router.UpdatePolicy(nil)
			case "transport_failed":
				transport.Close()
			case "policy_expired":
				clock.Store(started.Add(2 * time.Hour).UnixNano())
			case "network_changed":
				router.UnderlyingNetworkChanged()
			case "flow_budget_exhausted":
				for len(router.flowBudget) < cap(router.flowBudget) {
					router.flowBudget <- struct{}{}
				}
			}
			for _, address := range []string{"203.0.113.20:443", "[2001:db8:123::20]:443"} {
				target := netip.MustParseAddrPort(address)
				udp, err := client.DialUDPAddrPort(netip.AddrPort{}, target)
				if err != nil {
					t.Fatal(err)
				}
				udp.SetDeadline(time.Now().Add(100 * time.Millisecond))
				udp.Write([]byte("foreign-udp"))
				if _, err := udp.Read(buf); err == nil {
					t.Fatal("blocked UDP unexpectedly returned a payload")
				}
				udp.Close()
				ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
				tcp, err := client.DialContextTCPAddrPort(ctx, target)
				cancel()
				if err == nil {
					tcp.SetDeadline(time.Now().Add(100 * time.Millisecond))
					tcp.Write([]byte("foreign-tcp"))
					if _, err := tcp.Read(buf); err == nil {
						t.Fatal("blocked TCP unexpectedly returned a payload")
					}
					tcp.Close()
				}
			}
			if physical.Load() != 1 {
				t.Fatalf("foreign traffic reached physical callback: %d", physical.Load()-1)
			}
			if !router.CaptureActive() {
				t.Fatal("failure released capture")
			}
			select {
			case <-osTUN.done:
				t.Fatal("failure closed the OS capture interface")
			default:
			}
			router.Close() // Explicit disconnect is the only release in this scenario.
			if router.CaptureActive() {
				t.Fatal("explicit disconnect retained a live capture")
			}
		})
	}
}

func TestLeakScenariosDNSNoPhysicalFallback(t *testing.T) {
	for _, scenario := range []struct{ family, protocol string }{{"ipv4", "udp"}, {"ipv6", "udp"}, {"ipv4", "tcp"}, {"ipv6", "tcp"}} {
		t.Run(scenario.family+"/"+scenario.protocol, func(t *testing.T) {
			now := time.Now()
			policy, _ := CompilePolicy(testPolicy(now), now)
			var physicalDNS atomic.Int32
			osTUN := newFixtureTUN()
			router, transport, err := Attach(osTUN, Options{
				Addresses: []netip.Addr{netip.MustParseAddr("10.64.0.2"), netip.MustParseAddr("fd42:64::2")},
				DNS:       []netip.Addr{netip.MustParseAddr("1.1.1.1")}, Policy: policy, PreserveCaptureOnTransportClose: true,
				DirectDNS: func(_ context.Context, query []byte) ([]byte, error) {
					physicalDNS.Add(1)
					var message dnsmessage.Message
					if err := message.Unpack(query); err != nil {
						return nil, err
					}
					message.Response = true
					body := dnsmessage.ResourceBody(&dnsmessage.AResource{A: [4]byte{77, 88, 8, 8}})
					if message.Questions[0].Type == dnsmessage.TypeAAAA {
						body = &dnsmessage.AAAAResource{AAAA: netip.MustParseAddr("2a02:6b8::1").As16()}
					}
					message.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: message.Questions[0].Name,
						Type: message.Questions[0].Type, Class: dnsmessage.ClassINET, TTL: 60}, Body: body}}
					return message.Pack()
				},
			})
			if err != nil {
				t.Fatal(err)
			}
			client := connectFixture(t, router, osTUN)
			destination, queryType := "1.1.1.1:53", dnsmessage.TypeA
			if scenario.family == "ipv6" {
				destination, queryType = "[2606:4700:4700::1111]:53", dnsmessage.TypeAAAA
			}
			exchange := func(domain string, wantAnswer bool) {
				t.Helper()
				name, _ := dnsmessage.NewName(domain)
				query, err := (&dnsmessage.Message{Header: dnsmessage.Header{ID: 42}, Questions: []dnsmessage.Question{
					{Name: name, Type: queryType, Class: dnsmessage.ClassINET}}}).Pack()
				if err != nil {
					t.Fatal(err)
				}
				var conn net.Conn
				if scenario.protocol == "udp" {
					conn, err = client.DialUDPAddrPort(netip.AddrPort{}, netip.MustParseAddrPort(destination))
				} else {
					ctx, cancel := context.WithTimeout(context.Background(), time.Second)
					conn, err = client.DialContextTCPAddrPort(ctx, netip.MustParseAddrPort(destination))
					cancel()
				}
				if err != nil {
					t.Fatal(err)
				}
				defer conn.Close()
				deadline := 150 * time.Millisecond
				if wantAnswer {
					deadline = 3 * time.Second
				}
				conn.SetDeadline(time.Now().Add(deadline))
				wire := query
				if scenario.protocol == "tcp" {
					wire = make([]byte, len(query)+2)
					binary.BigEndian.PutUint16(wire, uint16(len(query)))
					copy(wire[2:], query)
				}
				if _, err := conn.Write(wire); err != nil {
					t.Fatal(err)
				}
				buf := make([]byte, 2048)
				n := 0
				if scenario.protocol == "udp" {
					n, err = conn.Read(buf)
				} else {
					var length [2]byte
					_, err = io.ReadFull(conn, length[:])
					if err == nil {
						n = int(binary.BigEndian.Uint16(length[:]))
						if n > len(buf) {
							t.Fatal("oversized fixture DNS answer")
						}
						_, err = io.ReadFull(conn, buf[:n])
					}
				}
				if wantAnswer {
					var message dnsmessage.Message
					if err != nil || message.Unpack(buf[:n]) != nil || len(message.Answers) != 1 {
						t.Fatalf("DNS observer control failed: %v", err)
					}
				} else if err == nil {
					var message dnsmessage.Message
					if message.Unpack(buf[:n]) != nil || message.RCode != dnsmessage.RCodeServerFailure || len(message.Answers) != 0 {
						t.Fatal("blocked DNS returned a successful or malformed answer")
					}
				}
			}
			exchange("shop.ru.", true)
			if physicalDNS.Load() != 1 {
				t.Fatal("DNS observer control was not observed")
			}
			transport.Close()
			exchange("foreign.example.", false)
			router.UpdatePolicy(nil)
			exchange("shop.ru.", false)
			if physicalDNS.Load() != 1 || !router.CaptureActive() {
				t.Fatal("DNS escaped or capture was released")
			}
		})
	}
}

func TestLeakScenarioUnderlayChangeClosesExistingPhysicalFlow(t *testing.T) {
	now := time.Now()
	policy, _ := CompilePolicy(testPolicy(now), now)
	var peer net.Conn
	router, _, err := Attach(newFixtureTUN(), Options{
		Addresses: []netip.Addr{netip.MustParseAddr("10.64.0.2")}, DNS: []netip.Addr{netip.MustParseAddr("1.1.1.1")}, Policy: policy,
		DirectDial: func(context.Context, string, string) (net.Conn, error) {
			var conn net.Conn
			conn, peer = net.Pipe()
			return conn, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer router.Close()
	conn, direct, err := router.dial(context.Background(), "tcp", netip.MustParseAddrPort("77.88.8.8:443"))
	if err != nil || !direct {
		t.Fatalf("control dial: %v", err)
	}
	defer conn.Close()
	defer peer.Close()
	router.UnderlyingNetworkChanged()
	peer.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := peer.Read(make([]byte, 1)); !errors.Is(err, io.EOF) {
		t.Fatalf("old physical socket survived underlay change: %v", err)
	}
	if !router.CaptureActive() {
		t.Fatal("underlay change released capture")
	}
}
