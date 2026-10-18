// Package routing implements destination routing independently of AWG peer
// configuration. It never falls back from a tunnel dial to a physical dial.
package routing

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/netip"
	"regexp"
	"sort"
	"strings"
	"time"
)

const (
	Schema          = "vex-routing-policy/v2"
	MaxCIDRs        = 32768
	MaxDomains      = 2048
	MaxPayloadBytes = 1 << 20
)

type DomainRule struct {
	Type  string `json:"type"`
	Value string `json:"value"`
}

type Policy struct {
	Schema          string       `json:"schema"`
	Version         string       `json:"version"`
	Region          string       `json:"region"`
	Platform        string       `json:"platform"`
	IssuedAt        time.Time    `json:"issued_at"`
	ExpiresAt       time.Time    `json:"expires_at"`
	SourceUpdatedAt time.Time    `json:"source_updated_at"`
	BypassRanges    []string     `json:"bypass_ranges"`
	DomainRules     []DomainRule `json:"domain_rules"`
}

type Authorization struct {
	KeyID           string `json:"key_id"`
	Algorithm       string `json:"algorithm"`
	PayloadBase64   string `json:"payload_base64"`
	SignatureBase64 string `json:"signature_base64"`
}

// CompiledPolicy is immutable. Its fields are private so a caller cannot claim
// that arbitrary, unsigned destinations have already passed admission.
type CompiledPolicy struct {
	policy   Policy
	v4, v6   []addressRange
	exact    map[string]struct{}
	suffix   map[string]struct{}
	keywords []string
	patterns []*regexp.Regexp
}

// Sorted, disjoint intervals bound policy memory by CIDR count rather than
// allocating up to 128 trie nodes per IPv6 entry inside a packet extension.
type addressRange struct{ first, last netip.Addr }

func prefixRange(p netip.Prefix) addressRange {
	bits := p.Addr().As16()
	start := p.Bits()
	if p.Addr().Is4() {
		start += 96
	}
	for i := start; i < 128; i++ {
		bits[i/8] |= 1 << (7 - i%8)
	}
	return addressRange{p.Addr(), netip.AddrFrom16(bits).Unmap()}
}

func compactRanges(values []addressRange) []addressRange {
	sort.Slice(values, func(i, j int) bool { return values[i].first.Compare(values[j].first) < 0 })
	out := values[:0]
	for _, value := range values {
		if len(out) > 0 && value.first.Compare(out[len(out)-1].last.Next()) <= 0 {
			if value.last.Compare(out[len(out)-1].last) > 0 {
				out[len(out)-1].last = value.last
			}
		} else {
			out = append(out, value)
		}
	}
	return out
}

func containsAddress(values []addressRange, addr netip.Addr) bool {
	i := sort.Search(len(values), func(i int) bool { return values[i].first.Compare(addr) > 0 }) - 1
	return i >= 0 && addr.Compare(values[i].last) <= 0
}

func VerifyPolicy(auth Authorization, keys map[string][]byte, platform string, now, highWater time.Time) (*CompiledPolicy, error) {
	policy, err := verifiedPolicyPayload(auth, keys)
	if err != nil {
		return nil, err
	}
	if policy.Platform != platform || policy.IssuedAt.Before(highWater) {
		return nil, errors.New("routing scope or replay invalid")
	}
	return CompilePolicy(policy, now)
}

func verifiedPolicyPayload(auth Authorization, keys map[string][]byte) (Policy, error) {
	fail := func(message string) (Policy, error) { return Policy{}, errors.New(message) }
	if auth.Algorithm != "ECDSA_P256_SHA256_DER" || len(auth.PayloadBase64) > 4*MaxPayloadBytes/3+8 {
		return fail("routing authorization invalid")
	}
	der, ok := keys[auth.KeyID]
	if !ok {
		return fail("routing signing key unknown")
	}
	key, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return fail("routing signing key invalid")
	}
	pub, ok := key.(*ecdsa.PublicKey)
	if !ok || pub.Curve.Params().Name != "P-256" {
		return fail("routing signing key invalid")
	}
	payload, err := base64.RawURLEncoding.Strict().DecodeString(auth.PayloadBase64)
	if err != nil || len(payload) > MaxPayloadBytes {
		return fail("routing payload invalid")
	}
	signature, err := base64.RawURLEncoding.Strict().DecodeString(auth.SignatureBase64)
	sum := sha256.Sum256(payload)
	if err != nil || !ecdsa.VerifyASN1(pub, sum[:], signature) {
		return fail("routing signature invalid")
	}
	if err := rejectDuplicateJSONKeys(payload); err != nil {
		return Policy{}, err
	}
	var policy Policy
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&policy); err != nil {
		return fail("routing payload fields invalid")
	}
	if decoder.Decode(new(any)) != io.EOF {
		return fail("routing payload trailing data")
	}
	return policy, nil
}

