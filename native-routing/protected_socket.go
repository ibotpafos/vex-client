package routing

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"syscall"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
)

type SocketPurpose int

const (
	SocketTransport SocketPurpose = iota
	SocketDirect
	SocketDNS
)

type PrepareSocket func(fd int, purpose SocketPurpose) error

func ProtectedDialer(prepare PrepareSocket, purpose SocketPurpose) DialFunc {
	return func(ctx context.Context, protocol, address string) (net.Conn, error) {
		if prepare == nil {
			return nil, errors.New("routing socket protector missing")
		}
		if _, err := netip.ParseAddrPort(address); err != nil {
			return nil, errors.New("routing socket requires literal IP")
		}
		if protocol != "tcp" && protocol != "udp" {
			return nil, errors.New("routing socket protocol invalid")
		}
		dialer := net.Dialer{Timeout: 15 * time.Second, ControlContext: func(_ context.Context, _, _ string, raw syscall.RawConn) error {
			var result error
			if err := raw.Control(func(fd uintptr) { result = prepare(int(fd), purpose) }); err != nil {
				return err
			}
			return result
		}}
		return dialer.DialContext(ctx, protocol, address)
	}
}

// ProtectedBind qualifies every AWG transport socket, including sockets
// replaced by BindUpdate. The platform's later binding call is supplementary.
type ProtectedBind struct {
	conn.Bind
	prepare PrepareSocket
}

func NewProtectedBind(bind conn.Bind, prepare PrepareSocket) *ProtectedBind {
	return &ProtectedBind{bind, prepare}
}

func (b *ProtectedBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	functions, actualPort, err := b.Bind.Open(port)
	if err != nil {
		return nil, 0, err
	}
	peek, ok := b.Bind.(conn.PeekLookAtSocketFd)
	if !ok || b.prepare == nil {
		b.Bind.Close()
		return nil, 0, errors.New("routing transport protector unavailable")
	}
	prepared := 0
	for _, get := range []func() (int, error){peek.PeekLookAtSocketFd4, peek.PeekLookAtSocketFd6} {
		fd, err := get()
		if err != nil || fd < 0 {
			continue
		}
		if err := b.prepare(fd, SocketTransport); err != nil {
			b.Bind.Close()
			return nil, 0, err
		}
		prepared++
	}
	if prepared == 0 {
		b.Bind.Close()
		return nil, 0, errors.New("routing transport has no qualified sockets")
	}
	return functions, actualPort, nil
}

func (b *ProtectedBind) PeekLookAtSocketFd4() (int, error) {
	return b.Bind.(conn.PeekLookAtSocketFd).PeekLookAtSocketFd4()
}
func (b *ProtectedBind) PeekLookAtSocketFd6() (int, error) {
	return b.Bind.(conn.PeekLookAtSocketFd).PeekLookAtSocketFd6()
}
