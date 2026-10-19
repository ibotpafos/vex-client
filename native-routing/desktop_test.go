package routing

import (
	"encoding/json"
	"strconv"
	"testing"
	"time"
)

func desktopIdentityFixture(t *testing.T, uid, gid int) []byte {
	t.Helper()
	raw, err := json.Marshal(DesktopParameters{
		Routing:                Parameters{Addresses: []string{"10.66.1.2/32"}, DNS: []string{"1.1.1.1"}, Mode: "full_tunnel"},
		PhysicalInterfaceIndex: 4, UID: uid, GID: gid,
	})
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestDesktopUnixIdentityIsAdmittedBeforeRuntimeStartup(t *testing.T) {
	for _, platform := range []string{"macos", "linux"} {
		t.Run(platform, func(t *testing.T) {
			for _, ids := range [][2]int{{0, 0}, {0, 99}, {99, 0}, {-1, 99}, {99, -1}} {
				_, _, err := AdmitDesktopParameters(desktopIdentityFixture(t, ids[0], ids[1]), platform, time.Now(), time.Time{})
				if err == nil {
					t.Fatalf("admitted invalid Unix socket identity %v", ids)
				}
			}
			options, local, err := AdmitDesktopParameters(desktopIdentityFixture(t, 99, 99), platform, time.Now(), time.Time{})
			if err != nil || local.UID != 99 || local.GID != 99 || options.Mode != "full_tunnel" {
				t.Fatalf("valid dedicated identity rejected: %v", err)
			}
		})
	}
}

func TestDesktopUnixIdentityCannotTruncateToRootOrUseTheReservedID(t *testing.T) {
	if strconv.IntSize != 64 {
		t.Skip("overflow values are unrepresentable on 32-bit Go")
	}
	for _, value := range []int64{1<<32 - 1, 1 << 32, 1<<32 + 99, 1 << 40} {
		for _, ids := range [][2]int{{int(value), 99}, {99, int(value)}} {
			if ValidUnixSocketIdentity(ids[0], ids[1]) {
				t.Fatalf("Unix identity validation accepted overflowing/reserved IDs %v", ids)
			}
			for _, platform := range []string{"macos", "linux"} {
				_, _, err := AdmitDesktopParameters(desktopIdentityFixture(t, ids[0], ids[1]), platform, time.Now(), time.Time{})
				if err == nil {
					t.Fatalf("%s admitted overflowing/reserved IDs %v", platform, ids)
				}
			}
		}
	}
}

func TestDesktopWindowsMetadataRetainsOptionalUnixIDs(t *testing.T) {
	for _, ids := range [][2]int{{0, 0}, {99, 99}} {
		_, local, err := AdmitDesktopParameters(desktopIdentityFixture(t, ids[0], ids[1]), "windows", time.Now(), time.Time{})
		if err != nil || local.UID != ids[0] || local.GID != ids[1] {
			t.Fatalf("Windows metadata compatibility changed: %v", err)
		}
	}
}

func TestDesktopIdentityBoundsIncludeRepresentableDedicatedIDs(t *testing.T) {
	if !ValidUnixSocketIdentity(1, 1) {
		t.Fatal("small positive Unix IDs rejected")
	}
	if strconv.IntSize == 64 {
		maximum := int64(1<<32 - 2)
		if !ValidUnixSocketIdentity(int(maximum), int(maximum)) {
			t.Fatal("maximum representable non-reserved Unix IDs rejected")
		}
	}
}
