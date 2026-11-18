package routing

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// Google DoH has a fixed bootstrap address and normal TLS hostname verification.
// No redirect, plaintext fallback or system resolver can escape classification.
func DirectDoH(dial DialFunc) DNSExchangeFunc {
	transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		if dial == nil {
			return nil, errors.New("routing DNS binder missing")
		}
		return dialQualifiedAddresses(ctx, dial, []netip.Addr{netip.MustParseAddr("8.8.8.8"), netip.MustParseAddr("2001:4860:4860::8888")}, 443)
	}, TLSHandshakeTimeout: 3 * time.Second, DisableKeepAlives: true}
	client := &http.Client{Transport: transport, Timeout: 5 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("routing DNS redirect prohibited") }}
	return func(ctx context.Context, query []byte) ([]byte, error) {
		request, err := http.NewRequestWithContext(ctx, "POST", "https://dns.google/dns-query", bytes.NewReader(query))
		if err != nil {
			return nil, err
		}
		request.Header.Set("Content-Type", "application/dns-message")
		request.Header.Set("Accept", "application/dns-message")
		response, err := client.Do(request)
		if err != nil {
			return nil, err
		}
		defer response.Body.Close()
		if response.StatusCode != 200 {
			return nil, errors.New("routing DNS response invalid")
		}
		body, err := io.ReadAll(io.LimitReader(response.Body, 65536))
		if err != nil || len(body) > 65535 {
			return nil, errors.New("routing DNS response too large")
		}
		return body, nil
	}
}

func exchangeDNSStream(ctx context.Context, dial func(context.Context, netip.AddrPort) (net.Conn, error), server netip.Addr, query []byte) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	var err error
	for attempt := 0; attempt < 2; attempt++ {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		var answer []byte
		answer, err = exchangeDNSStreamOnce(ctx, dial, server, query)
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if err == nil {
			return answer, nil
		}
		// RFC 7766 section 6.2.4: retry an unanswered query after early close.
		// Both attempts use the same encrypted dialler, DNS address and deadline.
		if !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
			return nil, err
		}
	}
	return nil, err
}

func exchangeDNSStreamOnce(ctx context.Context, dial func(context.Context, netip.AddrPort) (net.Conn, error), server netip.Addr, query []byte) ([]byte, error) {
	connection, err := dial(ctx, netip.AddrPortFrom(server, 53))
	if err != nil {
		return nil, err
	}
	defer connection.Close()
	stopCancel := context.AfterFunc(ctx, func() { connection.Close() })
	defer stopCancel()
	deadline, _ := ctx.Deadline()
	if err := connection.SetDeadline(deadline); err != nil {
		return nil, err
	}
	framed := make([]byte, 2+len(query))
	binary.BigEndian.PutUint16(framed[:2], uint16(len(query)))
	copy(framed[2:], query)
	if n, err := connection.Write(framed); err != nil {
		return nil, err
	} else if n != len(framed) {
		return nil, io.ErrShortWrite
	}
	var length [2]byte
	if _, err := io.ReadFull(connection, length[:]); err != nil {
		return nil, err
	}
	answer := make([]byte, binary.BigEndian.Uint16(length[:]))
	_, err = io.ReadFull(connection, answer)
	return answer, err
}

