package routing

import (
	"context"
	"net"
	"net/netip"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

func TestDNSDatagramIdleReclaimsCapacityAndReusedSocket(t *testing.T) {
	osTUN := newFixtureTUN()
	router, _, err := Attach(osTUN, Options{
		Addresses: []netip.Addr{netip.MustParseAddr("10.123.0.2")}, DNS: []netip.Addr{netip.MustParseAddr("1.1.1.1")}, MaxFlows: 2,
		DirectDNS: func(_ context.Context, query []byte) ([]byte, error) {
			var message dnsmessage.Message
			if err := message.Unpack(query); err != nil {
				return nil, err
			}
			message.Response = true
			message.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: message.Questions[0].Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 60},
				Body: &dnsmessage.AResource{A: [4]byte{104, 16, 10, 10}}}}
			return message.Pack()
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	client := connectFixture(t, router, osTUN)
	open := func() net.Conn {
		connection, err := client.DialUDPAddrPort(netip.AddrPort{}, netip.MustParseAddrPort("1.1.1.1:53"))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { connection.Close() })
		return connection
	}
	name, _ := dnsmessage.NewName("vexguard.app.")
	exchange := func(connection net.Conn, id uint16) {
		t.Helper()
		message := dnsmessage.Message{Header: dnsmessage.Header{ID: id}, Questions: []dnsmessage.Question{{Name: name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}}}
		query, _ := message.Pack()
		connection.SetDeadline(time.Now().Add(2 * time.Second))
		if _, err := connection.Write(query); err != nil {
			t.Fatal(err)
		}
		answer := make([]byte, 4096)
		n, err := connection.Read(answer)
		if err != nil {
			t.Fatal(err)
		}
		var response dnsmessage.Message
		if response.Unpack(answer[:n]) != nil || response.ID != id || !response.Response || len(response.Answers) != 1 {
			t.Fatal("DNS response invalid")
		}
	}
	for id := uint16(1); id <= 2; id++ {
		connection := open()
		exchange(connection, id)
		connection.Close()
	}
	if len(router.flowBudget) != 2 {
		t.Fatal("fixture did not occupy both DNS flow slots")
	}
	waitIdle := func() {
		t.Helper()
		deadline := time.Now().Add(3 * time.Second)
		for len(router.flowBudget) != 0 {
			if time.Now().After(deadline) {
				t.Fatal("idle DNS sockets continue to starve new application flows")
			}
			time.Sleep(5 * time.Millisecond)
		}
	}
	waitIdle()
	reused := open()
	exchange(reused, 3)
	waitIdle()
	// DNS is stateless: a later datagram on the same application socket must
	// create a fresh forwarded endpoint after its idle mapping was reclaimed.
	exchange(reused, 4)
}
