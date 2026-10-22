package routing

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

type PolicySource func(context.Context) (Authorization, error)

// The distribution fixes the recovery origin. DNS and HTTPS use qualified
// sockets; neither the system resolver nor a redirect can broaden this scope.
func ProtectedPolicySource(dns DNSExchangeFunc, dial DialFunc, platform string) PolicySource {
	return func(ctx context.Context) (Authorization, error) {
		if dns == nil || dial == nil {
			return Authorization{}, errors.New("routing refresh protector missing")
		}
		name, _ := dnsmessage.NewName("vexguard.app.")
		var addresses []netip.Addr
		for _, kind := range []dnsmessage.Type{dnsmessage.TypeA, dnsmessage.TypeAAAA} {
			question := dnsmessage.Question{Name: name, Type: kind, Class: dnsmessage.ClassINET}
			query := dnsmessage.Message{Header: dnsmessage.Header{ID: 1, RecursionDesired: true}, Questions: []dnsmessage.Question{question}}
			wire, _ := query.Pack()
			answer, err := dns(ctx, wire)
			if err != nil {
				continue
			}
			var response dnsmessage.Message
			if response.Unpack(answer) != nil || !response.Response || response.ID != 1 || len(response.Questions) != 1 || response.Questions[0] != question || len(response.Answers) > 64 {
				continue
			}
			for _, value := range response.Answers {
				var addr netip.Addr
				switch body := value.Body.(type) {
				case *dnsmessage.AResource:
					addr = netip.AddrFrom4(body.A)
				case *dnsmessage.AAAAResource:
					addr = netip.AddrFrom16(body.AAAA)
				}
				if publicDestination(addr) {
					addresses = append(addresses, addr)
				}
			}
		}
		if len(addresses) == 0 {
			return Authorization{}, errors.New("routing refresh bootstrap unavailable")
		}
		transport := &http.Transport{DisableKeepAlives: true, TLSHandshakeTimeout: 5 * time.Second,
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return dialQualifiedAddresses(ctx, dial, addresses, 443)
			}}
		defer transport.CloseIdleConnections()
		client := &http.Client{Transport: transport, Timeout: 15 * time.Second,
			CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("routing refresh redirect prohibited") }}
		request, err := http.NewRequestWithContext(ctx, "GET", "https://vexguard.app/v1/vpn/routing-policy/public?platform="+platform, nil)
		if err != nil {
			return Authorization{}, err
		}
		response, err := client.Do(request)
		if err != nil {
			return Authorization{}, err
		}
		defer response.Body.Close()
		if response.StatusCode != http.StatusOK {
			return Authorization{}, errors.New("routing refresh unavailable")
		}
		wire, err := io.ReadAll(io.LimitReader(response.Body, 2*MaxPayloadBytes+1))
		if err != nil || len(wire) > 2*MaxPayloadBytes {
			return Authorization{}, errors.New("routing refresh too large")
		}
		if err := rejectDuplicateJSONKeys(wire); err != nil {
			return Authorization{}, err
		}
		var envelope struct {
			Authorization Authorization `json:"authorization"`
		}
		decoder := json.NewDecoder(strings.NewReader(string(wire)))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&envelope) != nil || decoder.Decode(new(any)) != io.EOF {
			return Authorization{}, errors.New("routing refresh envelope invalid")
		}
		return envelope.Authorization, nil
	}
}

// A small happy-eyeballs race supports IPv6-only physical networks as well as
// IPv4. Every attempt goes through the same mandatory native socket qualifier.
func dialQualifiedAddresses(ctx context.Context, dial DialFunc, addresses []netip.Addr, port uint16) (net.Conn, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	type result struct {
		conn net.Conn
		err  error
	}
	results := make(chan result)
	if len(addresses) > 8 {
		addresses = addresses[:8]
	}
	for i, address := range addresses {
		go func(i int, address netip.Addr) {
			timer := time.NewTimer(time.Duration(i) * 200 * time.Millisecond)
			defer timer.Stop()
			select {
			case <-ctx.Done():
				return
			case <-timer.C:
			}
			connection, err := dial(ctx, "tcp", netip.AddrPortFrom(address, port).String())
			select {
			case results <- result{connection, err}:
			case <-ctx.Done():
				if connection != nil {
					connection.Close()
				}
			}
		}(i, address)
	}
	for range addresses {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case value := <-results:
			if value.err == nil {
				return value.conn, nil
			}
		}
	}
	return nil, errors.New("routing qualified connection failed")
}

func (r *Router) AcceptAuthorization(auth Authorization) error {
	r.policyMu.Lock()
	defer r.policyMu.Unlock()
	if r.mode != "all_except_ru" {
		return errors.New("routing mode is full tunnel")
	}
	keys, err := TrustedPolicyKeys()
	if err != nil {
		return err
	}
	policy, err := VerifyPolicy(auth, keys, r.platform, r.now(), r.highWater)
	if err != nil {
		return err
	}
	r.UpdatePolicy(policy)
	r.highWater = policy.IssuedAt()
	r.authorization = &auth
	return nil
}

func (r *Router) AuthorizationJSON() string {
	r.policyMu.Lock()
	defer r.policyMu.Unlock()
	if r.authorization == nil {
		return ""
	}
	wire, _ := json.Marshal(r.authorization)
	return string(wire)
}

func (r *Router) UpdateParameters(raw []byte, platform string) (bool, error) {
	r.policyMu.Lock()
	defer r.policyMu.Unlock()
	options, _, active, err := AdmitParameters(raw, platform, r.now(), r.highWater)
	if err != nil {
		return false, err
	}
	// Interface/DNS belong to the admitted transport. A policy refresh cannot
	// change those values while AWG is using the existing virtual interface.
	if !sameAddresses(options.Addresses, r.addresses) || !sameAddresses(options.DNS, r.dns) {
		return false, errors.New("routing transport changed during policy update")
	}
	r.mode = options.Mode
	r.UpdatePolicy(options.Policy)
	if options.Policy != nil {
		r.highWater = options.Policy.IssuedAt()
		r.authorization = options.Authorization
	}
	return active, nil
}

func sameAddresses(a, b []netip.Addr) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func (r *Router) refreshPolicies(source PolicySource) {
	delay := time.Duration(0)
	underlay := r.underlyingContext()
	for {
		if r.ctx.Err() != nil {
			return
		}
		timer := time.NewTimer(delay)
		select {
		case <-r.ctx.Done():
			timer.Stop()
			return
		case <-underlay.Done():
			timer.Stop()
			underlay = r.underlyingContext()
			delay = 0
			continue
		case <-timer.C:
		}
		r.policyMu.Lock()
		enabled := r.mode == "all_except_ru"
		r.policyMu.Unlock()
		delay = 5 * time.Minute
		if !enabled {
			continue
		}
		ctx, cancel := context.WithTimeout(underlay, 20*time.Second)
		auth, err := source(ctx)
		cancel()
		if underlay.Err() != nil {
			continue
		}
		if err == nil && r.AcceptAuthorization(auth) == nil {
			delay = 6 * time.Hour
		}
	}
}
