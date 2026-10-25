package netstack

import (
	"fmt"
	"net/netip"
	"os"
	"runtime"
	"sync"
	"testing"
	"time"

	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
)

func testNetTUN(t *testing.T) *netTun {
	t.Helper()
	device, _, err := CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.44.0.1")}, nil, 1360)
	if err != nil {
		t.Fatal(err)
	}
	return device.(*netTun)
}

func writeTestPacket(tun *netTun) {
	packet := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData([]byte{0x45, 0, 0, 20})})
	defer packet.DecRef()
	var packets stack.PacketBufferList
	packets.PushBack(packet)
	tun.ep.WritePackets(packets)
}

func TestCloseUnblocksPendingNotification(t *testing.T) {
	tun := testNetTUN(t)
	// Queue one packet without triggering the callback, then enter WriteNotify
	// without a reader. Queue removal proves the sender is already in flight.
	tun.ep.RemoveNotify(tun.notifyHandle)
	writeTestPacket(tun)
	finished := make(chan error, 1)
	go func() {
		defer func() {
			if p := recover(); p != nil {
				finished <- fmt.Errorf("notification panic: %v", p)
			} else {
				finished <- nil
			}
		}()
		tun.WriteNotify()
	}()
	deadline := time.Now().Add(2 * time.Second)
	for tun.ep.NumQueued() != 0 {
		if time.Now().After(deadline) {
			t.Fatal("notification never consumed queued packet")
		}
		runtime.Gosched()
	}
	if err := tun.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-finished:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Close left a blocked notification")
	}
	if _, err := tun.Read([][]byte{make([]byte, 64)}, []int{0}, 0); err != os.ErrClosed {
		t.Fatalf("closed reader: %v", err)
	}
}

func TestConcurrentCloseAndPacketDelivery(t *testing.T) {
	tun := testNetTUN(t)
	var producers sync.WaitGroup
	firstRead := make(chan struct{})
	readerDone := make(chan struct{})
	go func() {
		defer close(readerDone)
		var once sync.Once
		for {
			if _, err := tun.Read([][]byte{make([]byte, 64)}, []int{0}, 0); err != nil {
				return
			}
			once.Do(func() { close(firstRead) })
		}
	}()
	for k := 0; k < 8; k++ {
		producers.Add(1)
		go func() {
			defer producers.Done()
			for n := 0; n < 64; n++ {
				writeTestPacket(tun)
			}
		}()
	}
	select {
	case <-firstRead:
	case <-time.After(2 * time.Second):
		t.Fatal("no packet delivered before shutdown")
	}
	if err := tun.Close(); err != nil {
		t.Fatal(err)
	}
	producers.Wait()
	select {
	case <-readerDone:
	case <-time.After(2 * time.Second):
		t.Fatal("closed reader remained blocked")
	}
	if err := tun.Close(); err != nil {
		t.Fatal(err)
	}
	tun.WriteNotify()
}
