"""Compile the real socket client and existing fake helper; never use /var/run."""
from pathlib import Path
import subprocess
import tempfile
import os

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / "macos-native/Sources/VEXNativeMac/VEXHelperClient.swift").read_text()
client = source[source.index("struct VEXHelperClient {"):]
source = (ROOT / "macos-native/Tests/VEXNativeMacTests/HelperSocketSimulationTests.swift").read_text()
fixture = source[source.index("private final class SequencedHelperSocket:"):source.index("private final class SimulatedHelperSocket:")]
fixture = fixture.replace('path = "/tmp/vex-helper-sequence-', 'path = CommandLine.arguments[1] + "/vex-helper-sequence-',1)
harness = r"""
@main
struct SocketHarness {
    static func main() async throws {
        let server = try SequencedHelperSocket { command, attempt in
            if command == "down" { return "ok\n" }
            return attempt < 2
                ? "state=connected route_ok=true socket_exists=true\n"
                : "state=disconnected route_ok=false socket_exists=false\n"
        }
        defer { server.stop() }
        precondition(server.path.hasPrefix(CommandLine.arguments[1] + "/vex-helper-sequence-") && server.path.utf8.count < 104)
        let disconnected = try await VEXHelperClient(socketPath: server.path)
            .disconnectAndConfirm(maxStatusAttempts: 3, pollNanoseconds: 1_000_000)
        precondition(disconnected.state == .disconnected)
        precondition(server.waitForCommands(count: 3) == ["down", "status", "status"])
        for response in ["state=connected route_ok=true socket_exists=true\n", "error: unauthorized\n", "ok\n", "state=disconnected\n", "state=disconnected route_ok=false socket_exists=false leak_protection=armed\n"] {
            let rejected = try SequencedHelperSocket { command, _ in command == "down" ? "ok\n" : response }
            defer { rejected.stop() }
            do {
                _ = try await VEXHelperClient(socketPath: rejected.path)
                    .disconnectAndConfirm(maxStatusAttempts: 2, pollNanoseconds: 1_000_000)
                preconditionFailure("unsafe disconnect confirmation accepted")
            } catch let error as VEXHelperError {
                guard case .commandFailed = error else { throw error }
            }
        }
        print("PASS: real socket client waits for teardown; rejects connected, malformed and armed states; system helper untouched")
    }
}
"""
short_tmp = os.environ.get("VEX_NATIVE_SOCKET_TEST_TMPDIR")
if short_tmp: Path(short_tmp).mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix="vex-socket-",dir=short_tmp) as directory:
    temporary = Path(directory)
    swift = temporary / "main.swift"
    swift.write_text("import Foundation\nimport Darwin\nimport SwiftUI\n" + client + fixture + harness)
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", str(swift), str(ROOT / "macos-native/Sources/VEXNativeMac/Services/HelperDisconnectConfirmation.swift"), "-o", str(temporary / "probe")], check=True)
    subprocess.run([str(temporary / "probe"), str(temporary)], check=True, timeout=30)
