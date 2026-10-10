package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"testing"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/device"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun/netstack"
	"golang.org/x/net/dns/dnsmessage"
)

func TestEncryptedDNSAndHTTPS(t *testing.T) {
	f, err := newFixture()
	if err != nil {
		t.Fatal(err)
	}
	defer f.close()
	if err := f.serve(); err != nil {
		t.Fatal(err)
	}
	tun, client, err := netstack.CreateNetTUN([]netip.Addr{netip.MustParseAddr(clientIP)}, nil, 1360)
	if err != nil {
		t.Fatal(err)
	}
	d := device.NewDevice(tun, &loopbackBind{}, device.NewLogger(device.LogLevelSilent, ""))
	defer d.Close()
	private, _ := base64.StdEncoding.DecodeString(f.manifest.ClientPrivateKey)
	public, _ := base64.StdEncoding.DecodeString(f.manifest.ServerPublicKey)
	header, _ := base64.StdEncoding.DecodeString(f.manifest.HeaderProtectionKey)
	config := "private_key=" + hex.EncodeToString(private) + "\n" + advancedConfig(header) + "replace_peers=true\npublic_key=" + hex.EncodeToString(public) + "\nendpoint=" + f.manifest.Endpoint + "\npersistent_keepalive_interval=1\nreplace_allowed_ips=true\nallowed_ip=" + serverIP + "/32\n"
	if err := d.IpcSet(config); err != nil {
		t.Fatal(err)
	}
	if err := d.Up(); err != nil {
		t.Fatal(err)
	}
	u, err := client.DialUDPAddrPort(netip.AddrPort{}, netip.MustParseAddrPort(serverIP+":53"))
	if err != nil {
		t.Fatal(err)
	}
	defer u.Close()
	name, _ := dnsmessage.NewName(fixtureHost + ".")
	query := dnsmessage.Message{Header: dnsmessage.Header{ID: 54321}, Questions: []dnsmessage.Question{{Name: name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}}}
	packet, _ := query.Pack()
	response := make([]byte, 1232)
	n := 0
	// UDP questions may race the initial handshake. Retry within one finite
	// deadline, as a resolver would; HTTPS still uses reliable TCP afterwards.
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		u.SetDeadline(time.Now().Add(time.Second))
		if _, err = u.Write(packet); err != nil {
			t.Fatal(err)
		}
		n, err = u.Read(response)
		if err == nil {
			break
		}
	}
	if err != nil {
		t.Fatal(err)
	}
	var answer dnsmessage.Message
	if err := answer.Unpack(response[:n]); err != nil {
		t.Fatal(err)
	}
	if answer.ID != query.ID || !answer.Response || len(answer.Answers) != 1 || answer.Answers[0].Body.(*dnsmessage.AResource).A != [4]byte{10, 253, 253, 1} {
		t.Fatal("DNS payload mismatch")
	}
	roots := x509.NewCertPool()
	roots.AppendCertsFromPEM(f.root)
	transport := &http.Transport{Proxy: nil, TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}, DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return client.DialContextTCPAddrPort(ctx, netip.MustParseAddrPort(serverIP+":443"))
	}}
	defer transport.CloseIdleConnections()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	nonce := strings.Repeat("a", 32)
	r, _ := http.NewRequestWithContext(ctx, http.MethodGet, "https://"+fixtureHost+"/health?nonce="+nonce, nil)
	result, err := (&http.Client{Transport: transport}).Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer result.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(result.Body, 100))
	if result.StatusCode != 200 || string(body) != "vex-vpn-fixture:"+nonce || result.TLS == nil || len(result.TLS.VerifiedChains) == 0 {
		t.Fatal("HTTPS payload/certificate mismatch")
	}
	s, err := f.snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if s.HandshakeUnix == 0 || s.RxBytes == 0 || s.TxBytes == 0 || s.DNSRequests < 1 || s.HTTPSRequests != 1 {
		t.Fatalf("Actual encrypted peer counters missing: %+v", s)
	}
}

func TestFixtureRejectsExternalEndpoint(t *testing.T) {
	b := &loopbackBind{}
	for _, value := range []string{"203.0.113.1:1234", "[::1]:1234", "vpn.example:1234"} {
		if _, err := b.ParseEndpoint(value); err == nil {
			t.Fatal("external or unsupported endpoint accepted")
		}
	}
	if _, err := b.ParseEndpoint("127.0.0.1:1234"); err != nil {
		t.Fatal(err)
	}
}
