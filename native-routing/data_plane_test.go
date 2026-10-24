package routing

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/netip"
	"sync/atomic"
	"testing"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/tun"
	"golang.org/x/net/dns/dnsmessage"
	"vex.dev/native-routing/internal/awgnetstack"
)

// Entire DNS/TCP/TLS/HTTP exchange is packet-only, with the real AWG NetTUN
// and a synthetic remote peer. No host listener, route, DNS or VPN is changed.
func dataPlaneFixture(t *testing.T, dnsDrop bool, body string, status int, onRequest ...func()) (*Router, *tls.Config, *atomic.Int32) {
	t.Helper()
	var physical atomic.Int32
	r, _, err := Attach(newFixtureTUN(), Options{
		Addresses: []netip.Addr{netip.MustParseAddr("10.64.0.2")}, DNS: []netip.Addr{netip.MustParseAddr("10.64.0.1")},
		DirectDial: func(context.Context, string, string) (net.Conn, error) {
			physical.Add(1)
			t.Error("physical dial used by canary")
			return nil, io.EOF
		},
		DirectDNS: func(context.Context, []byte) ([]byte, error) {
			physical.Add(1)
			t.Error("physical DNS used by canary")
			return nil, io.EOF
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	peerTUN, peer, err := netstack.CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.64.0.1"), netip.MustParseAddr("1.1.1.1")}, nil, 1360)
	if err != nil {
		t.Fatal(err)
	}
	pump := func(from, to tun.Device) {
		buffer := make([]byte, 65536)
		for {
			sizes := []int{0}
			if _, err := from.Read([][]byte{buffer}, sizes, 0); err != nil {
				return
			}
			if _, err := to.Write([][]byte{buffer[:sizes[0]]}, 0); err != nil {
				return
			}
		}
	}
	go pump(r.transport, peerTUN)
	go pump(peerTUN, r.transport)
	dns, err := peer.ListenUDPAddrPort(netip.MustParseAddrPort("10.64.0.1:53"))
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		buffer := make([]byte, 4096)
		for {
			n, address, err := dns.ReadFrom(buffer)
			if err != nil {
				return
			}
			if dnsDrop {
				continue
			}
			var message dnsmessage.Message
			if message.Unpack(buffer[:n]) != nil {
				continue
			}
			message.Response = true
			message.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: message.Questions[0].Name, Class: dnsmessage.ClassINET, Type: dnsmessage.TypeA, TTL: 1}, Body: &dnsmessage.AResource{A: [4]byte{1, 1, 1, 1}}}}
			answer, _ := message.Pack()
			dns.WriteTo(answer, address)
		}
	}()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "one.one.one.one"}, DNSNames: []string{"one.one.one.one"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, BasicConstraintsValid: true, IsCA: true}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, _ := x509.MarshalPKCS8PrivateKey(key)
	certificate, err := tls.X509KeyPair(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}))
	if err != nil {
		t.Fatal(err)
	}
	ca, _ := x509.ParseCertificate(der)
	roots := x509.NewCertPool()
	roots.AddCert(ca)
	listener, err := peer.ListenTCPAddrPort(netip.MustParseAddrPort("1.1.1.1:443"))
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{ErrorLog: log.New(io.Discard, "", 0), Handler: http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		for _, ready := range onRequest {
			ready()
		}
		if req.URL.Path != "/cdn-cgi/trace" {
			t.Error("wrong HTTPS request")
		}
		if status == 0 {
			<-req.Context().Done()
			return
		}
		if status == 302 {
			w.Header().Set("Location", "https://other.example/")
		}
		w.WriteHeader(status)
		io.WriteString(w, body)
	})}
	go server.Serve(tls.NewListener(listener, &tls.Config{Certificates: []tls.Certificate{certificate}, MinVersion: tls.VersionTLS12}))
	t.Cleanup(func() { server.Close(); dns.Close(); r.Close(); peerTUN.Close() })
	return r, &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}, &physical
}

var isolatedDataPlaneTargets = []dataPlaneTarget{{"one.one.one.one", "/cdn-cgi/trace", "trace"}}

func TestDataPlaneIndependentServiceFallbackStillUsesSelectedPeer(t *testing.T) {
	r, trust, physical := dataPlaneFixture(t, false, "ip=8.8.4.4\n", 200)
	ctx, cancel := context.WithTimeout(r.underlyingContext(), 10*time.Second)
	defer cancel()
	targets := append([]dataPlaneTarget{{"wrong-certificate.example", "/cdn-cgi/trace", "trace"}}, isolatedDataPlaneTargets...)
	if got := r.verifyDataPlane(ctx, targets, trust); got != DataPlaneVerified {
		t.Fatalf("second service did not recover: %d", got)
	}
	if physical.Load() != 0 {
		t.Fatal("service fallback escaped the peer")
	}
}

