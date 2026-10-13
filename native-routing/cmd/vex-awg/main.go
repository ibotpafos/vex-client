package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
	"github.com/amnezia-vpn/amneziawg-go/v3/device"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun"
	routing "vex.dev/native-routing"
)

func main() {
	if err := run(); err != nil {
		os.Stderr.WriteString("VEX AWG startup or control failed\n")
		os.Exit(1)
	}
}

func run() error {
	foreground := flag.Bool("f", true, "run in foreground")
	version := flag.Bool("version", false, "print version")
	check := flag.Bool("check-routing-parameters", false, "admit protected routing metadata without network changes")
	paramsPath := flag.String("parameters", os.Getenv("VEX_ROUTING_PARAMETERS"), "protected routing metadata file")
	reload := flag.Bool("reload-routing", false, "reload signed routing policy without replacing AWG")
	stopTransport := flag.Bool("stop-transport", false, "stop AWG and retain protected capture")
	getAuthorization := flag.Bool("get-routing-authorization", false, "read last admitted public routing signature")
	updateUnderlay := flag.Bool("update-underlay", false, "update physical socket scope without replacing AWG")
	physicalIndex := flag.Int("physical-interface-index", 0, "physical interface index owned by the native supervisor")
	flag.Parse()
	_ = foreground
	if *version {
		os.Stdout.WriteString("amneziawg-go v3.1.20260828; VEX routing v2\n")
		return nil
	}
	if flag.NArg() != 1 {
		return errors.New("interface missing")
	}
	name := flag.Arg(0)
	if !validInterfaceName(name) {
		return errors.New("interface invalid")
	}
	if err := requireElevated(); err != nil {
		return err
	}
	platform := runtime.GOOS
	if platform == "darwin" {
		platform = "macos"
	}
	var options routing.Options
	var parameters routing.DesktopParameters
	var raw []byte
	var err error
	if *paramsPath != "" {
		raw, err = readProtectedParameters(*paramsPath)
		if err != nil {
			return err
		}
		options, parameters, err = routing.AdmitDesktopParameters(raw, platform, time.Now(), time.Time{})
		if err != nil {
			return err
		}
	}
	if *reload {
		if len(raw) == 0 {
			return errors.New("routing metadata missing")
		}
		return reloadRouting(name, raw)
	}
	if *stopTransport {
		value, err := sendRoutingControl(name, "set=1\nvex_transport=down\n\n")
		if err != nil {
			return err
		}
		if strings.TrimSpace(value) != "errno=0" {
			return errors.New("protected transport stop rejected")
		}
		return nil
	}
	if *getAuthorization {
		value, err := sendRoutingControl(name, "get_routing=1\n\n")
		if err == nil {
			_, err = os.Stdout.WriteString(value)
		}
		return err
	}
	if *updateUnderlay {
		if *physicalIndex <= 0 {
			return errors.New("physical interface invalid")
		}
		value, err := sendRoutingControl(name, fmt.Sprintf("set=1\nvex_physical_interface=%d\n\n", *physicalIndex))
		if err != nil {
			return err
		}
		if strings.TrimSpace(value) != "errno=0" {
			return errors.New("underlay rejected")
		}
		return nil
	}
	if *check {
		if len(raw) == 0 {
			return errors.New("routing parameters missing")
		}
		return nil
	}
	osTUN, err := tun.CreateTUN(name, 1360)
	if err != nil {
		return err
	}
	defer osTUN.Close()
	name, err = osTUN.Name()
	if err != nil {
		return err
	}
	listener, err := openUAPI(name)
	if err != nil {
		return err
	}
	defer listener.Close()
	if path := os.Getenv("WG_TUN_NAME_FILE"); path != "" {
		if err := writeProtectedName(path, name); err != nil {
			return err
		}
	}
	var router *routing.Router
	transport := osTUN
	var index atomic.Int64
	index.Store(int64(parameters.PhysicalInterfaceIndex))
	bind := conn.NewStdNetBind()
	if len(raw) > 0 {
		// UAPI and TUN open while privileged. Physical sockets are subsequently
		// created under the router's dedicated UID on Unix.
		if err := dropSocketPrivileges(parameters.UID, parameters.GID); err != nil {
			return err
		}
		prepare := func(fd int, _ routing.SocketPurpose) error { return routing.BindPhysicalSocket(fd, int(index.Load())) }
		options.DirectDial = routing.ProtectedDialer(prepare, routing.SocketDirect)
		options.DirectDNS = routing.DirectDoH(routing.ProtectedDialer(prepare, routing.SocketDNS))
		options.PolicySource = routing.ProtectedPolicySource(options.DirectDNS, options.DirectDial, platform)
		router, transport, err = routing.Attach(osTUN, options)
		if err != nil {
			return err
		}
		bind = routing.NewProtectedBind(bind, prepare)
	}
	dev := device.NewDevice(transport, bind, device.NewLogger(device.LogLevelError, "VEX: "))
	defer dev.Close()
	if err := dev.Up(); err != nil {
		return err
	}
	var updateMu sync.Mutex
	var highWater time.Time
	if options.Policy != nil {
		highWater = options.Policy.IssuedAt()
	}
	stopped := make(chan os.Signal, 1)
	signal.Notify(stopped, terminationSignals()...)
	defer signal.Stop(stopped)
	errorsChannel := make(chan error, 1)
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				select {
				case errorsChannel <- err:
				default:
				}
				return
			}
			go func(connection net.Conn) {
				defer connection.Close()
				reader := bufio.NewReaderSize(connection, 4096)
				first, err := reader.ReadString('\n')
				if err != nil || len(first) > 64 {
					return
				}
				prefix := first
				if first == "get_routing=1\n" && router != nil {
					connection.Write([]byte(router.AuthorizationJSON() + "\n"))
					return
				}
				if first == "set=1\n" {
					second, err := readBoundedLine(reader, 3<<20)
					if err != nil {
						return
					}
					prefix += second
					if strings.HasPrefix(second, "vex_physical_interface=") && router != nil {
						value, err := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(second, "vex_physical_interface=")))
						if err == nil && value > 0 {
							index.Store(int64(value))
							router.UnderlyingNetworkChanged()
							err = dev.BindUpdate()
						} else {
							err = errors.New("underlay invalid")
						}
						if err == nil {
							connection.Write([]byte("errno=0\n\n"))
						} else {
							connection.Write([]byte("errno=1\n\n"))
						}
						return
					}
					if second == "vex_transport=down\n" && router != nil {
						if err := dev.Down(); err != nil {
							connection.Write([]byte("errno=1\n\n"))
							return
						}
						if err := dev.IpcSet("private_key=" + strings.Repeat("0", 64) + "\nreplace_peers=true\n"); err != nil {
							connection.Write([]byte("errno=1\n\n"))
							return
						}
						connection.Write([]byte("errno=0\n\n"))
						return
					}
					if strings.HasPrefix(second, "vex_routing_parameters=") {
						if router == nil {
							return
						}
						value, err := base64.RawURLEncoding.Strict().DecodeString(strings.TrimSuffix(strings.TrimPrefix(second, "vex_routing_parameters="), "\n"))
						if err != nil {
							return
						}
						updateMu.Lock()
						next, nextParameters, err := routing.AdmitDesktopParameters(value, platform, time.Now(), highWater)
						if err == nil {
							payload, _ := json.Marshal(nextParameters.Routing)
							_, err = router.UpdateParameters(payload, platform)
							if err == nil && next.Policy != nil {
								highWater = next.Policy.IssuedAt()
							}
							if err == nil && index.Load() != int64(nextParameters.PhysicalInterfaceIndex) {
								index.Store(int64(nextParameters.PhysicalInterfaceIndex))
								router.UnderlyingNetworkChanged()
								err = dev.BindUpdate()
							}
						}
						updateMu.Unlock()
						if err == nil {
							connection.Write([]byte("errno=0\n\n"))
						} else {
							connection.Write([]byte("errno=1\n\n"))
						}
						return
					}
				}
				dev.IpcHandle(&bufferedConnection{Conn: connection, Reader: io.MultiReader(bytes.NewReader([]byte(prefix)), reader)})
			}(connection)
		}
	}()
	select {
	case <-stopped:
		return nil
	case <-dev.Wait():
		return nil
	case err := <-errorsChannel:
		return err
	}
}

type bufferedConnection struct {
	net.Conn
	io.Reader
}

func (c *bufferedConnection) Read(p []byte) (int, error) { return c.Reader.Read(p) }

func validInterfaceName(value string) bool {
	if len(value) == 0 || len(value) > 32 {
		return false
	}
	for _, c := range value {
		if (c < 'a' || c > 'z') && (c < 'A' || c > 'Z') && (c < '0' || c > '9') && c != '-' && c != '_' {
			return false
		}
	}
	return true
}

func readBoundedLine(reader *bufio.Reader, max int) (string, error) {
	var value []byte
	for {
		chunk, prefix, err := reader.ReadLine()
		if err != nil {
			return "", err
		}
		if len(value)+len(chunk) > max {
			return "", errors.New("routing frame too large")
		}
		value = append(value, chunk...)
		if !prefix {
			return string(value) + "\n", nil
		}
	}
}
