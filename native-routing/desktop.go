package routing

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"time"
)

// Written by the privileged owner, never by a caller-supplied command line.
// The socket identity/underlay are local receipts; policy authority stays signed.
type DesktopParameters struct {
	Routing                Parameters `json:"routing"`
	PhysicalInterfaceIndex int        `json:"physical_interface_index"`
	UID                    int        `json:"uid,omitempty"`
	GID                    int        `json:"gid,omitempty"`
}

// ValidUnixSocketIdentity rejects root, unset IDs and values that would truncate
// at the Unix 32-bit uid_t/gid_t boundary. The all-ones value is reserved.
func ValidUnixSocketIdentity(uid, gid int) bool {
	const maximum int64 = 1<<32 - 2
	return uid > 0 && gid > 0 && int64(uid) <= maximum && int64(gid) <= maximum
}

func AdmitDesktopParameters(raw []byte, platform string, now, highWater time.Time) (Options, DesktopParameters, error) {
	if len(raw) > 2*MaxPayloadBytes {
		return Options{}, DesktopParameters{}, errors.New("routing desktop parameters too large")
	}
	if err := rejectDuplicateJSONKeys(raw); err != nil {
		return Options{}, DesktopParameters{}, err
	}
	var parameters DesktopParameters
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&parameters); err != nil || decoder.Decode(new(any)) != io.EOF {
		return Options{}, DesktopParameters{}, errors.New("routing desktop parameters invalid")
	}
	if parameters.PhysicalInterfaceIndex <= 0 || parameters.UID < 0 || parameters.GID < 0 ||
		((platform == "macos" || platform == "linux") && !ValidUnixSocketIdentity(parameters.UID, parameters.GID)) {
		return Options{}, DesktopParameters{}, errors.New("routing local socket scope invalid")
	}
	payload, _ := json.Marshal(parameters.Routing)
	options, _, _, err := AdmitParameters(payload, platform, now, highWater)
	return options, parameters, err
}