// An expired, previously admitted signature can still prove a replay floor.
// It cannot authorize traffic. Untrusted cache timestamps are never used.
func policyReplayFloor(auth Authorization, keys map[string][]byte, platform string, now time.Time) time.Time {
	policy, err := verifiedPolicyPayload(auth, keys)
	if err != nil || policy.Platform != platform || policy.IssuedAt.After(now.Add(5*time.Minute)) {
		return time.Time{}
	}
	if _, err := CompilePolicy(policy, policy.IssuedAt); err != nil {
		return time.Time{}
	}
	return policy.IssuedAt
}

func CompilePolicy(policy Policy, now time.Time) (*CompiledPolicy, error) {
	if policy.Schema != Schema || policy.Region != "ru" || len(policy.Version) != 64 || policy.Platform == "" ||
		policy.IssuedAt.After(now.Add(5*time.Minute)) || !policy.ExpiresAt.After(now) ||
		!policy.ExpiresAt.After(policy.IssuedAt) ||
		policy.ExpiresAt.Sub(policy.IssuedAt) > 24*time.Hour || policy.SourceUpdatedAt.IsZero() ||
		policy.ExpiresAt.After(policy.SourceUpdatedAt.Add(7*24*time.Hour)) ||
		policy.SourceUpdatedAt.After(now.Add(5*time.Minute)) || now.Sub(policy.SourceUpdatedAt) > 7*24*time.Hour ||
		len(policy.BypassRanges) == 0 || len(policy.BypassRanges) > MaxCIDRs || len(policy.DomainRules) > MaxDomains {
		return nil, errors.New("routing policy bounds or lifetime invalid")
	}
	if _, err := hex.DecodeString(policy.Version); err != nil {
		return nil, errors.New("routing version invalid")
	}
	out := &CompiledPolicy{policy: policy, exact: make(map[string]struct{}), suffix: make(map[string]struct{})}
	out.policy.BypassRanges = append([]string(nil), policy.BypassRanges...)
	out.policy.DomainRules = append([]DomainRule(nil), policy.DomainRules...)
	for _, value := range policy.BypassRanges {
		p, err := netip.ParsePrefix(value)
		if err != nil || p != p.Masked() || p.Bits() == 0 || !publicPrefix(p) {
			return nil, errors.New("routing prefix invalid")
		}
		if p.Addr().Is4() {
			out.v4 = append(out.v4, prefixRange(p))
		} else {
			out.v6 = append(out.v6, prefixRange(p))
		}
	}
	out.v4, out.v6 = compactRanges(out.v4), compactRanges(out.v6)
	for _, rule := range policy.DomainRules {
		if rule.Value == "" || len(rule.Value) > 253 || rule.Value != strings.ToLower(rule.Value) {
			return nil, errors.New("routing domain invalid")
		}
		switch rule.Type {
		case "exact", "suffix":
			name, valid := canonicalName(rule.Value)
			if !valid || name != rule.Value {
				return nil, errors.New("routing domain invalid")
			}
			if rule.Type == "exact" {
				out.exact[name] = struct{}{}
			} else {
				out.suffix[name] = struct{}{}
			}
		case "keyword":
			out.keywords = append(out.keywords, rule.Value)
		case "regex":
			pattern, err := regexp.Compile(rule.Value)
			if err != nil {
				return nil, errors.New("routing pattern invalid")
			}
			out.patterns = append(out.patterns, pattern)
		default:
			return nil, errors.New("routing domain type invalid")
		}
	}
	return out, nil
}

func (p *CompiledPolicy) Version() string      { return p.policy.Version }
func (p *CompiledPolicy) ExpiresAt() time.Time { return p.policy.ExpiresAt }
func (p *CompiledPolicy) IssuedAt() time.Time  { return p.policy.IssuedAt }
func (p *CompiledPolicy) valid(now time.Time) bool {
	return p != nil && !now.Before(p.policy.IssuedAt.Add(-5*time.Minute)) && now.Before(p.policy.ExpiresAt) && now.Sub(p.policy.SourceUpdatedAt) <= 7*24*time.Hour
}

