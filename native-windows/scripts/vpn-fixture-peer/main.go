// A local acceptance peer. Its tunnel address exists only in a Go netstack,
// never on an OS adapter: a successful request must traverse encrypted AWG.
package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
	"github.com/amnezia-vpn/amneziawg-go/v3/device"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun/netstack"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/net/dns/dnsmessage"
)

const serverIP = "10.253.253.1"
const clientIP = "10.253.253.2"
const fixtureHost = "fixture.vex.invalid"

// Use the same advanced AWG3.1 parameters on both endpoints. On Windows these
// travel through signed-profile materialization and the qualified CLI parser.
func advancedConfig(header []byte) string {
	return "jc=2\njmin=64\njmax=128\ns1=12\ns2=12\ns3=12\ns4=12\n" +
		"h1=100001-100010\nh2=200001-200010\nh3=300001-300010\nh4=400001-400010\n" +
		"header_protection_key=" + hex.EncodeToString(header) + "\n" +
		"content_padding_addition=16-32\nrekey_after_time=120-130\nrekey_timeout=5-6\n" +
		"reject_after_time=180-190\nkeepalive_timeout=10-12\nmax_handshake_attempts=18-20\n" +
		"random_trailers=1\ndisable_cookies=0\n"
}

// A narrow Bind prevents even encrypted fixture traffic from leaving loopback.
// A normal bind can listen/send on all host interfaces.
type loopbackBind struct {
	mu  sync.Mutex
	udp *net.UDPConn
}

func (b *loopbackBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.udp != nil {
		return nil, 0, conn.ErrBindAlreadyOpen
	}
	u, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: int(port)})
	if err != nil {
		return nil, 0, err
	}
	b.udp = u
	receive := func(packets [][]byte, sizes []int, eps []conn.Endpoint) (int, error) {
		n, addr, err := u.ReadFromUDPAddrPort(packets[0])
		if err != nil {
			return 0, err
		}
		sizes[0] = n
		eps[0] = &conn.StdNetEndpoint{AddrPort: addr}
		return 1, nil
	}
	return []conn.ReceiveFunc{receive}, uint16(u.LocalAddr().(*net.UDPAddr).Port), nil
}
func (b *loopbackBind) Close() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.udp == nil {
		return nil
	}
	err := b.udp.Close()
	b.udp = nil
	return err
}
func (b *loopbackBind) SetMark(mark uint32) error {
	if mark != 0 {
		return errors.New("fixture rejects socket marks")
	}
	return nil
}
func (b *loopbackBind) BatchSize() int { return 1 }
func (b *loopbackBind) ParseEndpoint(value string) (conn.Endpoint, error) {
	a, err := netip.ParseAddrPort(value)
	if err != nil || !a.Addr().Is4() || !a.Addr().IsLoopback() {
		return nil, errors.New("fixture rejects non-loopback endpoint")
	}
	return &conn.StdNetEndpoint{AddrPort: a}, nil
}
func (b *loopbackBind) Send(packets [][]byte, ep conn.Endpoint) error {
	if !ep.DstIP().IsLoopback() {
		return errors.New("fixture rejects non-loopback send")
	}
	a, err := netip.ParseAddrPort(ep.DstToString())
	if err != nil {
		return err
	}
	b.mu.Lock()
	u := b.udp
	b.mu.Unlock()
	if u == nil {
		return net.ErrClosed
	}
	for _, packet := range packets {
		if _, err := u.WriteToUDPAddrPort(packet, a); err != nil {
			return err
		}
	}
	return nil
}

type manifest struct {
	Schema              string `json:"schema"`
	ClientPrivateKey    string `json:"client_private_key"`
	ServerPublicKey     string `json:"server_public_key"`
	HeaderProtectionKey string `json:"header_protection_key"`
	Endpoint            string `json:"endpoint"`
	ServerIP            string `json:"server_ip"`
	ClientIP            string `json:"client_ip"`
}
type status struct {
	Schema         string `json:"schema"`
	HandshakeUnix  int64  `json:"handshake_unix"`
	RxBytes        int64  `json:"rx_bytes"`
	TxBytes        int64  `json:"tx_bytes"`
	DNSRequests    int64  `json:"dns_requests"`
	DNSReceived    int64  `json:"dns_received"`
	DNSRejected    int64  `json:"dns_rejected"`
	DNSWriteErrors int64  `json:"dns_write_errors"`
	HTTPSRequests  int64  `json:"https_requests"`
}
type fixture struct {
	dev            *device.Device
	net            *netstack.Net
	manifest       manifest
	root           []byte
	cert           tls.Certificate
	dns            atomic.Int64
	dnsReceived    atomic.Int64
	dnsRejected    atomic.Int64
	dnsWriteErrors atomic.Int64
	https          atomic.Int64
	server         *http.Server
	closeDNS       func() error
}

