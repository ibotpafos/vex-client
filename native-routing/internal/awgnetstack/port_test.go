package netstack

import (
	"context"
	"errors"
	"net"
	"testing"
)

// Cancellation prevents any packet I/O after parsing a literal test address.
// Keep Atoi's accepted signed-zero/positive and leading-zero forms compatible.
func TestDialContextNumericPortBounds(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	network := &Net{hasV4: true, hasV6: true}
	for _, family := range []struct{ network, host string }{
		{"tcp4", "192.0.2.1"}, {"udp6", "2001:db8::1"},
	} {
		for _, port := range []string{"0", "-0", "+0", "+1", "00080", "32768", "65535", "+65535"} {
			t.Run(family.network+"/valid/"+port, func(t *testing.T) {
				conn, err := network.DialContext(ctx, family.network, net.JoinHostPort(family.host, port))
				if conn != nil || !errors.Is(err, errCanceled) {
					t.Fatalf("valid numeric port must reach cancellation, got connection=%v error=%v", conn, err)
				}
			})
		}
		for _, port := range []string{"", "-1", "65536", "4294967296", "18446744073709551616", "https", " 80", "1.0"} {
			t.Run(family.network+"/invalid/"+port, func(t *testing.T) {
				conn, err := network.DialContext(ctx, family.network, net.JoinHostPort(family.host, port))
				if conn != nil || !errors.Is(err, errNumericPort) {
					t.Fatalf("invalid numeric port must fail before dialing, got connection=%v error=%v", conn, err)
				}
			})
		}
	}
}