func (r *Router) dnsExchange(query []byte) ([]byte, error) {
	var request dnsmessage.Message
	if len(query) > 65535 || request.Unpack(query) != nil || request.Response || request.OpCode != 0 || len(request.Questions) != 1 {
		return nil, errors.New("routing DNS query invalid")
	}
	question := request.Questions[0]
	name, valid := canonicalName(question.Name.String())
	if !valid || question.Class != dnsmessage.ClassINET {
		return nil, errors.New("routing DNS question invalid")
	}
	policy := r.policy.Load()
	control := controlDomain(name)
	direct := control || policy.DirectDomain(name, r.now())
	// HTTPS/SVCB IP hints could bypass fake-address identity. Empty answers ask
	// the application to use the controlled A/AAAA path for DIRECT names.
	if direct && (question.Type == 64 || question.Type == 65) {
		empty := dnsmessage.Message{Header: dnsmessage.Header{ID: request.ID, Response: true, RecursionDesired: request.RecursionDesired, RecursionAvailable: true}, Questions: request.Questions}
		return empty.Pack()
	}
	ctx, cancel := context.WithTimeout(r.ctx, 5*time.Second)
	defer cancel()
	var answer []byte
	var err error
	if direct {
		if r.directDNS == nil {
			return nil, errors.New("routing direct DNS unavailable")
		}
		physical, cancelPhysical, underlay := r.physicalContext(ctx)
		defer cancelPhysical()
		if physical.Err() != nil || underlay.Err() != nil {
			return nil, errors.New("routing DNS network retired")
		}
		answer, err = r.directDNS(physical, query)
		// Serialize admission with network retirement, including recovery names
		// that intentionally do not require a current country policy.
		r.activeMu.Lock()
		defer r.activeMu.Unlock()
		if physical.Err() != nil || underlay.Err() != nil {
			return nil, errors.New("routing DNS network retired")
		}
	} else {
		// Failure remains inside AWG; never retry a foreign name with direct DNS.
		if r.transportStopped.Load() {
			return nil, errors.New("routing encrypted DNS unavailable")
		}
		answer, err = exchangeDNSStream(ctx, func(ctx context.Context, address netip.AddrPort) (net.Conn, error) {
			return r.net.DialContextTCPAddrPort(ctx, address)
		}, r.dns[0], query)
	}
	if err != nil {
		return nil, err
	}
	var response dnsmessage.Message
	if response.Unpack(answer) != nil || !response.Response || response.ID != request.ID || response.Truncated || len(response.Questions) != 1 || response.Questions[0] != question {
		return nil, errors.New("routing DNS answer invalid")
	}
	if !direct {
		return answer, nil
	}
	if !control && (policy != r.policy.Load() || !policy.valid(r.now())) {
		return nil, errors.New("routing DNS authority changed")
	}
	response.AuthenticData = false // Fake addresses are local data, not DNSSEC answers.
	response.Authorities, response.Additionals = nil, nil
	if len(response.Answers) > 64 {
		return nil, errors.New("routing DNS answer count invalid")
	}
	for i := range response.Answers {
		resource := &response.Answers[i]
		ttl := time.Duration(resource.Header.TTL) * time.Second
		if ttl > 5*time.Minute {
			ttl = 5 * time.Minute
		}
		if ttl < time.Second {
			ttl = time.Second
		}
		deadline := r.now().Add(ttl)
		if !control && deadline.After(policy.ExpiresAt()) {
			deadline = policy.ExpiresAt()
		}
		resource.Header.TTL = uint32(deadline.Sub(r.now()) / time.Second)
		var actual netip.Addr
		switch body := resource.Body.(type) {
		case *dnsmessage.AResource:
			actual = netip.AddrFrom4(body.A)
		case *dnsmessage.AAAAResource:
			actual = netip.AddrFrom16(body.AAAA)
		case *dnsmessage.CNAMEResource:
			continue
		default:
			continue
		}
		if !publicDestination(actual) {
			return nil, errors.New("routing DNS private destination prohibited")
		}
		version := controlMappingVersion
		if !control {
			version = policy.Version()
		}
		fake, err := r.fakes.put(name, actual, deadline, version, r.now())
		if err != nil {
			return nil, err
		}
		if actual.Is4() {
			resource.Body = &dnsmessage.AResource{A: fake.As4()}
		} else {
			resource.Body = &dnsmessage.AAAAResource{AAAA: fake.As16()}
		}
	}
	return response.Pack()
}

func dnsFailure(query []byte) []byte {
	var request dnsmessage.Message
	if request.Unpack(query) != nil {
		return nil
	}
	failure := dnsmessage.Message{Header: dnsmessage.Header{ID: request.ID, Response: true, RCode: dnsmessage.RCodeServerFailure}, Questions: request.Questions}
	answer, _ := failure.Pack()
	return answer
}

// UDP clients do not signal socket close. Reclaim idle DNS mappings promptly
// so completed lookups cannot hold the shared application flow budget for 30s.
const dnsDatagramIdleTimeout = time.Second

func (r *Router) serveDNSDatagrams(client net.Conn) {
	query := make([]byte, 65536)
	for {
		client.SetReadDeadline(time.Now().Add(dnsDatagramIdleTimeout))
		n, err := client.Read(query)
		if err != nil {
			return
		}
		answer, err := r.dnsExchange(query[:n])
		if err != nil {
			answer = dnsFailure(query[:n])
		}
		if len(answer) == 0 {
			continue
		}
		if _, err := client.Write(answer); err != nil {
			return
		}
	}
}

func (r *Router) serveDNSStream(client net.Conn) {
	var length [2]byte
	for {
		client.SetDeadline(r.now().Add(30 * time.Second))
		if _, err := io.ReadFull(client, length[:]); err != nil {
			return
		}
		query := make([]byte, binary.BigEndian.Uint16(length[:]))
		if _, err := io.ReadFull(client, query); err != nil {
			return
		}
		answer, err := r.dnsExchange(query)
		if err != nil {
			answer = dnsFailure(query)
		}
		if len(answer) == 0 {
			return
		}
		binary.BigEndian.PutUint16(length[:], uint16(len(answer)))
		if _, err := client.Write(append(length[:], answer...)); err != nil {
			return
		}
	}
}
