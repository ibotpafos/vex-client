//go:build windows

package main

import (
	"bufio"
	"encoding/base64"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/ipc"
	"github.com/amnezia-vpn/amneziawg-go/v3/ipc/namedpipe"
	"golang.org/x/sys/windows"
)

func requireElevated() error {
	if !windows.GetCurrentProcessToken().IsElevated() {
		return errors.New("privileged owner required")
	}
	return nil
}
func dropSocketPrivileges(uid, gid int) error    { return nil }
func terminationSignals() []os.Signal            { return []os.Signal{os.Interrupt, windows.SIGTERM} }
func openUAPI(name string) (net.Listener, error) { return ipc.UAPIListen(name) }
func readProtectedParameters(path string) ([]byte, error) {
	if !filepath.IsAbs(path) {
		return nil, errors.New("absolute routing metadata path required")
	}
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || info.Size() > 2<<20 {
		return nil, errors.New("routing metadata file invalid")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, (2<<20)+1))
	if err != nil || len(data) > 2<<20 {
		return nil, errors.New("routing metadata too large")
	}
	return data, nil
}
func writeProtectedName(path, name string) error { return os.WriteFile(path, []byte(name+"\n"), 0600) }
func reloadRouting(name string, raw []byte) error {
	value, err := sendRoutingControl(name, "set=1\nvex_routing_parameters="+base64.RawURLEncoding.EncodeToString(raw)+"\n\n")
	if err != nil {
		return err
	}
	if strings.TrimSpace(value) != "errno=0" {
		return errors.New("routing reload rejected")
	}
	return nil
}

func sendRoutingControl(name, frame string) (string, error) {
	connection, err := namedpipe.DialTimeout(`\\.\pipe\ProtectedPrefix\Administrators\AmneziaWG\`+name, 2*time.Second)
	if err != nil {
		return "", err
	}
	defer connection.Close()
	connection.SetDeadline(time.Now().Add(5 * time.Second))
	_, err = io.WriteString(connection, frame)
	if err != nil {
		return "", err
	}
	line, err := readBoundedLine(bufio.NewReader(connection), 2<<20)
	if err != nil {
		return "", err
	}
	return line, nil
}
