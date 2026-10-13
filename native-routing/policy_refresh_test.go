package routing

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"sync/atomic"
	"testing"
	"time"
)

// Isolated distribution fixture, restored after each test. These tests are
// deliberately not parallel: production always uses the embedded public ring.
func fixturePolicySigner(t *testing.T) func(Policy) Authorization {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	public, _ := x509.MarshalPKIXPublicKey(&key.PublicKey)
	original := policySigningKeysJSON
	policySigningKeysJSON, _ = json.Marshal(map[string]any{
		"schema": "vex.profile-signing-keyring.v1",
		"keys":   []map[string]string{{"key_id": "fixture", "algorithm": "ECDSA_P256_SHA256_DER", "subject_public_key_info_base64": base64.StdEncoding.EncodeToString(public)}},
	})
	t.Cleanup(func() { policySigningKeysJSON = original })
	return func(policy Policy) Authorization {
		payload, _ := json.Marshal(policy)
		digest := sha256.Sum256(payload)
		signature, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
		if err != nil {
			t.Fatal(err)
		}
		return Authorization{"fixture", "ECDSA_P256_SHA256_DER", base64.RawURLEncoding.EncodeToString(payload), base64.RawURLEncoding.EncodeToString(signature)}
	}
}

func TestStartupKeepsReplayFloorWithoutCurrentAuthority(t *testing.T) {
	now := time.Now().UTC()
	sign := fixturePolicySigner(t)
	previous := testPolicy(now)
	previous.IssuedAt = now.Add(-2 * time.Hour)
	previous.SourceUpdatedAt = now.Add(-3 * time.Hour)
	previous.ExpiresAt = now.Add(-time.Hour)
	cache := sign(previous)
	for _, mode := range []string{"all_except_ru", "full_tunnel"} {
		wire, _ := json.Marshal(Parameters{Addresses: []string{"10.123.0.2/32"}, DNS: []string{"1.1.1.1"}, Mode: mode, PreviousAuthorization: &cache})
		options, _, active, err := AdmitParameters(wire, "android", now, time.Time{})
		if err != nil || active || options.Policy != nil || !options.HighWater.Equal(previous.IssuedAt) {
			t.Fatalf("%s lost the verified replay floor: active=%v err=%v", mode, active, err)
		}
		router, _, err := Attach(newFixtureTUN(), options)
		if err != nil {
			t.Fatal(err)
		}
		older := testPolicy(now)
		older.IssuedAt = now.Add(-3 * time.Hour)
		older.SourceUpdatedAt = now.Add(-4 * time.Hour)
		if err := router.AcceptAuthorization(sign(older)); err == nil {
			t.Fatal("old refresh admitted after restart")
		}
		router.Close()
	}
}

func TestRefreshFailureAndClockExpiryKeepCapture(t *testing.T) {
	now := time.Now().UTC()
	value := testPolicy(now)
	policy, err := CompilePolicy(value, now)
	if err != nil {
		t.Fatal(err)
	}
	var clock atomic.Int64
	clock.Store(now.UnixNano())
	refreshed := make(chan struct{}, 1)
	router, _, err := Attach(newFixtureTUN(), Options{
		Addresses: []netip.Addr{netip.MustParseAddr("10.123.0.2")},
		DNS:       []netip.Addr{netip.MustParseAddr("1.1.1.1")},
		Mode:      "all_except_ru", Platform: "android", Policy: policy,
		Now: func() time.Time { return time.Unix(0, clock.Load()) },
		PolicySource: func(context.Context) (Authorization, error) {
			refreshed <- struct{}{}
			return Authorization{}, errors.New("isolated refresh failure")
		},
		DirectDial: func(context.Context, string, string) (net.Conn, error) { return nil, errors.New("fixture") },
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { router.Close() })
	select {
	case <-refreshed:
	case <-time.After(time.Second):
		t.Fatal("background refresh did not run")
	}
	if !router.DirectPolicyActive() || !router.CaptureActive() {
		t.Fatal("refresh error revoked still-valid authority/capture")
	}
	connection, peer := net.Pipe()
	defer peer.Close()
	router.activeMu.Lock()
	router.directConnections[connection] = struct{}{}
	router.activeMu.Unlock()
	clock.Store(now.Add(2 * time.Hour).UnixNano())
	peer.SetReadDeadline(time.Now().Add(2500 * time.Millisecond))
	if _, err := peer.Read(make([]byte, 1)); !errors.Is(err, io.EOF) {
		t.Fatal("expired direct flow stayed open", err)
	}
	if router.policy.Load() != nil || !router.CaptureActive() {
		t.Fatal("expiry released capture or kept authority")
	}
	router.StopTransport()
	if !router.CaptureActive() {
		t.Fatal("encrypted transport stop released capture")
	}
}

func TestFakeMappingsReclaimMemoryWithoutReusingIdentity(t *testing.T) {
	now := time.Now()
	table := newFakeTable()
	actual := netip.MustParseAddr("104.16.10.10")
	var old netip.Addr
	for i := 0; i < maxFakeMappings; i++ {
		ip, err := table.put(fmt.Sprintf("site%d.ru", i), actual, now.Add(time.Second), "generation", now)
		if err != nil {
			t.Fatal(err)
		}
		if i == 0 {
			old = ip
		}
	}
	next, err := table.put("new.ru", actual, now.Add(time.Minute), "generation", now.Add(2*time.Second))
	if err != nil || next == old || !fakeV4.Contains(next) || len(table.byIP) != 1 || len(table.byKey) != 1 {
		t.Fatal("expired capacity was not reclaimed safely", err)
	}
	if _, ok := table.get(old, nil, now.Add(2*time.Second)); ok {
		t.Fatal("old fake identity was reassigned")
	}
	table.next = 1 << 17
	if _, err := table.put("limit.ru", actual, now.Add(time.Minute), "generation", now); err == nil {
		t.Fatal("fake IPv4 allocation left reserved space")
	}
}
