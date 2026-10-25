package routing

import (
	"context"
	"errors"
	"io"
	"net"
	"net/netip"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/tun"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv6"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
	"gvisor.dev/gvisor/pkg/waiter"
	"vex.dev/native-routing/internal/awgnetstack"
)

type DialFunc func(context.Context, string, string) (net.Conn, error)
type DNSExchangeFunc func(context.Context, []byte) ([]byte, error)

// Native Linux TUN offload writes prepend a virtio header (10 bytes); Darwin
// prepends a 4-byte address family. Reserve the same 16-byte headroom as AWG's
// packet path so either native device can write without releasing capture.
const osPacketHeadroom = 16

type Options struct {
	Addresses     []netip.Addr
	DNS           []netip.Addr
	Policy        *CompiledPolicy
	Mode          string
	Platform      string
	Authorization *Authorization
	HighWater     time.Time
	PolicySource  PolicySource
	MaxFlows      int
	// DirectDial must protect/bind every socket before connecting. A nil or
	// failing callback rejects DIRECT; the default OS dialer is never used.
	DirectDial                      DialFunc
	DirectDNS                       DNSExchangeFunc
	Now                             func() time.Time
	PreserveCaptureOnTransportClose bool
}

type Router struct {
	osTun              tun.Device
	transport          tun.Device
	net                *netstack.Net
	stack              *stack.Stack
	link               *channel.Endpoint
	policy             atomic.Pointer[CompiledPolicy]
	direct             DialFunc
	directDNS          DNSExchangeFunc
	dns                []netip.Addr
	addresses          []netip.Addr
	policyMu           sync.Mutex
	mode, platform     string
	highWater          time.Time
	authorization      *Authorization
	now                func() time.Time
	fakes              *fakeTable
	ctx                context.Context
	cancel             context.CancelFunc
	closeOnce          sync.Once
	transportCloseOnce sync.Once
	transportStopped   atomic.Bool
	preserveCapture    bool
	writeMu            sync.Mutex
	activeMu           sync.Mutex
	directConnections  map[net.Conn]struct{}
	underlay           context.Context
	cancelUnderlay     context.CancelFunc
	flowBudget         chan struct{}
}

