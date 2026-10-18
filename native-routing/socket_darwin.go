//go:build darwin || ios

package routing

import (
	"errors"
	"golang.org/x/sys/unix"
)

// An explicit physical interface is mandatory. Index zero cannot quietly use
// the default route or send unqualified traffic after a network transition.
func BindPhysicalSocket(fd, interfaceIndex int) error {
	if interfaceIndex <= 0 {
		return errors.New("routing physical interface unavailable")
	}
	address, err := unix.Getsockname(fd)
	if err != nil {
		return err
	}
	switch address.(type) {
	case *unix.SockaddrInet4:
		return unix.SetsockoptInt(fd, unix.IPPROTO_IP, unix.IP_BOUND_IF, interfaceIndex)
	case *unix.SockaddrInet6:
		return unix.SetsockoptInt(fd, unix.IPPROTO_IPV6, unix.IPV6_BOUND_IF, interfaceIndex)
	default:
		return errors.New("routing socket family invalid")
	}
}