func (p *CompiledPolicy) DirectIP(addr netip.Addr, now time.Time) bool {
	addr = addr.Unmap()
	if !p.valid(now) || !publicDestination(addr) {
		return false
	}
	if addr.Is4() {
		return containsAddress(p.v4, addr)
	}
	return containsAddress(p.v6, addr)
}

func (p *CompiledPolicy) DirectDomain(value string, now time.Time) bool {
	if !p.valid(now) {
		return false
	}
	name, valid := canonicalName(value)
	if !valid {
		return false
	}
	if _, ok := p.exact[name]; ok {
		return true
	}
	for suffix := name; suffix != ""; {
		if _, ok := p.suffix[suffix]; ok {
			return true
		}
		index := strings.IndexByte(suffix, '.')
		if index < 0 {
			break
		}
		suffix = suffix[index+1:]
	}
	for _, keyword := range p.keywords {
		if strings.Contains(name, keyword) {
			return true
		}
	}
	for _, pattern := range p.patterns {
		if pattern.MatchString(name) {
			return true
		}
	}
	return false
}

func canonicalName(value string) (string, bool) {
	name := strings.ToLower(strings.TrimSuffix(value, "."))
	if name == "" || len(name) > 253 {
		return "", false
	}
	for _, label := range strings.Split(name, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return "", false
		}
		for _, c := range label {
			if c != '-' && (c < 'a' || c > 'z') && (c < '0' || c > '9') {
				return "", false
			}
		}
	}
	return name, true
}

var nonPublicPrefixes = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"), netip.MustParsePrefix("10.0.0.0/8"), netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("127.0.0.0/8"), netip.MustParsePrefix("169.254.0.0/16"), netip.MustParsePrefix("172.16.0.0/12"),
	netip.MustParsePrefix("192.0.0.0/24"), netip.MustParsePrefix("192.0.2.0/24"), netip.MustParsePrefix("192.168.0.0/16"),
	netip.MustParsePrefix("198.18.0.0/15"), netip.MustParsePrefix("198.51.100.0/24"), netip.MustParsePrefix("203.0.113.0/24"),
	netip.MustParsePrefix("224.0.0.0/3"), netip.MustParsePrefix("::/96"), netip.MustParsePrefix("::ffff:0:0/96"),
	netip.MustParsePrefix("2001:db8::/32"), netip.MustParsePrefix("fc00::/7"), netip.MustParsePrefix("fe80::/10"), netip.MustParsePrefix("ff00::/8"),
}

func publicDestination(addr netip.Addr) bool {
	if !addr.IsValid() || addr.Is4In6() || !addr.IsGlobalUnicast() {
		return false
	}
	for _, reserved := range nonPublicPrefixes {
		if reserved.Contains(addr) {
			return false
		}
	}
	return true
}

func publicPrefix(prefix netip.Prefix) bool {
	if !publicDestination(prefix.Addr()) {
		return false
	}
	for _, reserved := range nonPublicPrefixes {
		if prefix.Overlaps(reserved) {
			return false
		}
	}
	return true
}

// Exact key checks precede parsing; encoding/json otherwise silently accepts
// duplicate fields, which creates different policy views in different clients.
func rejectDuplicateJSONKeys(payload []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(payload))
	depth := 0
	var visit func() error
	visit = func() error {
		token, err := decoder.Token()
		if err != nil {
			return err
		}
		delimiter, container := token.(json.Delim)
		if !container {
			return nil
		}
		depth++
		defer func() { depth-- }()
		if depth > 16 {
			return errors.New("routing JSON nesting invalid")
		}
		switch delimiter {
		case '{':
			seen := make(map[string]bool)
			for decoder.More() {
				token, err := decoder.Token()
				if err != nil {
					return err
				}
				key, ok := token.(string)
				if !ok || seen[key] {
					return errors.New("routing duplicate key")
				}
				seen[key] = true
				if err := visit(); err != nil {
					return err
				}
			}
		case '[':
			for decoder.More() {
				if err := visit(); err != nil {
					return err
				}
			}
		default:
			return errors.New("routing JSON invalid")
		}
		_, err = decoder.Token()
		return err
	}
	if err := visit(); err != nil {
		return errors.New("routing JSON invalid")
	}
	if _, err := decoder.Token(); err != io.EOF {
		return errors.New("routing JSON invalid")
	}
	return nil
}