func newFixture() (*fixture, error) {
	clientPrivate, serverPrivate, header := make([]byte, 32), make([]byte, 32), make([]byte, 32)
	for _, value := range [][]byte{clientPrivate, serverPrivate, header} {
		if _, err := rand.Read(value); err != nil {
			return nil, err
		}
	}
	clientPublic, err := curve25519.X25519(clientPrivate, curve25519.Basepoint)
	if err != nil {
		return nil, err
	}
	serverPublic, err := curve25519.X25519(serverPrivate, curve25519.Basepoint)
	if err != nil {
		return nil, err
	}
	tun, network, err := netstack.CreateNetTUN([]netip.Addr{netip.MustParseAddr(serverIP)}, nil, 1360)
	if err != nil {
		return nil, err
	}
	f := &fixture{net: network}
	f.dev = device.NewDevice(tun, &loopbackBind{}, device.NewLogger(device.LogLevelSilent, ""))
	failed := true
	defer func() {
		if failed {
			f.dev.Close()
		}
	}()
	cfg := "private_key=" + hex.EncodeToString(serverPrivate) + "\nlisten_port=0\n" + advancedConfig(header) +
		"replace_peers=true\npublic_key=" + hex.EncodeToString(clientPublic) + "\nreplace_allowed_ips=true\nallowed_ip=" + clientIP + "/32\n"
	if err := f.dev.IpcSet(cfg); err != nil {
		return nil, err
	}
	if err := f.dev.Up(); err != nil {
		return nil, err
	}
	uapi, err := f.dev.IpcGet()
	if err != nil {
		return nil, err
	}
	port := ""
	for _, line := range strings.Split(uapi, "\n") {
		if strings.HasPrefix(line, "listen_port=") {
			port = strings.TrimPrefix(line, "listen_port=")
		}
	}
	if port == "" || port == "0" {
		return nil, errors.New("fixture port unavailable")
	}
	f.manifest = manifest{"vex.windows-vpn-fixture.v1", base64.StdEncoding.EncodeToString(clientPrivate), base64.StdEncoding.EncodeToString(serverPublic), base64.StdEncoding.EncodeToString(header), "127.0.0.1:" + port, serverIP, clientIP}
	f.root, f.cert, err = fixtureCertificate()
	if err != nil {
		return nil, err
	}
	failed = false
	return f, nil
}

func fixtureCertificate() ([]byte, tls.Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, tls.Certificate{}, err
	}
	now := time.Now()
	ca := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "VEX ephemeral fixture CA"}, NotBefore: now.Add(-time.Minute), NotAfter: now.Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	caDER, err := x509.CreateCertificate(rand.Reader, ca, ca, &key.PublicKey, key)
	if err != nil {
		return nil, tls.Certificate{}, err
	}
	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, tls.Certificate{}, err
	}
	leaf := &x509.Certificate{SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: fixtureHost}, DNSNames: []string{fixtureHost}, NotBefore: now.Add(-time.Minute), NotAfter: now.Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	leafDER, err := x509.CreateCertificate(rand.Reader, leaf, ca, &leafKey.PublicKey, key)
	if err != nil {
		return nil, tls.Certificate{}, err
	}
	pk, err := x509.MarshalPKCS8PrivateKey(leafKey)
	if err != nil {
		return nil, tls.Certificate{}, err
	}
	cert, err := tls.X509KeyPair(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leafDER}), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: pk}))
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER}), cert, err
}

func (f *fixture) serve() error {
	u, err := f.net.ListenUDPAddrPort(netip.MustParseAddrPort(serverIP + ":53"))
	if err != nil {
		return err
	}
	f.closeDNS = u.Close
	go func() {
		packet := make([]byte, 1232)
		for {
			n, addr, err := u.ReadFrom(packet)
			if err != nil {
				return
			}
			f.dnsReceived.Add(1)
			if addr.(*net.UDPAddr).IP.String() != clientIP {
				f.dnsRejected.Add(1)
				continue
			}
			response, err := dnsResponse(packet[:n])
			if err != nil {
				f.dnsRejected.Add(1)
				continue
			}
			if _, err := u.WriteTo(response, addr); err == nil {
				f.dns.Add(1)
			} else {
				f.dnsWriteErrors.Add(1)
			}
		}
	}()
	l, err := f.net.ListenTCPAddrPort(netip.MustParseAddrPort(serverIP + ":443"))
	if err != nil {
		u.Close()
		return err
	}
	f.server = &http.Server{ReadHeaderTimeout: 5 * time.Second, WriteTimeout: 5 * time.Second, IdleTimeout: 5 * time.Second, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, _ := net.SplitHostPort(r.RemoteAddr)
		nonce := r.URL.Query().Get("nonce")
		if host != clientIP || r.Host != fixtureHost || r.URL.Path != "/health" || len(nonce) != 32 || strings.ContainsAny(nonce, "\r\n") {
			http.Error(w, "invalid fixture request", http.StatusBadRequest)
			return
		}
		f.https.Add(1)
		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprint(w, "vex-vpn-fixture:"+nonce)
	})}
	go f.server.Serve(tls.NewListener(l, &tls.Config{Certificates: []tls.Certificate{f.cert}, MinVersion: tls.VersionTLS12}))
	return nil
}

