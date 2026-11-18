package routing

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"time"
)

// These stable, non-sensitive codes also cross the Android JNI boundary.
const (
	DataPlaneVerified = iota
	DataPlaneDNSFailed
	DataPlaneHTTPSFailed
	DataPlaneRetired
)

type dataPlaneTarget struct{ host, path, format string }

// No caller-supplied URL, physical dialer, proxy, system resolver, cookies,
// authorization or persistent connections can enter this check. r.net is the
// AWG-side NetTUN, so even DIRECT domains and excluded app UIDs use this peer.
func (r *Router) VerifyDataPlane() int {
	ctx, cancel := context.WithTimeout(r.underlyingContext(), 12*time.Second)
	defer cancel()
	return r.verifyDataPlane(ctx, []dataPlaneTarget{
		{"one.one.one.one", "/cdn-cgi/trace", "trace"},
		{"api.ipify.org", "/?format=json", "json"},
	}, nil)
}

func (r *Router) verifyDataPlane(ctx context.Context, targets []dataPlaneTarget, trust *tls.Config) int {
	result := DataPlaneDNSFailed
	for _, target := range targets {
		if ctx.Err() != nil || r.transportStopped.Load() || !r.CaptureActive() {
			return DataPlaneRetired
		}
		// Two independent services share one bounded operation. Failure never
		// retries through the physical Internet or the DIRECT policy path.
		attempt, cancel := context.WithTimeout(ctx, 6*time.Second)
		dnsContext, cancelDNS := context.WithTimeout(attempt, 3*time.Second)
		resolved, err := r.net.LookupContextHost(dnsContext, target.host)
		cancelDNS()
		var addresses []netip.Addr
		if err == nil {
			for _, value := range resolved {
				if address, err := netip.ParseAddr(value); err == nil && publicDestination(address) {
					addresses = append(addresses, address)
				}
			}
		}
		if len(addresses) == 0 {
			cancel()
			continue
		}
		result = DataPlaneHTTPSFailed
		err = r.dataPlaneHTTPS(attempt, target, addresses, trust)
		if err == nil && attempt.Err() == nil && ctx.Err() == nil && !r.transportStopped.Load() && r.CaptureActive() {
			cancel()
			return DataPlaneVerified
		}
		cancel()
	}
	return result
}

func (r *Router) dataPlaneHTTPS(ctx context.Context, target dataPlaneTarget, addresses []netip.Addr, trust *tls.Config) error {
	transport := &http.Transport{
		Proxy: nil, DisableKeepAlives: true, TLSHandshakeTimeout: 3 * time.Second,
		TLSClientConfig: trust, MaxResponseHeaderBytes: 8192,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			if network != "tcp" || address != net.JoinHostPort(target.host, "443") || r.transportStopped.Load() {
				return nil, errors.New("data plane destination unavailable")
			}
			return dialQualifiedAddresses(ctx, func(ctx context.Context, _, address string) (net.Conn, error) {
				return r.net.DialContextTCPAddrPort(ctx, netip.MustParseAddrPort(address))
			}, addresses, 443)
		},
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error {
		return errors.New("data plane redirect prohibited")
	}}
	request, err := http.NewRequestWithContext(ctx, "GET", "https://"+target.host+target.path, nil)
	if err != nil {
		return err
	}
	request.Header.Set("Cache-Control", "no-cache, no-store")
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK || response.TLS == nil || len(response.TLS.VerifiedChains) == 0 {
		return errors.New("data plane HTTPS response not verified")
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 4097))
	if err != nil || len(body) > 4096 {
		return errors.New("data plane HTTPS body invalid")
	}
	var echo string
	if target.format == "json" {
		var value struct {
			IP string `json:"ip"`
		}
		if json.Unmarshal(body, &value) != nil {
			return errors.New("data plane HTTPS echo invalid")
		}
		echo = value.IP
	} else {
		for _, line := range strings.Split(string(body), "\n") {
			if strings.HasPrefix(line, "ip=") {
				echo = strings.TrimSpace(strings.TrimPrefix(line, "ip="))
			}
		}
	}
	ip, err := netip.ParseAddr(echo)
	if err != nil || !publicDestination(ip) {
		return errors.New("data plane HTTPS echo missing")
	}
	// The IP is deliberately not returned, logged or persisted.
	return nil
}
