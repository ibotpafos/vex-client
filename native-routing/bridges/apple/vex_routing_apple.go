//go:build darwin || ios

package main

/*
#include <stdint.h>
#include <stdlib.h>
*/
import "C"

import (
	"math"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
	"github.com/amnezia-vpn/amneziawg-go/v3/device"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun"
	"golang.org/x/sys/unix"
	routing "vex.dev/native-routing"
)

type vexAppleRoutingHandle struct {
	router    *routing.Router
	index     atomic.Int64
	highWater time.Time
}

var vexTunnelHandlesMu sync.Mutex
var vexAppleRoutingMu sync.Mutex
var vexAppleRoutingHandles = make(map[int32]*vexAppleRoutingHandle)

//export wgRouterStopTransport
func wgRouterStopTransport(id int32) int32 {
	vexTunnelHandlesMu.Lock()
	defer vexTunnelHandlesMu.Unlock()
	vexAppleRoutingMu.Lock()
	handle := vexAppleRoutingHandles[id]
	vexAppleRoutingMu.Unlock()
	device, exists := tunnelHandles[id]
	if handle == nil || !exists {
		return -1
	}
	if device.Down() != nil || device.IpcSet("private_key="+strings.Repeat("0", 64)+"\nreplace_peers=true\n") != nil {
		return -1
	}
	return 0
}

//export wgTurnOnRouted
func wgTurnOnRouted(settings *C.char, fd int32, parameters *C.char, interfaceIndex int32) int32 {
	options, _, _, err := routing.AdmitParameters([]byte(C.GoString(parameters)), "ios", time.Now(), time.Time{})
	if err != nil {
		return -1
	}
	duplicate, err := unix.Dup(int(fd))
	if err != nil {
		return -1
	}
	if err := unix.SetNonblock(duplicate, true); err != nil {
		unix.Close(duplicate)
		return -1
	}
	osTUN, err := tun.CreateTUNFromFile(os.NewFile(uintptr(duplicate), "/dev/tun"), 0)
	if err != nil {
		unix.Close(duplicate)
		return -1
	}
	handle := &vexAppleRoutingHandle{}
	handle.index.Store(int64(interfaceIndex))
	prepare := func(fd int, _ routing.SocketPurpose) error {
		return routing.BindPhysicalSocket(fd, int(handle.index.Load()))
	}
	options.DirectDial = routing.ProtectedDialer(prepare, routing.SocketDirect)
	options.DirectDNS = routing.DirectDoH(routing.ProtectedDialer(prepare, routing.SocketDNS))
	options.PolicySource = routing.ProtectedPolicySource(options.DirectDNS, options.DirectDial, "ios")
	if options.Policy != nil {
		handle.highWater = options.Policy.IssuedAt()
	}
	router, transport, err := routing.Attach(osTUN, options)
	if err != nil {
		osTUN.Close()
		return -1
	}
	handle.router = router
	logger := &device.Logger{Verbosef: CLogger(0).Printf, Errorf: CLogger(1).Printf}
	dev := device.NewDevice(transport, routing.NewProtectedBind(conn.NewStdNetBind(), prepare), logger)
	if err := dev.IpcSet(C.GoString(settings)); err != nil {
		dev.Close()
		return -1
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		return -1
	}
	vexTunnelHandlesMu.Lock()
	defer vexTunnelHandlesMu.Unlock()
	vexAppleRoutingMu.Lock()
	defer vexAppleRoutingMu.Unlock()
	var id int32
	for id = 0; id < math.MaxInt32; id++ {
		if _, exists := tunnelHandles[id]; !exists {
			break
		}
	}
	if id == math.MaxInt32 {
		dev.Close()
		return -1
	}
	tunnelHandles[id] = tunnelHandle{dev, logger}
	vexAppleRoutingHandles[id] = handle
	return id
}

//export wgRouterSetInterface
func wgRouterSetInterface(id int32, interfaceIndex int32) {
	vexAppleRoutingMu.Lock()
	handle := vexAppleRoutingHandles[id]
	vexAppleRoutingMu.Unlock()
	if handle == nil {
		return
	}
	handle.index.Store(int64(interfaceIndex))
	handle.router.UnderlyingNetworkChanged()
	vexTunnelHandlesMu.Lock()
	defer vexTunnelHandlesMu.Unlock()
	if tunnel, ok := tunnelHandles[id]; ok {
		tunnel.BindUpdate()
	}
}

//export wgRouterUpdatePolicy
func wgRouterUpdatePolicy(id int32, parameters *C.char) int32 {
	vexAppleRoutingMu.Lock()
	defer vexAppleRoutingMu.Unlock()
	handle := vexAppleRoutingHandles[id]
	if handle == nil {
		return -1
	}
	active, err := handle.router.UpdateParameters([]byte(C.GoString(parameters)), "ios")
	if err != nil {
		return -1
	}
	if active {
		return 1
	}
	return 0
}

//export wgRouterAuthorization
func wgRouterAuthorization(id int32) *C.char {
	vexAppleRoutingMu.Lock()
	defer vexAppleRoutingMu.Unlock()
	if handle := vexAppleRoutingHandles[id]; handle != nil {
		return C.CString(handle.router.AuthorizationJSON())
	}
	return nil
}

func vexRoutingDidStop(id int32) {
	vexAppleRoutingMu.Lock()
	delete(vexAppleRoutingHandles, id)
	vexAppleRoutingMu.Unlock()
}
