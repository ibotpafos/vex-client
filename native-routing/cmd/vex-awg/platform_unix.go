//go:build darwin || linux

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
	"syscall"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/ipc"
	"golang.org/x/sys/unix"
)

func requireElevated() error {
	if os.Geteuid() != 0 {
		return errors.New("privileged owner required")
	}
	return nil
}
func dropSocketPrivileges(uid, gid int) error {
	if uid <= 0 || gid <= 0 {
		return errors.New("dedicated routing UID required")
	}
	if err := unix.Setgroups([]int{}); err != nil {
		return err
	}
	if err := unix.Setgid(gid); err != nil {
		return err
	}
	return unix.Setuid(uid)
}
func terminationSignals() []os.Signal { return []os.Signal{os.Interrupt, syscall.SIGTERM} }
func openUAPI(name string) (net.Listener, error) {
	file, err := ipc.UAPIOpen(name)
	if err != nil {
		return nil, err
	}
	listener, err := ipc.UAPIListen(name, file)
	if err != nil {
		file.Close()
	}
	return listener, err
}
func readProtectedParameters(path string) ([]byte, error) {
	if !filepath.IsAbs(path) {
		return nil, errors.New("absolute routing metadata path required")
	}
	for current := path; current != "/"; current = filepath.Dir(current) {
		info, err := os.Lstat(current)
		if err != nil {
			return nil, err
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || stat.Uid != 0 || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0022 != 0 {
			return nil, errors.New("routing metadata ownership invalid")
		}
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return nil, errors.New("regular routing metadata required")
	}
	data, err := io.ReadAll(io.LimitReader(file, (2<<20)+1))
	if err != nil || len(data) > 2<<20 {
		return nil, errors.New("routing metadata too large")
	}
	return data, nil
}
func writeProtectedName(path, name string) error {
	// Legacy awg-quick owns this protected path before launch. Do not follow a
	// caller-controlled symlink when starting the privileged process.
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC|unix.O_NOFOLLOW, 0600)
	if err != nil {
		return err
	}
	defer file.Close()
	_, err = file.WriteString(name + "\n")
	return err
}
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
	path := "/var/run/amneziawg/" + name + ".sock"
	if _, err := os.Stat(path); err != nil {
		path = "/var/run/wireguard/" + name + ".sock"
	}
	connection, err := net.DialTimeout("unix", path, 2*time.Second)
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
