package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
	"github.com/amnezia-vpn/amneziawg-go/v3/device"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun/netstack"
	"golang.org/x/net/dns/dnsmessage"
)

// Exercise the actual CLI argument admission and startup used by Windows CI.
// No adapter, route or firewall is created; the peer remains a local netstack.
func TestPeerCLIExtendedLifetime(t *testing.T) {
	buildDirectory := t.TempDir()
	peerPath := filepath.Join(buildDirectory, "qualified-peer.exe")
	buildContext, cancelBuild := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancelBuild()
	build := exec.CommandContext(buildContext, "go", "build", "-trimpath", "-buildvcs=false", "-o", peerPath, ".")
	if err := build.Run(); err != nil {
		t.Fatal("qualified peer CLI build failed")
	}

	directory := t.TempDir()
	if err := os.WriteFile(filepath.Join(directory, "owned-fixture"), []byte("test-owned"), 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	peer := exec.CommandContext(ctx, peerPath, "-directory", directory, "-lifetime", "420s")
	if err := peer.Start(); err != nil {
		t.Fatal("qualified peer CLI did not start")
	}
	done := make(chan error, 1)
	go func() { done <- peer.Wait() }()
	t.Cleanup(func() {
		_ = peer.Process.Kill() // Only the exact child started above is owned.
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			t.Error("owned peer process did not terminate")
		}
	})
	ready := false
	for !ready {
		if data, err := os.ReadFile(filepath.Join(directory, "manifest.json")); err == nil {
			var manifest struct {
				Schema string `json:"schema"`
			}
			if json.Unmarshal(data, &manifest) == nil && manifest.Schema == "vex.windows-vpn-fixture.v1" {
				ready = true
				break
			}
		}
		select {
		case <-done:
			// Keep cleanup's Wait result available without logging CLI output.
			done <- nil
			t.Fatal("420-second peer exited before readiness")
		case <-ctx.Done():
			t.Fatal("420-second peer did not become ready within its startup bound")
		case <-time.After(25 * time.Millisecond):
		}
	}

	rejectedDirectory := t.TempDir()
	if err := os.WriteFile(filepath.Join(rejectedDirectory, "owned-fixture"), []byte("test-owned"), 0600); err != nil {
		t.Fatal(err)
	}
	rejectionContext, cancelRejection := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancelRejection()
	rejected := exec.CommandContext(rejectionContext, peerPath, "-directory", rejectedDirectory, "-lifetime", "421s")
	if err := rejected.Run(); err == nil || rejectionContext.Err() != nil {
		t.Fatal("peer CLI did not enforce its finite 420-second maximum")
	}
	if _, err := os.Stat(filepath.Join(rejectedDirectory, "manifest.json")); !os.IsNotExist(err) {
		t.Fatal("over-budget peer created fixture state")
	}
}

func TestEncryptedDNSAndHTTPS(t *testing.T) {
	t.Run("loopback", func(t *testing.T) { testEncryptedDNSAndHTTPSAt(t, fixtureLoopback) })
	address, ok := existingPrivateHostIPv4()
	if !ok {
		t.Log("No existing private non-loopback IPv4; host-address subtest unavailable")
		return
	}
	t.Run("host-private", func(t *testing.T) { testEncryptedDNSAndHTTPSAt(t, address) })
}

func existingPrivateHostIPv4() (netip.Addr, bool) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return netip.Addr{}, false
	}
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addresses, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, assigned := range addresses {
			text, _, _ := strings.Cut(assigned.String(), "/")
			address, err := netip.ParseAddr(text)
			if err == nil && address.Is4() && address.IsPrivate() && validateHostLocalAddress(address) == nil {
				return address, true
			}
		}
	}
	return netip.Addr{}, false
}

func testEncryptedDNSAndHTTPSAt(t *testing.T, endpointAddress netip.Addr) {
	t.Helper()
	f, err := newFixtureAt(endpointAddress)
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
	d := device.NewDevice(tun, &hostLocalBind{address: endpointAddress}, device.NewLogger(device.LogLevelSilent, ""))
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
	if s.DNSReceived < s.DNSRequests || s.DNSRejected != 0 || s.DNSWriteErrors != 0 {
		t.Fatalf("DNS receive/reply counters inconsistent: %+v", s)
	}
}

func TestFixtureRejectsExternalEndpoint(t *testing.T) {
	b := &hostLocalBind{}
	for _, value := range []string{"203.0.113.1:1234", "[::1]:1234", "vpn.example:1234", "0.0.0.0:1234", "224.0.0.1:1234", serverIP + ":1234", clientIP + ":1234", "127.0.0.2:1234", "127.0.0.1:0"} {
		if _, err := b.ParseEndpoint(value); err == nil {
			t.Fatal("external or unsupported endpoint accepted")
		}
	}
	if _, err := b.ParseEndpoint("127.0.0.1:1234"); err != nil {
		t.Fatal(err)
	}
}

func TestFixtureRejectsNonHostBind(t *testing.T) {
	for _, value := range []string{"0.0.0.0", "224.0.0.1", "255.255.255.255", "192.0.2.1", "198.51.100.1", "203.0.113.1", "198.18.0.1", "127.0.0.2", "169.254.1.1", serverIP, clientIP, "::1", "::ffff:127.0.0.1"} {
		address := netip.MustParseAddr(value)
		if _, err := newFixtureAt(address); err == nil {
			t.Fatal("unsafe fixture bind accepted")
		}
		b := &hostLocalBind{address: address}
		if _, _, err := b.Open(0); err == nil {
			b.Close()
			t.Fatal("unsafe bind opened")
		}
	}
	if _, err := newFixtureAt(netip.Addr{}); err == nil {
		t.Fatal("invalid fixture bind accepted")
	}
	// Require rejection by live assignment, not just the documentation policy.
	found := false
	for _, value := range []string{"10.252.254.254", "172.31.254.254", "192.168.254.254"} {
		address := netip.MustParseAddr(value)
		if validateHostLocalAddress(address) == nil {
			continue
		}
		found = true
		if _, err := newFixtureAt(address); err == nil {
			t.Fatal("unassigned private bind accepted")
		}
		b := &hostLocalBind{address: address}
		if _, err := b.ParseEndpoint(value + ":1234"); err == nil {
			t.Fatal("unassigned private endpoint accepted")
		}
		break
	}
	if !found {
		t.Fatal("No unassigned private address candidate")
	}
}

func TestFixtureSendRejectsDifferentHostAddress(t *testing.T) {
	b := &hostLocalBind{}
	if _, _, err := b.Open(0); err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	for _, value := range []string{"203.0.113.1:1234", "127.0.0.2:1234", serverIP + ":1234"} {
		endpoint := &conn.StdNetEndpoint{AddrPort: netip.MustParseAddrPort(value)}
		if err := b.Send([][]byte{{1}}, endpoint); err == nil {
			t.Fatal("send to a different address accepted")
		}
	}
	if err := b.Send([][]byte{{1}}, nil); err == nil {
		t.Fatal("nil endpoint accepted")
	}
	if address, ok := existingPrivateHostIPv4(); ok {
		selected := &hostLocalBind{address: address}
		if _, err := selected.ParseEndpoint("127.0.0.1:1234"); err == nil {
			t.Fatal("configured host bind accepted loopback destination")
		}
		if _, err := selected.ParseEndpoint(address.String() + ":1234"); err != nil {
			t.Fatal(err)
		}
	}
}
