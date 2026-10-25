package routing

import (
	"context"
	"errors"
	"io"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

func TestLeakScenarioPendingPhysicalDialCannotSurviveTransition(t *testing.T) {
	for _, targetKind := range []string{"ipv4", "ipv6", "domain", "control"} {
		for _, protocol := range []string{"tcp", "udp"} {
			if targetKind == "control" && protocol != "tcp" {
				continue // Recovery identity permits TCP/443 only.
			}
			for _, transition := range []string{"underlay", "disconnect"} {
				t.Run(targetKind+"/"+protocol+"/"+transition, func(t *testing.T) {
					now := time.Now()
					policy, err := CompilePolicy(testPolicy(now), now)
					if err != nil {
						t.Fatal(err)
					}
					late, peer := net.Pipe()
					t.Cleanup(func() { late.Close(); peer.Close() })
					started, release := make(chan struct{}), make(chan struct{})
					var releaseOnce sync.Once
					unblock := func() { releaseOnce.Do(func() { close(release) }) }
					t.Cleanup(unblock)
					router, _, err := Attach(newFixtureTUN(), Options{
						Addresses: []netip.Addr{netip.MustParseAddr("10.64.0.2")}, DNS: []netip.Addr{netip.MustParseAddr("1.1.1.1")}, Policy: policy,
						DirectDial: func(context.Context, string, string) (net.Conn, error) {
							close(started)
							<-release // Model a late callback even if cancellation is ignored.
							return late, nil
						},
					})
					if err != nil {
						t.Fatal(err)
					}
					t.Cleanup(func() { router.Close() })
					ip := netip.MustParseAddr("77.88.8.8")
					if targetKind == "ipv6" {
						ip = netip.MustParseAddr("2a02:6b8::1")
					} else if targetKind == "domain" || targetKind == "control" {
						name, version := "shop.ru", policy.Version()
						if targetKind == "control" {
							name, version = "vexguard.app", controlMappingVersion
						}
						ip, err = router.fakes.put(name, netip.MustParseAddr("104.16.10.10"), now.Add(time.Minute), version, now)
						if err != nil {
							t.Fatal(err)
						}
					}
					type result struct {
						conn   net.Conn
						direct bool
						err    error
					}
					done := make(chan result, 1)
					ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
					defer cancel()
					go func() {
						conn, direct, err := router.dial(ctx, protocol, netip.AddrPortFrom(ip, 443))
						done <- result{conn, direct, err}
					}()
					select {
					case <-started: // Positive observation: the pending DIRECT dial exists.
					case <-ctx.Done():
						t.Fatal("physical callback was not reached")
					}
					if transition == "underlay" {
						router.UnderlyingNetworkChanged()
					} else {
						router.Close()
					}
					unblock()
					select {
					case got := <-done:
						if got.err == nil || got.conn != nil || !got.direct {
							t.Error("late physical connection was admitted after transition")
							if got.conn != nil {
								got.conn.Close()
							}
						}
					case <-ctx.Done():
						t.Fatal("late dial did not finish")
					}
					peer.SetReadDeadline(time.Now().Add(time.Second))
					if _, err := peer.Read(make([]byte, 1)); !errors.Is(err, io.EOF) {
						t.Fatalf("rejected physical socket stayed open: %v", err)
					}
					if router.CaptureActive() != (transition == "underlay") {
						t.Fatal("transition changed capture ownership")
					}
				})
			}
		}
	}
}

func TestLeakScenarioLateDNSAnswerCannotSurviveTransition(t *testing.T) {
	for _, domain := range []string{"shop.ru.", "vexguard.app."} {
		for _, kind := range []dnsmessage.Type{dnsmessage.TypeA, dnsmessage.TypeAAAA} {
			for _, transition := range []string{"underlay", "disconnect"} {
				t.Run(domain+kind.String()+"/"+transition, func(t *testing.T) {
					now := time.Now()
					policy, err := CompilePolicy(testPolicy(now), now)
					if err != nil {
						t.Fatal(err)
					}
					started, release := make(chan struct{}), make(chan struct{})
					var releaseOnce sync.Once
					unblock := func() { releaseOnce.Do(func() { close(release) }) }
					t.Cleanup(unblock)
					router, _, err := Attach(newFixtureTUN(), Options{
						Addresses: []netip.Addr{netip.MustParseAddr("10.64.0.2")}, DNS: []netip.Addr{netip.MustParseAddr("1.1.1.1")}, Policy: policy,
						DirectDNS: func(_ context.Context, query []byte) ([]byte, error) {
							close(started)
							<-release
							var message dnsmessage.Message
							if err := message.Unpack(query); err != nil {
								return nil, err
							}
							message.Response = true
							var body dnsmessage.ResourceBody = &dnsmessage.AResource{A: [4]byte{104, 16, 10, 10}}
							if kind == dnsmessage.TypeAAAA {
								body = &dnsmessage.AAAAResource{AAAA: netip.MustParseAddr("2606:4700::1").As16()}
							}
							message.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: message.Questions[0].Name, Type: kind, Class: dnsmessage.ClassINET, TTL: 60}, Body: body}}
							return message.Pack()
						},
					})
					if err != nil {
						t.Fatal(err)
					}
					t.Cleanup(func() { router.Close() })
					name, _ := dnsmessage.NewName(domain)
					query, err := (&dnsmessage.Message{Header: dnsmessage.Header{ID: 42}, Questions: []dnsmessage.Question{{Name: name, Type: kind, Class: dnsmessage.ClassINET}}}).Pack()
					if err != nil {
						t.Fatal(err)
					}
					done := make(chan error, 1)
					go func() { _, err := router.dnsExchange(query); done <- err }()
					select {
					case <-started:
					case <-time.After(3 * time.Second):
						t.Fatal("physical DNS callback was not reached")
					}
					if transition == "underlay" {
						router.UnderlyingNetworkChanged()
					} else {
						router.Close()
					}
					unblock()
					select {
					case err := <-done:
						if err == nil {
							t.Error("stale physical DNS answer was admitted")
						}
					case <-time.After(3 * time.Second):
						t.Fatal("late DNS did not finish")
					}
				})
			}
		}
	}
}

