//go:build windows

package routing

import (
	"errors"
	"golang.org/x/sys/windows"
	"math/bits"
	"syscall"
)

func BindPhysicalSocket(fd, interfaceIndex int) error {
	if interfaceIndex <= 0 {
		return errors.New("routing physical interface unavailable")
	}
	address, err := syscall.Getsockname(syscall.Handle(fd))
	if err != nil {
		return err
	}
	switch address.(type) {
	case *syscall.SockaddrInet4:
		return windows.SetsockoptInt(windows.Handle(fd), windows.IPPROTO_IP, 31 /* IP_UNICAST_IF */, int(bits.ReverseBytes32(uint32(interfaceIndex))))
	case *syscall.SockaddrInet6:
		return windows.SetsockoptInt(windows.Handle(fd), windows.IPPROTO_IPV6, 31 /* IPV6_UNICAST_IF */, interfaceIndex)
	default:
		return errors.New("routing socket family invalid")
	}
}
