package routing

import (
	"context"
	"net"
	"net/netip"
	"strings"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

func TestControlDomainExactAllowlist(t *testing.T) {
	for _, host := range []string{"vexguard.app", "www.vexguard.app", "api.vexguard.app", "api2.vexguard.app"} {
		if !controlDomain(host) {
			t.Errorf("control host rejected: %s", host)
		}
	}
	for _, host := range []string{"", "api3.vexguard.app", "evil.vexguard.app", "evil.api.vexguard.app", "api.vexguard.app.evil.test", "api2.vexguard.app.evil.test", "api-vexguard.app", "api.vexguard.app:443", "104.16.10.10"} {
		if controlDomain(host) {
			t.Errorf("untrusted host admitted: %s", host)
		}
	}
}

// Exercise DNS classification and dialing directly with in-memory callbacks:
// no TUN, OS configuration, resolver, listener or physical socket is created.
func TestAPIControlHTTPSIndependentOfPolicyAndTransport(t *testing.T) {
	now := time.Now().UTC()
	policy, err := CompilePolicy(testPolicy(now), now)
	if err != nil {
		t.Fatal(err)
	}
	for _, state := range []string{"missing", "active", "expired", "stopped"} {
		for _, host := range []string{"api.vexguard.app", "api2.vexguard.app"} {
			for _, actual := range []netip.Addr{netip.MustParseAddr("104.16.10.10"), netip.MustParseAddr("2606:4700::1111")} {
				t.Run(state+"/"+host+"/"+actual.String(), func(t *testing.T) {
					clock := now
					if state == "expired" {
						clock = policy.ExpiresAt().Add(time.Second)
					}
					calls, queries := 0, 0
					r := &Router{ctx: context.Background(), now: func() time.Time { return clock }, fakes: newFakeTable(), directConnections: make(map[net.Conn]struct{})}
					if state == "active" || state == "expired" {
						r.policy.Store(policy)
					}
					// "stopped" models retained capture after transport loss.
					r.transportStopped.Store(state == "stopped")
					r.direct = func(_ context.Context, protocol, address string) (net.Conn, error) {
						calls++
						if protocol != "tcp" || address != netip.AddrPortFrom(actual, 443).String() {
							t.Fatalf("unexpected DIRECT target: %s %s", protocol, address)
						}
						client, peer := net.Pipe()
						peer.Close()
						return client, nil
					}
					r.directDNS = func(_ context.Context, wire []byte) ([]byte, error) {
						queries++
						var message dnsmessage.Message
						if err := message.Unpack(wire); err != nil {
							return nil, err
						}
						message.Response = true
						var body dnsmessage.ResourceBody = &dnsmessage.AAAAResource{AAAA: actual.As16()}
						if actual.Is4() {
							body = &dnsmessage.AResource{A: actual.As4()}
						}
						message.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: message.Questions[0].Name, Type: message.Questions[0].Type, Class: dnsmessage.ClassINET, TTL: 60}, Body: body}}
						return message.Pack()
					}
					name, err := dnsmessage.NewName(strings.ToUpper(host) + ".")
					if err != nil {
						t.Fatal(err)
					}
					kind := dnsmessage.TypeAAAA
					if actual.Is4() {
						kind = dnsmessage.TypeA
					}
					query := dnsmessage.Message{Questions: []dnsmessage.Question{{Name: name, Type: kind, Class: dnsmessage.ClassINET}}}
					wire, err := query.Pack()
					if err != nil {
						t.Fatal(err)
					}
					answer, err := r.dnsExchange(wire)
					if err != nil {
						t.Fatal(err)
					}
					var response dnsmessage.Message
					if err := response.Unpack(answer); err != nil || len(response.Answers) != 1 {
						t.Fatalf("invalid DNS answer: %v", err)
					}
					var fake netip.Addr
					switch body := response.Answers[0].Body.(type) {
					case *dnsmessage.AResource:
						fake = netip.AddrFrom4(body.A)
					case *dnsmessage.AAAAResource:
						fake = netip.AddrFrom16(body.AAAA)
					}
					if !isFake(fake) || !r.fakes.isControl(fake) {
						t.Fatal("API DNS lost hostname identity")
					}
					conn, direct, err := r.dial(r.ctx, "tcp", netip.AddrPortFrom(fake, 443))
					if err != nil || !direct {
						t.Fatalf("API HTTPS not DIRECT: %v", err)
					}
					r.releaseConnection(conn, direct)
					for _, blocked := range []struct {
						protocol string
						port     uint16
					}{{"tcp", 80}, {"tcp", 22}, {"udp", 443}} {
						if _, _, err := r.dial(r.ctx, blocked.protocol, netip.AddrPortFrom(fake, blocked.port)); err == nil {
							t.Errorf("control exception admitted %s/%d", blocked.protocol, blocked.port)
						}
					}
					// Stopping only this in-memory flag lets shared-IP rejection
					// be checked without attempting any encrypted connection.
					r.transportStopped.Store(true)
					if _, direct, err := r.dial(r.ctx, "tcp", netip.AddrPortFrom(actual, 443)); err == nil || direct {
						t.Fatal("shared real IP inherited control trust")
					}
					clock = clock.Add(time.Minute)
					if _, _, err := r.dial(r.ctx, "tcp", netip.AddrPortFrom(fake, 443)); err == nil {
						t.Fatal("expired control identity admitted")
					}
					if calls != 1 || queries != 1 {
						t.Fatalf("unexpected physical callbacks: dial=%d DNS=%d", calls, queries)
					}
				})
			}
		}
	}
}
