package routing

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/netip"
	"strings"
	"testing"
	"time"
)

func testPolicy(now time.Time) Policy {
	return Policy{Schema: Schema, Version: strings.Repeat("a", 64), Region: "ru", Platform: "android",
		IssuedAt: now.Add(-time.Minute), ExpiresAt: now.Add(time.Hour), SourceUpdatedAt: now.Add(-time.Hour),
		BypassRanges: []string{"77.88.8.0/24", "2a02:6b8::/32"}, DomainRules: []DomainRule{{"suffix", "ru"}, {"suffix", "su"}, {"suffix", "xn--p1ai"}, {"suffix", "yastatic.net"}, {"exact", "only.example.com"}}}
}

func signedPolicy(t *testing.T, payload []byte) (Authorization, map[string][]byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	pub, _ := x509.MarshalPKIXPublicKey(&key.PublicKey)
	digest := sha256.Sum256(payload)
	signature, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return Authorization{"fixture", "ECDSA_P256_SHA256_DER", base64.RawURLEncoding.EncodeToString(payload), base64.RawURLEncoding.EncodeToString(signature)}, map[string][]byte{"fixture": pub}
}

func TestVerifiedCompleteCountryPolicy(t *testing.T) {
	now := time.Now().UTC()
	policy := testPolicy(now)
	for i := 0; i < 10829; i++ {
		policy.BypassRanges = append(policy.BypassRanges, fmt.Sprintf("80.%d.%d.0/24", i/256, i%256))
	}
	payload, _ := json.Marshal(policy)
	auth, keys := signedPolicy(t, payload)
	verified, err := VerifyPolicy(auth, keys, "android", now, time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	for _, ip := range []string{"77.88.8.8", "2a02:6b8::1", "80.42.76.1"} {
		if !verified.DirectIP(netip.MustParseAddr(ip), now) {
			t.Fatalf("complete policy lost %s", ip)
		}
	}
	for _, ip := range []string{"8.8.8.8", "1.1.1.1", "10.0.0.1", "::1", "198.18.0.1"} {
		if verified.DirectIP(netip.MustParseAddr(ip), now) {
			t.Fatalf("unexpected direct %s", ip)
		}
	}
	for _, name := range []string{"gosuslugi.ru", "RU.", "assets.yastatic.net", "магазин.xn--p1ai", "only.example.com"} {
		if strings.Contains(name, "магазин") {
			name = "xn--80aairftm.xn--p1ai"
		}
		if !verified.DirectDomain(name, now) {
			t.Fatalf("missing Russian name %s", name)
		}
	}
	for _, name := range []string{"notru.com", "yastatic.net.evil.com", "evilru", "sub.only.example.com", "bad..ru", "bad/ru"} {
		if verified.DirectDomain(name, now) {
			t.Fatalf("suffix/exact semantics widened for %s", name)
		}
	}
}

func TestPolicyAdmissionRejectsTamperingReplayAndExpiry(t *testing.T) {
	now := time.Now().UTC()
	policy := testPolicy(now)
	payload, _ := json.Marshal(policy)
	auth, keys := signedPolicy(t, payload)
	for _, mutate := range []func(*Authorization){
		func(a *Authorization) { a.KeyID = "unknown" },
		func(a *Authorization) { a.Algorithm = "ECDSA" },
		func(a *Authorization) { a.PayloadBase64 = base64.RawURLEncoding.EncodeToString(append(payload, ' ')) },
		func(a *Authorization) { a.SignatureBase64 = "AAAA" },
	} {
		bad := auth
		mutate(&bad)
		if _, err := VerifyPolicy(bad, keys, "android", now, time.Time{}); err == nil {
			t.Fatal("tampering admitted")
		}
	}
	for _, args := range []struct {
		platform       string
		now, highWater time.Time
	}{
		{"ios", now, time.Time{}}, {"android", now.Add(2 * time.Hour), time.Time{}}, {"android", now, now},
	} {
		if _, err := VerifyPolicy(auth, keys, args.platform, args.now, args.highWater); err == nil {
			t.Fatal("scope/replay/expiry admitted")
		}
	}
	for _, bad := range []string{strings.Replace(string(payload), `"region":"ru"`, `"region":"ru","region":"ru"`, 1), strings.TrimSuffix(string(payload), "}") + `,"extra":true}`} {
		auth, keys := signedPolicy(t, []byte(bad))
		if _, err := VerifyPolicy(auth, keys, "android", now, time.Time{}); err == nil {
			t.Fatal("ambiguous/unknown fields admitted")
		}
	}
}

func TestSharedCDNMappingDoesNotExemptItsRealIP(t *testing.T) {
	now := time.Now().UTC()
	policy, err := CompilePolicy(testPolicy(now), now)
	if err != nil {
		t.Fatal(err)
	}
	table := newFakeTable()
	shared := netip.MustParseAddr("104.16.10.10")
	fake, err := table.put("shop.ru", shared, now.Add(time.Minute), policy.Version(), now)
	if err != nil {
		t.Fatal(err)
	}
	if policy.DirectIP(shared, now) {
		t.Fatal("shared CDN address authorized globally")
	}
	if actual, valid := table.get(fake, policy, now); !valid || actual != shared {
		t.Fatal("Russian flow lost hostname identity")
	}
	if _, valid := table.get(fake, policy, now.Add(2*time.Minute)); valid {
		t.Fatal("expired mapping admitted")
	}
	changed := testPolicy(now)
	changed.Version = strings.Repeat("b", 64)
	newPolicy, _ := CompilePolicy(changed, now)
	if _, valid := table.get(fake, newPolicy, now); valid {
		t.Fatal("revoked mapping admitted after policy update")
	}
	if _, valid := table.get(netip.MustParseAddr("198.18.22.22"), policy, now); valid {
		t.Fatal("unknown fake address admitted")
	}
}

func TestPolicyRejectsRangesOverlappingNonPublicSpace(t *testing.T) {
	now := time.Now()
	for _, prefix := range []string{"1.0.0.0/8", "8.0.0.0/5", "100.0.0.0/8", "192.0.0.0/8", "2000::/3", "::ffff:77.88.8.8/128"} {
		policy := testPolicy(now)
		policy.BypassRanges = []string{prefix}
		_, err := CompilePolicy(policy, now)
		// 1/8 is public. Other ranges are noncanonical or include reserved space.
		if prefix == "1.0.0.0/8" && err != nil {
			t.Fatal(err)
		}
		if prefix != "1.0.0.0/8" && err == nil {
			t.Fatalf("unsafe range %s admitted", prefix)
		}
	}
}