// Attach consumes the OS TUN and returns the TUN AWG must use. Only two OS
// default routes are needed; the complete country policy stays in memory.
func Attach(osTun tun.Device, options Options) (*Router, tun.Device, error) {
	if osTun == nil || len(options.Addresses) == 0 || len(options.DNS) == 0 {
		return nil, nil, errors.New("routing TUN parameters missing")
	}
	mtu, err := osTun.MTU()
	if err != nil || mtu < 576 || mtu > 9000 {
		return nil, nil, errors.New("routing MTU invalid")
	}
	if options.Now == nil {
		options.Now = time.Now
	}
	if options.MaxFlows <= 0 {
		options.MaxFlows = 128
	}
	if options.Platform == "ios" && options.MaxFlows > 32 {
		options.MaxFlows = 32
	}
	transport, virtual, err := netstack.CreateNetTUN(options.Addresses, options.DNS, mtu)
	if err != nil {
		return nil, nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	r := &Router{osTun: osTun, transport: transport, net: virtual, direct: options.DirectDial,
		directDNS: options.DirectDNS, dns: append([]netip.Addr(nil), options.DNS...), now: options.Now,
		fakes: fakeTableForPlatform(options.Platform), ctx: ctx, cancel: cancel, directConnections: make(map[net.Conn]struct{}), flowBudget: make(chan struct{}, options.MaxFlows)}
	r.preserveCapture = options.PreserveCaptureOnTransportClose
	r.addresses = append([]netip.Addr(nil), options.Addresses...)
	r.mode, r.platform, r.highWater, r.authorization = options.Mode, options.Platform, options.HighWater, options.Authorization
	r.policy.Store(options.Policy)
	r.underlay, r.cancelUnderlay = context.WithCancel(ctx)
	r.link = channel.New(1024, uint32(mtu), "")
	r.stack = stack.New(stack.Options{NetworkProtocols: []stack.NetworkProtocolFactory{ipv4.NewProtocol, ipv6.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol}})
	if tcpErr := r.stack.CreateNIC(1, r.link); tcpErr != nil {
		r.Close()
		return nil, nil, errors.New(tcpErr.String())
	}
	r.stack.SetPromiscuousMode(1, true)
	r.stack.SetSpoofing(1, true)
	r.stack.SetRouteTable([]tcpip.Route{{Destination: header.IPv4EmptySubnet, NIC: 1}, {Destination: header.IPv6EmptySubnet, NIC: 1}})
	tcpForwarder := tcp.NewForwarder(r.stack, 64<<10, options.MaxFlows, r.forwardTCP)
	r.stack.SetTransportProtocolHandler(tcp.ProtocolNumber, tcpForwarder.HandlePacket)
	udpForwarder := udp.NewForwarder(r.stack, r.forwardUDP)
	r.stack.SetTransportProtocolHandler(udp.ProtocolNumber, udpForwarder.HandlePacket)
	go r.readOS()
	go r.writeOS()
	go r.expireDirect()
	if options.PolicySource != nil {
		go r.refreshPolicies(options.PolicySource)
	}
	return r, &transportTUN{Device: transport, owner: r}, nil
}

// Policy-only updates keep AWG, peer keys, TUN and OS routes intact. Existing
// DIRECT sockets close before revoked mappings can be reused.
func (r *Router) UpdatePolicy(policy *CompiledPolicy) {
	r.activeMu.Lock()
	previous := r.policy.Load()
	r.policy.Store(policy)
	if previous == nil || policy == nil || previous.Version() != policy.Version() {
		for connection := range r.directConnections {
			connection.Close()
		}
	}
	r.activeMu.Unlock()
}

// UnderlyingNetworkChanged prevents existing protected sockets from migrating
// to an unqualified interface. New sockets use the native binder's new state.
func (r *Router) UnderlyingNetworkChanged() {
	r.activeMu.Lock()
	defer r.activeMu.Unlock()
	r.cancelUnderlay()
	r.underlay, r.cancelUnderlay = context.WithCancel(r.ctx)
	for connection := range r.directConnections {
		connection.Close()
	}
}

// Keep caller deadlines and cancel pending physical work when its network is
// retired. The captured underlay is also checked under activeMu at admission:
// AfterFunc cancellation is asynchronous, and a callback can return late.
func (r *Router) physicalContext(parent context.Context) (context.Context, context.CancelFunc, context.Context) {
	underlay := r.underlyingContext()
	ctx, cancel := context.WithCancel(parent)
	stop := context.AfterFunc(underlay, cancel)
	if underlay.Err() != nil {
		cancel()
	}
	return ctx, func() { stop(); cancel() }, underlay
}

func (r *Router) underlyingContext() context.Context {
	r.activeMu.Lock()
	defer r.activeMu.Unlock()
	return r.underlay
}

func (r *Router) Close() error {
	var err error
	r.closeOnce.Do(func() {
		r.cancel()
		r.UpdatePolicy(nil)
		if r.stack != nil {
			r.stack.Close()
		}
		if r.link != nil {
			r.link.Close()
		}
		r.StopTransport()
		err = r.osTun.Close()
	})
	return err
}

type transportTUN struct {
	tun.Device
	owner *Router
}

func (t *transportTUN) Name() (string, error)    { return t.owner.osTun.Name() }
func (t *transportTUN) File() *os.File           { return t.owner.osTun.File() }
func (t *transportTUN) Events() <-chan tun.Event { return t.owner.osTun.Events() }
func (t *transportTUN) Close() error {
	if t.owner.preserveCapture {
		t.owner.StopTransport()
		return nil
	}
	return t.owner.Close()
}

// Native owners release retained capture only for explicit disconnect or after
// another admitted TUN replaces it. AWG failure cannot restore physical routes.
func (r *Router) StopTransport() {
	r.transportCloseOnce.Do(func() { r.transportStopped.Store(true); r.transport.Close() })
}

func (r *Router) CaptureActive() bool {
	select {
	case <-r.ctx.Done():
		return false
	default:
		return true
	}
}

func (r *Router) DirectPolicyActive() bool { return r.policy.Load().valid(r.now()) }

func (r *Router) readOS() {
	batch := r.osTun.BatchSize()
	bufs, sizes := make([][]byte, batch), make([]int, batch)
	for i := range bufs {
		bufs[i] = make([]byte, 65536+osPacketHeadroom)
	}
	for {
		n, err := r.osTun.Read(bufs, sizes, osPacketHeadroom)
		if err != nil {
			r.Close()
			return
		}
		for i := 0; i < n; i++ {
			if sizes[i] < 1 {
				continue
			}
			var protocol tcpip.NetworkProtocolNumber
			switch bufs[i][osPacketHeadroom] >> 4 {
			case 4:
				protocol = ipv4.ProtocolNumber
			case 6:
				protocol = ipv6.ProtocolNumber
			default:
				continue
			}
			packet := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(bufs[i][osPacketHeadroom : osPacketHeadroom+sizes[i]])})
			r.link.InjectInbound(protocol, packet)
			packet.DecRef()
		}
	}
}

func (r *Router) writeOS() {
	for {
		packet := r.link.ReadContext(r.ctx)
		if packet == nil {
			return
		}
		view := packet.ToView()
		packet.DecRef()
		r.writeMu.Lock()
		payload := make([]byte, osPacketHeadroom+view.Size())
		copy(payload[osPacketHeadroom:], view.AsSlice())
		_, err := r.osTun.Write([][]byte{payload}, osPacketHeadroom)
		r.writeMu.Unlock()
		view.Release()
		if err != nil {
			r.Close()
			return
		}
	}
}

func destination(id stack.TransportEndpointID) netip.AddrPort {
	ip, _ := netip.AddrFromSlice(id.LocalAddress.AsSlice())
	return netip.AddrPortFrom(ip.Unmap(), id.LocalPort)
}

func (r *Router) acquireFlow() bool {
	select {
	case r.flowBudget <- struct{}{}:
		return true
	default:
		return false
	}
}

