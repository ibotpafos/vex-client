package routing

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"testing"
	"time"
)

// An error may carry a typed nil (e.g. *gonet.TCPConn) through net.Conn.
// Calling any method on it can crash the native Android process.
type failedQualifiedConn struct{ net.Conn }

var failedQualifiedClose = make(chan struct{}, 1)

func (*failedQualifiedConn) Close() error { failedQualifiedClose <- struct{}{}; return nil }

func TestQualifiedDialCancellationDoesNotCloseFailedTypedNil(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	first := netip.MustParseAddr("1.1.1.1")
	second := netip.MustParseAddr("8.8.8.8")
	client, peer := net.Pipe()
	defer client.Close()
	defer peer.Close()
	failedReturned := make(chan struct{})
	dial := func(ctx context.Context, _, address string) (net.Conn, error) {
		if address == netip.AddrPortFrom(first, 443).String() {
			<-ctx.Done()
			defer close(failedReturned)
			var connection *failedQualifiedConn
			return connection, errors.New("dial canceled")
		}
		return client, nil
	}
	got, err := dialQualifiedAddresses(ctx, dial, []netip.Addr{first, second}, 443)
	if err != nil || got != client {
		t.Fatalf("winner not retained: %v", err)
	}
	select {
	case <-failedReturned:
	case <-ctx.Done():
		t.Fatal("losing dial not canceled")
	}
	select {
	case <-failedQualifiedClose:
		t.Fatal("method called on failed typed-nil connection")
	case <-time.After(100 * time.Millisecond):
	}
}

func TestQualifiedDialClosesSuccessfulLoser(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	started := make(chan struct{}, 2)
	release := make(chan struct{})
	closed := make(chan net.Conn, 2)
	dial := func(context.Context, string, string) (net.Conn, error) {
		a, b := net.Pipe()
		t.Cleanup(func() { a.Close(); b.Close() })
		started <- struct{}{}
		<-release
		return &qualifiedTrackedConn{Conn: a, closed: closed}, nil
	}
	done := make(chan net.Conn, 1)
	go func() {
		c, err := dialQualifiedAddresses(ctx, dial, []netip.Addr{netip.MustParseAddr("1.1.1.1"), netip.MustParseAddr("8.8.8.8")}, 443)
		if err == nil {
			done <- c
		}
	}()
	for range 2 {
		select {
		case <-started:
		case <-ctx.Done():
			t.Fatal("both dials did not start")
		}
	}
	close(release)
	var winner net.Conn
	select {
	case winner = <-done:
	case <-ctx.Done():
		t.Fatal("winner missing")
	}
	select {
	case loser := <-closed:
		if loser == winner {
			t.Fatal("winner closed")
		}
	case <-ctx.Done():
		t.Fatal("successful losing connection leaked")
	}
	winner.Close()
}

type qualifiedTrackedConn struct {
	net.Conn
	closed chan net.Conn
}

func (c *qualifiedTrackedConn) Close() error { c.closed <- c; return c.Conn.Close() }
