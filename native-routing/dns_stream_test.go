package routing

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/netip"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

func dnsStreamMessages(t *testing.T) ([]byte, []byte, []byte) {
	t.Helper()
	name, err := dnsmessage.NewName("example.com.")
	if err != nil {
		t.Fatal(err)
	}
	message := dnsmessage.Message{Header: dnsmessage.Header{ID: 123, RecursionDesired: true},
		Questions: []dnsmessage.Question{{Name: name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}}}
	query, err := message.Pack()
	if err != nil {
		t.Fatal(err)
	}
	message.Response = true
	message.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 60},
		Body: &dnsmessage.AResource{A: [4]byte{93, 184, 216, 34}}}}
	answer, err := message.Pack()
	if err != nil {
		t.Fatal(err)
	}
	frame := make([]byte, 2+len(answer))
	binary.BigEndian.PutUint16(frame, uint16(len(answer)))
	copy(frame[2:], answer)
	return query, answer, frame
}

func dnsStreamFixture(t *testing.T, query []byte, handle func(int, net.Conn)) (func(context.Context, netip.AddrPort) (net.Conn, error), *atomic.Int32) {
	t.Helper()
	var calls atomic.Int32
	return func(ctx context.Context, target netip.AddrPort) (net.Conn, error) {
		if target != netip.MustParseAddrPort("10.64.0.1:53") {
			t.Errorf("DNS retry changed destination: %v", target)
		}
		attempt := int(calls.Add(1))
		client, server := net.Pipe()
		t.Cleanup(func() { client.Close(); server.Close() })
		go func() {
			defer server.Close()
			var length [2]byte
			if _, err := io.ReadFull(server, length[:]); err != nil {
				return
			}
			wire := make([]byte, binary.BigEndian.Uint16(length[:]))
			if _, err := io.ReadFull(server, wire); err != nil {
				return
			}
			if !bytes.Equal(wire, query) {
				t.Error("retry changed DNS question or transaction ID")
				return
			}
			handle(attempt, server)
		}()
		return client, nil
	}, &calls
}

func TestDNSStreamRetriesEarlyClose(t *testing.T) {
	// TODO(physical-qa): accept this retry in a signed Android client on Mi A1.
	// Stand login is restored. Standalone run-as socket probes did not establish
	// a qualified VPN path; only the updated APK can complete this acceptance.
	query, answer, frame := dnsStreamMessages(t)
	for label, partial := range map[string][]byte{"before_length": nil, "partial_length": frame[:1], "partial_body": frame[:7]} {
		t.Run(label, func(t *testing.T) {
			dial, calls := dnsStreamFixture(t, query, func(attempt int, connection net.Conn) {
				if attempt == 1 {
					connection.Write(partial)
				} else {
					connection.Write(frame)
				}
			})
			got, err := exchangeDNSStream(context.Background(), dial, netip.MustParseAddr("10.64.0.1"), query)
			if err != nil || !bytes.Equal(got, answer) || calls.Load() != 2 {
				t.Fatalf("unanswered DNS did not recover on one fresh connection: calls=%d err=%v", calls.Load(), err)
			}
		})
	}
}

func TestDNSStreamRetryLimit(t *testing.T) {
	query, _, _ := dnsStreamMessages(t)
	dial, calls := dnsStreamFixture(t, query, func(_ int, _ net.Conn) {})
	_, err := exchangeDNSStream(context.Background(), dial, netip.MustParseAddr("10.64.0.1"), query)
	if !errors.Is(err, io.EOF) || calls.Load() != 2 {
		t.Fatalf("expected two bounded attempts: calls=%d err=%v", calls.Load(), err)
	}
}

func TestDNSStreamDoesNotRetryCompleteResponse(t *testing.T) {
	query, _, _ := dnsStreamMessages(t)
	// Parsing and question/ID validation belong to dnsExchange. A complete but
	// invalid message must reach that validation without a transport retry.
	frame := []byte{0, 1, 0xff}
	dial, calls := dnsStreamFixture(t, query, func(_ int, connection net.Conn) { connection.Write(frame) })
	got, err := exchangeDNSStream(context.Background(), dial, netip.MustParseAddr("10.64.0.1"), query)
	if err != nil || !bytes.Equal(got, frame[2:]) || calls.Load() != 1 {
		t.Fatalf("complete response was changed or retried: calls=%d err=%v", calls.Load(), err)
	}
}

func TestDNSStreamDialFailureIsNotRetried(t *testing.T) {
	sentinel := errors.New("encrypted transport unavailable")
	var calls int
	_, err := exchangeDNSStream(context.Background(), func(context.Context, netip.AddrPort) (net.Conn, error) {
		calls++
		return nil, sentinel
	}, netip.MustParseAddr("10.64.0.1"), []byte{1})
	if !errors.Is(err, sentinel) || calls != 1 {
		t.Fatalf("dial failure handling changed: calls=%d err=%v", calls, err)
	}
}

func TestDNSStreamRetrySharesDeadlineAndCancelsRead(t *testing.T) {
	query, _, _ := dnsStreamMessages(t)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	secondRead := make(chan struct{})
	dial, calls := dnsStreamFixture(t, query, func(attempt int, connection net.Conn) {
		if attempt == 2 {
			close(secondRead)
			var b [1]byte
			connection.Read(b[:])
		}
	})
	var deadlines []time.Time
	checkedDial := func(ctx context.Context, target netip.AddrPort) (net.Conn, error) {
		deadline, ok := ctx.Deadline()
		if !ok {
			t.Error("DNS attempt has no deadline")
		}
		deadlines = append(deadlines, deadline)
		return dial(ctx, target)
	}
	done := make(chan error, 1)
	go func() {
		_, err := exchangeDNSStream(ctx, checkedDial, netip.MustParseAddr("10.64.0.1"), query)
		done <- err
	}()
	select {
	case <-secondRead:
		cancel()
	case err := <-done:
		t.Fatalf("retry never reached second connection: %v", err)
	case <-time.After(3 * time.Second):
		t.Fatal("second connection deadline")
	}
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) || calls.Load() != 2 || len(deadlines) != 2 || !deadlines[0].Equal(deadlines[1]) {
			t.Fatalf("cancellation or total deadline changed: calls=%d deadlines=%v err=%v", calls.Load(), deadlines, err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("cancelled DNS read remained blocked")
	}
}

func TestDNSStreamCancelledBeforeDial(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	var calls int
	_, err := exchangeDNSStream(ctx, func(context.Context, netip.AddrPort) (net.Conn, error) {
		calls++
		return nil, errors.New("must not dial")
	}, netip.MustParseAddr("10.64.0.1"), []byte{1})
	if !errors.Is(err, context.Canceled) || calls != 0 {
		t.Fatalf("cancelled query dialled: calls=%d err=%v", calls, err)
	}
}