func TestDataPlaneNetworkRetiredDuringHTTPResponse(t *testing.T) {
	ready := make(chan struct{})
	r, trust, _ := dataPlaneFixture(t, false, "", 0, func() { close(ready) })
	ctx, cancel := context.WithTimeout(r.underlyingContext(), 10*time.Second)
	defer cancel()
	result := make(chan int, 1)
	go func() { result <- r.verifyDataPlane(ctx, isolatedDataPlaneTargets, trust) }()
	select {
	case <-ready:
	case <-ctx.Done():
		t.Fatal("HTTPS positive setup did not reach peer")
	}
	r.UnderlyingNetworkChanged()
	select {
	case got := <-result:
		if got == DataPlaneVerified {
			t.Fatal("retired HTTP operation confirmed new network")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("network cancellation did not stop HTTP")
	}
}

func TestDataPlaneRealDNSAndTLSHTTPOverSelectedNetTUN(t *testing.T) {
	r, trust, physical := dataPlaneFixture(t, false, "ip=8.8.4.4\n", 200)
	ctx, cancel := context.WithTimeout(r.underlyingContext(), 10*time.Second)
	defer cancel()
	if got := r.verifyDataPlane(ctx, isolatedDataPlaneTargets, trust); got != DataPlaneVerified {
		t.Fatalf("positive control failed: %d", got)
	}
	if physical.Load() != 0 {
		t.Fatal("canary escaped the selected peer")
	}
}

func TestDataPlaneDNSFailureNeverUsesHostOrDirectFallback(t *testing.T) {
	r, trust, physical := dataPlaneFixture(t, true, "ip=8.8.4.4\n", 200)
	ctx, cancel := context.WithTimeout(r.underlyingContext(), 100*time.Millisecond)
	defer cancel()
	if got := r.verifyDataPlane(ctx, isolatedDataPlaneTargets, trust); got == DataPlaneVerified {
		t.Fatal("DNS failure accepted")
	}
	if physical.Load() != 0 {
		t.Fatal("DNS used direct fallback")
	}
}

func TestDataPlaneDNSAndTCPOrTLSAloneAreInsufficient(t *testing.T) {
	for _, scenario := range []struct {
		name, body string
		status     int
		untrusted  bool
	}{
		{"no_http_response", "", 0, false}, {"redirect", "ip=8.8.4.4\n", 302, false},
		{"wrong_status", "ip=8.8.4.4\n", 503, false}, {"missing_echo", "ok", 200, false},
		{"untrusted_certificate", "ip=8.8.4.4\n", 200, true},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			ready := make(chan struct{})
			r, trust, physical := dataPlaneFixture(t, false, scenario.body, scenario.status, func() {
				if scenario.status == 0 {
					close(ready)
				}
			})
			if scenario.untrusted {
				trust = &tls.Config{RootCAs: x509.NewCertPool(), MinVersion: tls.VersionTLS12}
			}
			ctx, cancel := context.WithTimeout(r.underlyingContext(), 10*time.Second)
			defer cancel()
			if scenario.status == 0 {
				go func() {
					select {
					case <-ready:
						cancel()
					case <-ctx.Done():
					}
				}()
			}
			if got := r.verifyDataPlane(ctx, isolatedDataPlaneTargets, trust); got != DataPlaneHTTPSFailed {
				t.Fatalf("expected HTTPS failure after DNS, got %d", got)
			}
			if physical.Load() != 0 {
				t.Fatal("HTTPS used direct fallback")
			}
		})
	}
}

func TestDataPlaneRetiredPeerAndNetworkCannotConfirm(t *testing.T) {
	for _, mode := range []string{"closed", "transport_stopped", "network_retired"} {
		t.Run(mode, func(t *testing.T) {
			r, trust, _ := dataPlaneFixture(t, false, "ip=8.8.4.4\n", 200)
			ctx, cancel := context.WithTimeout(r.underlyingContext(), 10*time.Second)
			defer cancel()
			switch mode {
			case "closed":
				r.Close()
			case "transport_stopped":
				r.StopTransport()
			case "network_retired":
				r.UnderlyingNetworkChanged()
			}
			if got := r.verifyDataPlane(ctx, isolatedDataPlaneTargets, trust); got != DataPlaneRetired {
				t.Fatalf("retired generation accepted: %d", got)
			}
		})
	}
}