func dnsResponse(packet []byte) ([]byte, error) {
	var query dnsmessage.Message
	if err := query.Unpack(packet); err != nil {
		return nil, err
	}
	if query.Header.Response || len(query.Questions) != 1 || query.Questions[0].Type != dnsmessage.TypeA || query.Questions[0].Name.String() != fixtureHost+"." {
		return nil, errors.New("unsupported fixture DNS question")
	}
	response := dnsmessage.Message{Header: dnsmessage.Header{ID: query.Header.ID, Response: true, Authoritative: true, RecursionDesired: query.Header.RecursionDesired}, Questions: query.Questions, Answers: []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: query.Questions[0].Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 0}, Body: &dnsmessage.AResource{A: [4]byte{10, 253, 253, 1}}}}}
	return response.Pack()
}

func (f *fixture) snapshot() (status, error) {
	text, err := f.dev.IpcGet()
	if err != nil {
		return status{}, err
	}
	s := status{Schema: "vex.windows-vpn-peer-status.v1", DNSRequests: f.dns.Load(), DNSReceived: f.dnsReceived.Load(), DNSRejected: f.dnsRejected.Load(), DNSWriteErrors: f.dnsWriteErrors.Load(), HTTPSRequests: f.https.Load()}
	// Never persist the raw UAPI output, which includes private keys.
	for _, line := range strings.Split(text, "\n") {
		name, value, _ := strings.Cut(line, "=")
		v, _ := strconv.ParseInt(value, 10, 64)
		switch name {
		case "last_handshake_time_sec":
			s.HandshakeUnix = v
		case "rx_bytes":
			s.RxBytes = v
		case "tx_bytes":
			s.TxBytes = v
		}
	}
	return s, nil
}
func (f *fixture) close() {
	if f.server != nil {
		f.server.Close()
	}
	if f.closeDNS != nil {
		f.closeDNS()
	}
	f.dev.Close()
}

func run() error {
	directory := flag.String("directory", "", "fresh private fixture directory")
	lifetime := flag.Duration("lifetime", 180*time.Second, "finite maximum fixture lifetime")
	flag.Parse()
	if *directory == "" || *lifetime < 10*time.Second || *lifetime > 5*time.Minute {
		return errors.New("invalid fixture options")
	}
	if _, err := os.Stat(filepath.Join(*directory, "owned-fixture")); err != nil {
		return errors.New("fixture ownership marker missing")
	}
	f, err := newFixture()
	if err != nil {
		return err
	}
	defer f.close()
	if err := f.serve(); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(*directory, "root.pem"), f.root, 0600); err != nil {
		return err
	}
	data, err := json.Marshal(f.manifest)
	if err != nil {
		return err
	}
	file, err := os.OpenFile(filepath.Join(*directory, "manifest.json"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	_, err = file.Write(data)
	closeErr := file.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	deadline := time.NewTimer(*lifetime)
	defer deadline.Stop()
	for {
		s, err := f.snapshot()
		if err != nil {
			return err
		}
		data, _ := json.Marshal(s)
		// Windows rename does not replace a target; delete only our safe status file.
		path := filepath.Join(*directory, "peer-status.json")
		if err := os.WriteFile(path+".tmp", data, 0600); err != nil {
			return err
		}
		os.Remove(path)
		if err := os.Rename(path+".tmp", path); err != nil {
			return err
		}
		select {
		case <-ctx.Done():
			return nil
		case <-deadline.C:
			return nil
		case <-ticker.C:
		}
	}
}
func main() {
	if err := run(); err != nil {
		// Keys/configuration and raw device errors are deliberately excluded.
		fmt.Fprintln(os.Stderr, "VEX fixture failed:", fmt.Sprintf("%T", err))
		os.Exit(1)
	}
}