func (r *Router) dial(ctx context.Context, protocol string, target netip.AddrPort) (net.Conn, bool, error) {
	policy := r.policy.Load()
	actual, direct := target.Addr(), false
	control := false
	if isFake(actual) {
		control = r.fakes.isControl(actual)
		if control && (protocol != "tcp" || target.Port() != 443) {
			return nil, false, errors.New("routing control port prohibited")
		}
		var valid bool
		actual, valid = r.fakes.get(actual, policy, r.now())
		if !valid {
			return nil, false, errors.New("routing DNS identity expired")
		}
		direct = true
	} else {
		direct = policy.DirectIP(actual, r.now())
	}
	address := netip.AddrPortFrom(actual, target.Port())
	if direct {
		if r.direct == nil {
			return nil, true, errors.New("routing physical binder unavailable")
		}
		ctx, cancel, underlay := r.physicalContext(ctx)
		defer cancel()
		if ctx.Err() != nil || underlay.Err() != nil {
			return nil, true, errors.New("routing physical network retired")
		}
		connection, err := r.direct(ctx, protocol, address.String())
		if err != nil {
			if connection != nil {
				connection.Close()
			}
			return nil, true, err
		}
		if connection == nil {
			return nil, true, errors.New("routing physical connection missing")
		}
		r.activeMu.Lock()
		if ctx.Err() != nil || underlay.Err() != nil || (!control && (policy != r.policy.Load() || !policy.valid(r.now()))) {
			r.activeMu.Unlock()
			connection.Close()
			return nil, true, errors.New("routing authority changed")
		}
		r.directConnections[connection] = struct{}{}
		r.activeMu.Unlock()
		return connection, true, nil
	}
	// The AWG virtual network has no physical fallback, including DNS, QUIC,
	// IPv6 and network-change failures.
	if r.transportStopped.Load() {
		return nil, false, errors.New("routing encrypted transport unavailable")
	}
	if protocol == "tcp" {
		connection, err := r.net.DialContextTCPAddrPort(ctx, address)
		return connection, false, err
	}
	connection, err := r.net.DialUDPAddrPort(netip.AddrPort{}, address)
	return connection, false, err
}

func (r *Router) releaseConnection(connection net.Conn, direct bool) {
	connection.Close()
	if direct {
		r.activeMu.Lock()
		delete(r.directConnections, connection)
		r.activeMu.Unlock()
	}
}

func (r *Router) forwardTCP(request *tcp.ForwarderRequest) {
	if !r.acquireFlow() {
		request.Complete(true)
		return
	}
	defer func() { <-r.flowBudget }()
	target := destination(request.ID())
	var queue waiter.Queue
	endpoint, err := request.CreateEndpoint(&queue)
	if err != nil {
		request.Complete(true)
		return
	}
	request.Complete(false)
	client := gonet.NewTCPConn(&queue, endpoint)
	defer client.Close()
	if target.Port() == 53 {
		r.serveDNSStream(client)
		return
	}
	ctx, cancel := context.WithTimeout(r.ctx, 15*time.Second)
	remote, direct, dialErr := r.dial(ctx, "tcp", target)
	cancel()
	if dialErr != nil {
		return
	}
	defer r.releaseConnection(remote, direct)
	done := make(chan struct{})
	go func() { io.Copy(remote, client); remote.Close(); close(done) }()
	io.Copy(client, remote)
	client.Close()
	<-done
}

func (r *Router) forwardUDP(request *udp.ForwarderRequest) {
	var queue waiter.Queue
	endpoint, err := request.CreateEndpoint(&queue)
	if err != nil {
		return
	}
	client := gonet.NewUDPConn(r.stack, &queue, endpoint)
	if !r.acquireFlow() {
		client.Close()
		return
	}
	go func() {
		defer func() { <-r.flowBudget }()
		defer client.Close()
		target := destination(request.ID())
		if target.Port() == 53 {
			r.serveDNSDatagrams(client)
			return
		}
		ctx, cancel := context.WithTimeout(r.ctx, 15*time.Second)
		remote, direct, dialErr := r.dial(ctx, "udp", target)
		cancel()
		if dialErr != nil {
			return
		}
		defer r.releaseConnection(remote, direct)
		done := make(chan struct{})
		copyPackets := func(dst, src net.Conn) {
			buf := make([]byte, 65536)
			for {
				src.SetReadDeadline(r.now().Add(90 * time.Second))
				n, err := src.Read(buf)
				if err != nil {
					return
				}
				if _, err = dst.Write(buf[:n]); err != nil {
					return
				}
			}
		}
		go func() { copyPackets(remote, client); remote.Close(); close(done) }()
		copyPackets(client, remote)
		client.Close()
		<-done
	}()
}

func (r *Router) expireDirect() {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-r.ctx.Done():
			return
		case <-ticker.C:
			r.policyMu.Lock()
			if policy := r.policy.Load(); policy != nil && !policy.valid(r.now()) {
				r.UpdatePolicy(nil)
			}
			r.policyMu.Unlock()
		}
	}
}
