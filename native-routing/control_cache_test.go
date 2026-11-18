package routing

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/netip"
	"testing"
	"time"
)

func TestAndroidCachedControlHTTPSAfterPeerReplacement(t *testing.T) {
	now := time.Now()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	cert := &x509.Certificate{SerialNumber: big.NewInt(1), DNSNames: []string{"vexguard.app"}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, BasicConstraintsValid: true, IsCA: true}
	der, err := x509.CreateCertificate(rand.Reader, cert, cert, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	ca, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(ca)
	actual := netip.MustParseAddr("104.16.30.30")
	target := make(chan string, 1)
	previous := androidControlRouter(t, target)
	cached, err := previous.fakes.put("vexguard.app", actual, now.Add(time.Minute), controlMappingVersion, now)
	if err != nil {
		t.Fatal(err)
	}
	previous.Close()
	osTUN := newFixtureTUN()
	next, _, err := Attach(osTUN, Options{
		Platform: "android", Addresses: []netip.Addr{netip.MustParseAddr("10.64.0.2")}, DNS: []netip.Addr{netip.MustParseAddr("1.1.1.1")},
		DirectDial: func(_ context.Context, protocol, address string) (net.Conn, error) {
			client, peer := net.Pipe()
			go func() {
				defer peer.Close()
				peer.SetDeadline(time.Now().Add(15 * time.Second))
				// A cached address sent to another virtual host closes before TLS,
				// reproducing Android's "Connection closed by peer" symptom.
				if protocol != "tcp" || address != netip.AddrPortFrom(actual, 443).String() {
					return
				}
				server := tls.Server(peer, &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}, MinVersion: tls.VersionTLS12})
				defer server.Close()
				request, err := http.ReadRequest(bufio.NewReader(server))
				if err != nil {
					return
				}
				defer request.Body.Close()
				if request.Host != "vexguard.app" {
					return
				}
				io.WriteString(server, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
			}()
			return client, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { next.Close() })
	if _, err := next.fakes.put("unrelated.ru", netip.MustParseAddr("104.16.40.40"), now.Add(time.Minute), "other-policy", now); err != nil {
		t.Fatal(err)
	}
	app := connectFixture(t, next, osTUN)
	transport := &http.Transport{TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}, DisableKeepAlives: true, DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return app.DialContextTCPAddrPort(ctx, netip.AddrPortFrom(cached, 443))
	}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 15 * time.Second}
	response, err := client.Get("https://vexguard.app/v1/health")
	if err != nil {
		t.Fatalf("cached control HTTPS failed after replacing peer: %v", err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil || response.StatusCode != http.StatusOK || string(body) != "ok" {
		t.Fatalf("HTTP200 body not received: status=%d err=%v", response.StatusCode, err)
	}
}

func androidControlRouter(t *testing.T, target chan string, clock ...func() time.Time) *Router {
	t.Helper()
	now := time.Now
	if len(clock) > 0 {
		now = clock[0]
	}
	r, _, err := Attach(newFixtureTUN(), Options{
		Platform:  "android",
		Now:       now,
		Addresses: []netip.Addr{netip.MustParseAddr("10.64.0.2")},
		DNS:       []netip.Addr{netip.MustParseAddr("1.1.1.1")},
		DirectDial: func(_ context.Context, _, address string) (net.Conn, error) {
			target <- address
			client, peer := net.Pipe()
			go peer.Close()
			return client, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { r.Close() })
	return r
}

// Android can retain its VPN Network and an application's cached A/AAAA answer
// while GoBackend replaces the router/peer. The cached address must keep its
// original hostname, regardless of the new router's first DNS query.
func TestAndroidCachedControlAddressSurvivesRouterReplacement(t *testing.T) {
	for _, address := range []string{"104.16.10.10", "2606:4700::1111"} {
		t.Run(address, func(t *testing.T) {
			target := make(chan string, 2)
			previous := androidControlRouter(t, target)
			now := time.Now()
			actual := netip.MustParseAddr(address)
			cached, err := previous.fakes.put("vexguard.app", actual, now.Add(time.Minute), controlMappingVersion, now)
			if err != nil {
				t.Fatal(err)
			}
			previous.Close()
			next := androidControlRouter(t, target)
			other := netip.MustParseAddr("104.16.20.20")
			if actual.Is6() {
				other = netip.MustParseAddr("2606:4700::2222")
			}
			_, err = next.fakes.put("unrelated.ru", other, now.Add(time.Minute), "other-policy", now)
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			conn, direct, err := next.dial(ctx, "tcp", netip.AddrPortFrom(cached, 443))
			if err != nil {
				t.Fatalf("cached control origin lost after peer replacement: %v", err)
			}
			defer next.releaseConnection(conn, direct)
			if got := <-target; !direct || got != netip.AddrPortFrom(actual, 443).String() {
				t.Fatalf("cached control identity changed destination to %s", got)
			}
			for _, attempt := range []struct {
				protocol string
				port     uint16
			}{{"tcp", 22}, {"udp", 443}, {"udp", 53}} {
				if _, _, err := next.dial(ctx, attempt.protocol, netip.AddrPortFrom(cached, attempt.port)); err == nil {
					t.Fatal("shared cache widened the control exception")
				}
			}
		})
	}
}

func TestAndroidCachedCountryIdentityStillNeedsCurrentPolicy(t *testing.T) {
	now := time.Now()
	policy, err := CompilePolicy(testPolicy(now), now)
	if err != nil {
		t.Fatal(err)
	}
	target := make(chan string, 2)
	previous := androidControlRouter(t, target)
	cached, err := previous.fakes.put("shop.ru", netip.MustParseAddr("104.16.10.10"), now.Add(time.Minute), policy.Version(), now)
	if err != nil {
		t.Fatal(err)
	}
	previous.Close()
	next := androidControlRouter(t, target)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, _, err := next.dial(ctx, "tcp", netip.AddrPortFrom(cached, 443)); err == nil {
		t.Fatal("old country's identity granted DIRECT without current policy")
	}
	next.UpdatePolicy(policy)
	conn, direct, err := next.dial(ctx, "tcp", netip.AddrPortFrom(cached, 443))
	if err != nil || !direct {
		t.Fatalf("current policy could not revalidate cached hostname: %v", err)
	}
	next.releaseConnection(conn, direct)
	if got := <-target; got != "104.16.10.10:443" {
		t.Fatal("cached identity changed", got)
	}
	next.UpdatePolicy(nil)
	if _, _, err := next.dial(ctx, "tcp", netip.AddrPortFrom(cached, 443)); err == nil {
		t.Fatal("revocation ignored")
	}
	select {
	case got := <-target:
		t.Fatal("rejected destination dialed", got)
	default:
	}
}

func TestAndroidDNSCacheStillExpiresAcrossRouterReplacement(t *testing.T) {
	now := time.Now()
	target := make(chan string, 2)
	previous := androidControlRouter(t, target)
	cached, err := previous.fakes.put("www.vexguard.app", netip.MustParseAddr("104.16.10.10"), now.Add(time.Second), controlMappingVersion, now)
	if err != nil {
		t.Fatal(err)
	}
	previous.Close()
	next := androidControlRouter(t, target, func() time.Time { return now.Add(2 * time.Second) })
	if _, _, err := next.dial(context.Background(), "tcp", netip.AddrPortFrom(cached, 443)); err == nil {
		t.Fatal("expired control DNS mapping survived")
	}
	select {
	case got := <-target:
		t.Fatal("expired destination dialed", got)
	default:
	}
}