func TestLeakScenarioNetworkChangeCancelsPendingPhysicalWork(t *testing.T) {
	for _, operation := range []string{"dial", "dns"} {
		for _, transition := range []string{"underlay", "disconnect", "caller_cancel"} {
			if operation == "dns" && transition == "caller_cancel" {
				continue
			}
			t.Run(operation+"/"+transition, func(t *testing.T) {
				now := time.Now()
				policy, err := CompilePolicy(testPolicy(now), now)
				if err != nil {
					t.Fatal(err)
				}
				started := make(chan context.Context, 1)
				block := func(ctx context.Context) error {
					started <- ctx
					<-ctx.Done()
					return ctx.Err()
				}
				router, _, err := Attach(newFixtureTUN(), Options{
					Addresses: []netip.Addr{netip.MustParseAddr("10.64.0.2")}, DNS: []netip.Addr{netip.MustParseAddr("1.1.1.1")}, Policy: policy,
					DirectDial: func(ctx context.Context, _, _ string) (net.Conn, error) { return nil, block(ctx) },
					DirectDNS:  func(ctx context.Context, _ []byte) ([]byte, error) { return nil, block(ctx) },
				})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { router.Close() })
				ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
				defer cancel()
				done := make(chan error, 1)
				query := transitionDNSQuery(t, "shop.ru.")
				go func() {
					if operation == "dial" {
						_, _, err := router.dial(ctx, "tcp", netip.MustParseAddrPort("77.88.8.8:443"))
						done <- err
					} else {
						_, err := router.dnsExchange(query)
						done <- err
					}
				}()
				var physical context.Context
				select {
				case physical = <-started:
				case <-time.After(3 * time.Second):
					t.Fatal("pending operation did not start")
				}
				if operation == "dial" {
					if deadline, ok := physical.Deadline(); !ok || time.Until(deadline) > 10*time.Second {
						t.Fatal("caller deadline was lost")
					}
				}
				switch transition {
				case "underlay":
					router.UnderlyingNetworkChanged()
				case "disconnect":
					router.Close()
				case "caller_cancel":
					cancel()
				}
				select {
				case <-physical.Done():
				case <-time.After(3 * time.Second):
					t.Fatal("retired physical work was not canceled promptly")
				}
				select {
				case err := <-done:
					if err == nil {
						t.Fatal("canceled operation succeeded")
					}
				case <-time.After(3 * time.Second):
					t.Fatal("canceled operation stayed blocked")
				}
				if router.CaptureActive() != (transition != "disconnect") {
					t.Fatal("cancellation released capture")
				}
			})
		}
	}
}

