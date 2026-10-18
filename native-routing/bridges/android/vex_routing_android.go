//go:build android

package main

/*
#include <stdint.h>
#include <stdlib.h>
int vex_prepare_socket(uint64_t context, int fd, int64_t generation, int purpose);
void vex_release_protector(uint64_t context);
*/
import "C"

import (
	"errors"
	"math"
	"sync"
	"sync/atomic"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
	"github.com/amnezia-vpn/amneziawg-go/v3/device"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun"
	"golang.org/x/sys/unix"
	routing "vex.dev/native-routing"
)

type vexRoutingHandle struct {
	router     *routing.Router
	generation atomic.Int64
	context    uint64
	highWater  time.Time
}

var vexTunnelHandlesMu sync.Mutex
var vexRoutingMu sync.Mutex
var vexRoutingHandles = make(map[int32]*vexRoutingHandle)

//export awgRouterAuthorization
func awgRouterAuthorization(id int32) *C.char {
	vexRoutingMu.Lock()
	defer vexRoutingMu.Unlock()
	if handle := vexRoutingHandles[id]; handle != nil {
		return C.CString(handle.router.AuthorizationJSON())
	}
	return nil
}

//export awgTurnOnRouted
func awgTurnOnRouted(name string, fd int32, settings, parameters string, protector uint64, generation int64, retain int32) int32 {
	options, _, _, err := routing.AdmitParameters([]byte(parameters), "android", time.Now(), time.Time{})
	if err != nil {
		unix.Close(int(fd))
		return -1
	}
	osTUN, _, err := tun.CreateUnmonitoredTUNFromFD(int(fd))
	if err != nil {
		unix.Close(int(fd))
		return -1
	}
	handle := &vexRoutingHandle{context: protector}
	handle.generation.Store(generation)
	prepare := func(fd int, purpose routing.SocketPurpose) error {
		if C.vex_prepare_socket(C.uint64_t(protector), C.int(fd), C.int64_t(handle.generation.Load()), C.int(purpose)) == 0 {
			return errors.New("native socket protection failed")
		}
		return nil
	}
	options.DirectDial = routing.ProtectedDialer(prepare, routing.SocketDirect)
	options.DirectDNS = routing.DirectDoH(routing.ProtectedDialer(prepare, routing.SocketDNS))
	options.PolicySource = routing.ProtectedPolicySource(options.DirectDNS, options.DirectDial, "android")
	options.PreserveCaptureOnTransportClose = retain != 0
	if options.Policy != nil {
		handle.highWater = options.Policy.IssuedAt()
	}
	var transport tun.Device
	handle.router, transport, err = routing.Attach(osTUN, options)
	if err != nil {
		osTUN.Close()
		return -1
	}
	logger := device.NewLogger(device.LogLevelError, "VEX routing: ")
	dev := device.NewDevice(transport, routing.NewProtectedBind(conn.NewStdNetBind(), prepare), logger)
	err = dev.IpcSet(settings)
	if err == nil {
		dev.DisableSomeRoamingForBrokenMobileSemantics()
		err = dev.Up()
	}
	vexTunnelHandlesMu.Lock()
	defer vexTunnelHandlesMu.Unlock()
	vexRoutingMu.Lock()
	defer vexRoutingMu.Unlock()
	var id int32
	for id = 0; id < math.MaxInt32; id++ {
		if _, exists := tunnelHandles[id]; exists {
			continue
		}
		if _, retained := vexRoutingHandles[id]; !retained {
			break
		}
	}
	if id == math.MaxInt32 {
		dev.Close()
		handle.router.Close()
		return -1
	}
	vexRoutingHandles[id] = handle
	if err != nil {
		// Keep an admitted capture while the Java owner establishes its blocker.
		// A negative ID encodes its receipt, so cleanup never guesses ownership.
		dev.Close()
		return -id - 2
	}
	tunnelHandles[id] = TunnelHandle{device: dev}
	return id
}

//export awgRouterSetUnderlying
func awgRouterSetUnderlying(id int32, generation int64) {
	vexRoutingMu.Lock()
	handle := vexRoutingHandles[id]
	vexRoutingMu.Unlock()
	if handle == nil {
		return
	}
	handle.generation.Store(generation)
	handle.router.UnderlyingNetworkChanged()
}

//export awgRouterUpdatePolicy
func awgRouterUpdatePolicy(id int32, parameters string) int32 {
	vexRoutingMu.Lock()
	defer vexRoutingMu.Unlock()
	handle := vexRoutingHandles[id]
	if handle == nil {
		return -1
	}
	active, err := handle.router.UpdateParameters([]byte(parameters), "android")
	if err != nil {
		return -1
	}
	if active {
		return 1
	}
	return 0
}

//export awgRouterCaptureActive
func awgRouterCaptureActive(id int32) int32 {
	vexRoutingMu.Lock()
	defer vexRoutingMu.Unlock()
	if handle := vexRoutingHandles[id]; handle != nil && handle.router.CaptureActive() {
		return 1
	}
	return 0
}

//export awgRouterPolicyActive
func awgRouterPolicyActive(id int32) int32 {
	vexRoutingMu.Lock()
	defer vexRoutingMu.Unlock()
	if handle := vexRoutingHandles[id]; handle != nil && handle.router.DirectPolicyActive() {
		return 1
	}
	return 0
}

//export awgRouterRelease
func awgRouterRelease(id int32) {
	vexRoutingMu.Lock()
	handle := vexRoutingHandles[id]
	delete(vexRoutingHandles, id)
	vexRoutingMu.Unlock()
	if handle != nil {
		handle.router.Close()
		C.vex_release_protector(C.uint64_t(handle.context))
	}
}
