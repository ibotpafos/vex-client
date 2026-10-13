package routing

import (
	"bytes"
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/netip"
	"time"
)

//go:embed policy-signing-keys.json
var policySigningKeysJSON []byte

type Parameters struct {
	Addresses             []string       `json:"addresses"`
	DNS                   []string       `json:"dns"`
	Mode                  string         `json:"mode"`
	Authorization         *Authorization `json:"authorization,omitempty"`
	PreviousAuthorization *Authorization `json:"previous_authorization,omitempty"`
}

func TrustedPolicyKeys() (map[string][]byte, error) {
	var ring struct {
		Schema string `json:"schema"`
		Keys   []struct {
			ID        string `json:"key_id"`
			Algorithm string `json:"algorithm"`
			SPKI      string `json:"subject_public_key_info_base64"`
		} `json:"keys"`
	}
	if err := json.Unmarshal(policySigningKeysJSON, &ring); err != nil {
		return nil, err
	}
	if ring.Schema != "vex.profile-signing-keyring.v1" || len(ring.Keys) < 1 || len(ring.Keys) > 8 {
		return nil, errors.New("routing trusted keyring invalid")
	}
	keys := make(map[string][]byte, len(ring.Keys))
	for _, key := range ring.Keys {
		if key.ID == "" || key.Algorithm != "ECDSA_P256_SHA256_DER" {
			return nil, errors.New("routing trusted key invalid")
		}
		der, err := base64.StdEncoding.Strict().DecodeString(key.SPKI)
		if err != nil {
			return nil, err
		}
		if _, duplicate := keys[key.ID]; duplicate {
			return nil, errors.New("routing trusted key duplicate")
		}
		keys[key.ID] = der
	}
	return keys, nil
}

// Parameters are bridge metadata, not routing authority. Only the signed
// payload and keys provisioned by the signed distribution grant DIRECT.
func AdmitParameters(raw []byte, platform string, now, highWater time.Time) (Options, Parameters, bool, error) {
	if len(raw) > 2*MaxPayloadBytes {
		return Options{}, Parameters{}, false, errors.New("routing parameters too large")
	}
	if err := rejectDuplicateJSONKeys(raw); err != nil {
		return Options{}, Parameters{}, false, err
	}
	var parameters Parameters
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&parameters); err != nil || decoder.Decode(new(any)) != io.EOF {
		return Options{}, Parameters{}, false, errors.New("routing parameters invalid")
	}
	if parameters.Mode != "full_tunnel" && parameters.Mode != "all_except_ru" {
		return Options{}, Parameters{}, false, errors.New("routing mode invalid")
	}
	if len(parameters.Addresses) == 0 || len(parameters.Addresses) > 8 || len(parameters.DNS) == 0 || len(parameters.DNS) > 8 {
		return Options{}, Parameters{}, false, errors.New("routing address count invalid")
	}
	options := Options{Mode: parameters.Mode, Platform: platform, HighWater: highWater}
	for _, value := range parameters.Addresses {
		var address netip.Addr
		if prefix, err := netip.ParsePrefix(value); err == nil {
			address = prefix.Addr()
		} else {
			address, err = netip.ParseAddr(value)
			if err != nil {
				return Options{}, Parameters{}, false, err
			}
		}
		if !address.IsGlobalUnicast() || address.Is4In6() {
			return Options{}, Parameters{}, false, errors.New("routing interface address invalid")
		}
		options.Addresses = append(options.Addresses, address)
	}
	for _, value := range parameters.DNS {
		address, err := netip.ParseAddr(value)
		if err != nil || !address.IsGlobalUnicast() || address.Is4In6() {
			return Options{}, Parameters{}, false, errors.New("routing DNS address invalid")
		}
		options.DNS = append(options.DNS, address)
	}
	keys, err := TrustedPolicyKeys()
	if err != nil {
		return Options{}, Parameters{}, false, err
	}
	if parameters.PreviousAuthorization != nil {
		if floor := policyReplayFloor(*parameters.PreviousAuthorization, keys, platform, now); floor.After(highWater) {
			highWater = floor
		}
	}
	options.HighWater = highWater
	// Remember verified history even when startup has no current authority or
	// uses full tunnel. A later background refresh must not admit an older lease.
	if parameters.Mode == "full_tunnel" || parameters.Authorization == nil {
		return options, parameters, false, nil
	}
	policy, err := VerifyPolicy(*parameters.Authorization, keys, platform, now, highWater)
	if err != nil {
		return options, parameters, false, nil
	} // Safe, compact full-tunnel fallback.
	options.Policy = policy
	options.Authorization = parameters.Authorization
	options.HighWater = policy.IssuedAt()
	return options, parameters, true, nil
}