func transitionDNSQuery(t *testing.T, domain string) []byte {
	t.Helper()
	name, _ := dnsmessage.NewName(domain)
	wire, err := (&dnsmessage.Message{Header: dnsmessage.Header{ID: 42}, Questions: []dnsmessage.Question{{Name: name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}}}).Pack()
	if err != nil {
		t.Fatal(err)
	}
	return wire
}

func TestLeakScenarioFreshNetworkRemainsUsable(t *testing.T) {
	now := time.Now()
	policy, err := CompilePolicy(testPolicy(now), now)
	if err != nil {
		t.Fatal(err)
	}
	router, _, err := Attach(newFixtureTUN(), Options{
		Addresses: []netip.Addr{netip.MustParseAddr("10.64.0.2")}, DNS: []netip.Addr{netip.MustParseAddr("1.1.1.1")}, Policy: policy,
		DirectDial: func(context.Context, string, string) (net.Conn, error) {
			conn, peer := net.Pipe()
			go func() { defer peer.Close(); io.Copy(peer, peer) }()
			return conn, nil
		},
		DirectDNS: func(_ context.Context, query []byte) ([]byte, error) {
			var response dnsmessage.Message
			if err := response.Unpack(query); err != nil {
				return nil, err
			}
			response.Response = true
			response.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: response.Questions[0].Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 60}, Body: &dnsmessage.AResource{A: [4]byte{104, 16, 10, 10}}}}
			return response.Pack()
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer router.Close()
	var controlIP netip.Addr
	for i := 0; i < 3; i++ {
		if i > 0 {
			router.UnderlyingNetworkChanged()
		}
		for _, protocol := range []string{"tcp", "udp"} {
			conn, direct, err := router.dial(context.Background(), protocol, netip.MustParseAddrPort("77.88.8.8:443"))
			if err != nil || !direct {
				t.Fatalf("fresh %s physical dial: %v", protocol, err)
			}
			conn.SetDeadline(time.Now().Add(3 * time.Second))
			_, writeErr := conn.Write([]byte("control"))
			buf := make([]byte, 7)
			_, readErr := io.ReadFull(conn, buf)
			router.releaseConnection(conn, direct)
			if writeErr != nil || readErr != nil || string(buf) != "control" {
				t.Fatal("fresh physical echo did not work")
			}
		}
		for _, domain := range []string{"shop.ru.", "vexguard.app."} {
			answer, err := router.dnsExchange(transitionDNSQuery(t, domain))
			var response dnsmessage.Message
			if err != nil || response.Unpack(answer) != nil || len(response.Answers) != 1 {
				t.Fatalf("fresh DNS did not work: %v", err)
			}
			if domain == "vexguard.app." {
				controlIP = netip.AddrFrom4(response.Answers[0].Body.(*dnsmessage.AResource).A)
			}
		}
	}
	router.Close()
	if conn, _, err := router.dial(context.Background(), "tcp", netip.MustParseAddrPort("77.88.8.8:443")); err == nil || conn != nil {
		t.Fatal("closed router started physical work")
	}
	if _, err := router.dnsExchange(transitionDNSQuery(t, "shop.ru.")); err == nil {
		t.Fatal("closed router accepted DNS")
	}
	if conn, _, err := router.dial(context.Background(), "tcp", netip.AddrPortFrom(controlIP, 443)); err == nil || conn != nil {
		if conn != nil {
			conn.Close()
		}
		t.Fatal("closed router started recovery socket")
	}
	if _, err := router.dnsExchange(transitionDNSQuery(t, "vexguard.app.")); err == nil {
		t.Fatal("closed router accepted recovery DNS")
	}
}

