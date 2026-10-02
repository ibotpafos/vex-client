#!/usr/bin/env python3
"""Compile real HelperRuntime with memory ports; use only disposable Unix sockets."""
from pathlib import Path
import os
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "macos-native/Sources/VEXHelperCore"
HARNESS = ROOT / "macos-native/Tests/OfflineHarness/PendingJournalRuntime.swift"


def request(path: Path, command: str) -> str:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(5)
        client.connect(str(path))
        client.sendall((command + "\n").encode())
        output = b""
        while b"\n" not in output:
            chunk = client.recv(4096)
            if not chunk:
                break
            output += chunk
        return output.decode()


with tempfile.TemporaryDirectory(prefix="vex-journal-") as raw:
    directory = Path(raw)
    binary = directory / "probe"
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library",
                    *map(str, sorted(CORE.glob("*.swift"))), str(HARNESS),
                    "-framework", "Security", "-framework", "SystemConfiguration", "-lbsm",
                    "-o", str(binary)], check=True, timeout=180)
    subprocess.run([str(binary), str(directory)], check=True, timeout=60)
    # A real UnixSocketServer, but only memory tunnel/PF ports. Terminate only
    # the child fixture process we own; never locate or signal a system helper.
    short_root = os.environ.get("VEX_NATIVE_SOCKET_TEST_TMPDIR", "/tmp")
    Path(short_root).mkdir(parents=True, exist_ok=True)
    for phase in ("corrupt", "absent"):
        with tempfile.TemporaryDirectory(prefix="vex-jr-", dir=short_root) as raw_socket:
            scratch = Path(raw_socket)
            path = scratch / "server.sock"
            assert len(str(path).encode()) < 104
            process = subprocess.Popen([str(binary), "--serve", str(scratch), phase],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 10
                while not path.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.01)
                assert path.exists(), "fixture socket did not start"
                response = request(path, "shutdown")
                if phase == "corrupt":
                    assert response.startswith("error: protected replacement recovery pending"), response
                    assert not (scratch / "cleanup.done").exists()
                    assert process.poll() is None, "pending recovery incorrectly exited the fixture"
                    assert "recovery_pending=true" in request(path, "status")
                else:
                    assert response == "ok\n", response
                    assert (scratch / "cleanup.done").read_text() == "fixture cleanup completed\n", "premature shutdown acknowledgement"
                    assert process.wait(timeout=5) == 0
                print(f"PASS socket shutdown phase={phase}: response follows actual fake-runtime result")
            finally:
                if process.poll() is None:
                    process.terminate()
                stdout, stderr = process.communicate(timeout=10)
                if stdout:
                    print(stdout.decode(errors="replace"))
                if stderr:
                    print(stderr.decode(errors="replace"))
    print("PASS pending-journal runtime/RPC/races/filesystem/socket checks; live network mutations=0")
