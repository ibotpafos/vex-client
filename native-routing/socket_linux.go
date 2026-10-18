//go:build linux

package routing

import (
	"encoding/binary"
	"errors"
	"golang.org/x/sys/unix"
)

// IP[_V6]_UNICAST_IF selects a physical oif without retaining CAP_NET_RAW
// after the dedicated UID drop. Both Linux options take network byte order:
// kernel net/{ipv4/ip,ipv6/ipv6}_sockglue.c. Failure never uses an unbound dial.
func BindPhysicalSocket(fd, index int) error {
	if index <= 0 {
		return errors.New("physical interface missing")
	}
	address, err := unix.Getsockname(fd)
	if err != nil {
		return err
	}
	var value [4]byte
	binary.BigEndian.PutUint32(value[:], uint32(index))
	interfaceValue := int(binary.NativeEndian.Uint32(value[:]))
	switch address.(type) {
	case *unix.SockaddrInet4:
		return unix.SetsockoptInt(fd, unix.IPPROTO_IP, unix.IP_UNICAST_IF, interfaceValue)
	case *unix.SockaddrInet6:
		return unix.SetsockoptInt(fd, unix.IPPROTO_IPV6, unix.IPV6_UNICAST_IF, interfaceValue)
	default:
		return errors.New("physical socket family invalid")
	}
}