func TestLeakScenarioPolicyRefreshFollowsNetworkChanges(t *testing.T) {
	for _, state := range []string{"pending", "backoff"} {
		t.Run(state, func(t *testing.T) {
			started := make(chan context.Context, 2)
			first := true
			router, _, err := Attach(newFixtureTUN(), Options{
				Addresses: []netip.Addr{netip.MustParseAddr("10.64.0.2")}, DNS: []netip.Addr{netip.MustParseAddr("1.1.1.1")}, Mode: "all_except_ru",
				PolicySource: func(ctx context.Context) (Authorization, error) {
					started <- ctx
					if !first || state == "pending" {
						<-ctx.Done()
					}
					first = false
					return Authorization{}, errors.New("isolated unavailable source")
				},
			})
			if err != nil {
				t.Fatal(err)
			}
			defer router.Close()
			next := func() context.Context {
				t.Helper()
				select {
				case ctx := <-started:
					return ctx
				case <-time.After(3 * time.Second):
					t.Fatal("refresh did not start on current network")
					return nil
				}
			}
			old := next()
			if state == "backoff" {
				select {
				case <-old.Done():
				case <-time.After(3 * time.Second):
					t.Fatal("failed refresh did not enter backoff")
				}
			}
			router.UnderlyingNetworkChanged()
			select {
			case <-old.Done():
			case <-time.After(3 * time.Second):
				t.Fatal("old refresh was not canceled")
			}
			fresh := next()
			if fresh.Err() != nil || !router.CaptureActive() {
				t.Fatal("new refresh inherited retired network")
			}
			router.Close()
			select {
			case <-fresh.Done():
			case <-time.After(3 * time.Second):
				t.Fatal("disconnect left refresh running")
			}
		})
	}
}

func TestLeakScenarioPendingPacketsStayOffRetiredNetwork(t *testing.T) {
	for _, protocol := range []string{"tcp", "udp"} {
		t.Run(protocol, func(t *testing.T) {
			now := time.Now()
			policy, err := CompilePolicy(testPolicy(now), now)
			if err != nil {
				t.Fatal(err)
			}
			started, release := make(chan struct{}), make(chan struct{})
			var once sync.Once
			unblock := func() { once.Do(func() { close(release) }) }
			var calls, stalePayloads atomic.Int32
			osTUN := newFixtureTUN()
			router, _, err := Attach(osTUN, Options{
				Addresses: []netip.Addr{netip.MustParseAddr("10.64.0.2")}, DNS: []netip.Addr{netip.MustParseAddr("1.1.1.1")}, Policy: policy,
				DirectDial: func(context.Context, string, string) (net.Conn, error) {
					first := calls.Add(1) == 1
					conn, peer := net.Pipe()
					go func() {
						defer peer.Close()
						buf := make([]byte, 128)
						for {
							n, err := peer.Read(buf)
							if err != nil {
								return
							}
							if first {
								stalePayloads.Add(1)
							}
							if _, err := peer.Write(buf[:n]); err != nil {
								return
							}
						}
					}()
					if first {
						close(started)
						<-release
					}
					return conn, nil
				},
			})
			if err != nil {
				t.Fatal(err)
			}
			client := connectFixture(t, router, osTUN)
			t.Cleanup(unblock)
			open := func(port uint16) net.Conn {
				t.Helper()
				target := netip.AddrPortFrom(netip.MustParseAddr("77.88.8.8"), port)
				if protocol == "udp" {
					conn, err := client.DialUDPAddrPort(netip.AddrPort{}, target)
					if err != nil {
						t.Fatal(err)
					}
					return conn
				}
				ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
				defer cancel()
				conn, err := client.DialContextTCPAddrPort(ctx, target)
				if err != nil {
					t.Fatal(err)
				}
				return conn
			}
			old := open(443)
			defer old.Close()
			old.SetDeadline(time.Now().Add(3 * time.Second))
			if _, err := old.Write([]byte("stale")); err != nil {
				t.Fatal(err)
			}
			select {
			case <-started:
			case <-time.After(3 * time.Second):
				t.Fatal("packet did not start physical dial")
			}
			router.UnderlyingNetworkChanged()
			unblock()
			old.SetReadDeadline(time.Now().Add(150 * time.Millisecond))
			buf := make([]byte, 128)
			if _, err := old.Read(buf); err == nil {
				t.Fatal("retired packet flow received an echo")
			}
			fresh := open(444)
			defer fresh.Close()
			fresh.SetDeadline(time.Now().Add(3 * time.Second))
			if _, err := fresh.Write([]byte("fresh")); err != nil {
				t.Fatal(err)
			}
			if _, err := io.ReadFull(fresh, buf[:5]); err != nil || string(buf[:5]) != "fresh" {
				t.Fatalf("fresh packet flow failed: %v", err)
			}
			if stalePayloads.Load() != 0 || calls.Load() != 2 || !router.CaptureActive() {
				t.Fatal("retired payload escaped or positive control was absent")
			}
		})
	}
}
