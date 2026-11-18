"""Execute the production disconnect body with in-memory Android/backend boundaries.

Requires an explicit Kotlin compiler classpath and stdlib; never runs Gradle,
ADB, VpnService, or a real tunnel. Example invocation is recorded in the work
evidence. This fixture verifies result/ownership policy, not Android FD release.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "android/app/src/main/java/com/vexguard/app/vpn/WireGuardController.kt"


def disconnect_method(source):
    start = source.index("  suspend fun disconnect(releaseAntiLeak: Boolean)")
    opening = source.index("{", start)
    depth = 1
    for index in range(opening + 1, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError("production disconnect method is incomplete")


HARNESS = r'''
object Dispatchers { val IO = Unit }
suspend fun <T> withContext(context: Unit, block: suspend () -> T): T = block()
class Mutex { suspend fun <T> withLock(block: suspend () -> T): T = block() }
sealed interface VpnConnectionState {
  data object Disconnected : VpnConnectionState
  data object Blocking : VpnConnectionState
}
object VexLeakBlockerService {
  var active = false
  var startSucceeds = true
  var stopSucceeds = true
  var starts = 0
  var stops = 0
  suspend fun startAndAwait(context: Unit, applications: List<String>): Boolean {
    starts++
    active = startSucceeds
    return active
  }
  suspend fun stopAndAwait(context: Unit): Boolean {
    stops++
    if (stopSucceeds) active = false
    return stopSucceeds
  }
  fun reset() {
    active = false; startSucceeds = true; stopSucceeds = true; starts = 0; stops = 0
  }
}
class Backend(var capture: Boolean) {
  var releases = 0
  var downs = 0
  var downFails = false
  fun hasRoutingCapture() = capture
  fun releaseRetainedRoutingCapture() { releases++; capture = false }
  fun down() { downs++; if (downFails) error("backend failure") }
}
class Controller(capture: Boolean) {
  val appContext = Unit
  val backend = Backend(capture)
  val tunnelMutex = Mutex()
  var transitionState: String? = null
  var antiLeakArmed = true
  var lastConfigText: String? = "admitted config"
  var lastRoutingParameters: String? = "admitted routing"
  var lastRoutedApplications = emptyList<String>()
  fun setTunnelDown() = backend.down()
  // PRODUCTION_METHOD
}
suspend fun main() {
  VexLeakBlockerService.reset()
  val retained = Controller(true)
  check(retained.disconnect(false) == VpnConnectionState.Blocking)
  check(retained.backend.capture && retained.backend.releases == 0)
  check(VexLeakBlockerService.starts == 0)
  check(retained.lastConfigText == null && retained.transitionState == null)

  VexLeakBlockerService.reset()
  val blocker = Controller(false)
  check(blocker.disconnect(false) == VpnConnectionState.Blocking)
  check(VexLeakBlockerService.active && VexLeakBlockerService.starts == 1)
  check(blocker.backend.releases == 0)

  VexLeakBlockerService.reset()
  VexLeakBlockerService.active = true
  val manual = Controller(true)
  check(manual.disconnect(true) == VpnConnectionState.Disconnected)
  check(!manual.antiLeakArmed && !manual.backend.capture)
  check(manual.backend.releases == 1 && VexLeakBlockerService.stops == 1)
  check(!VexLeakBlockerService.active)

  VexLeakBlockerService.reset()
  VexLeakBlockerService.stopSucceeds = false
  val failedStop = Controller(true)
  check(runCatching { failedStop.disconnect(true) }.isFailure)
  check(failedStop.backend.downs == 0 && failedStop.backend.releases == 0)
  check(failedStop.antiLeakArmed && failedStop.transitionState == null)

  VexLeakBlockerService.reset()
  VexLeakBlockerService.startSucceeds = false
  val failedBlocker = Controller(false)
  check(runCatching { failedBlocker.disconnect(false) }.isFailure)
  check(failedBlocker.backend.releases == 0 && failedBlocker.transitionState == null)

  VexLeakBlockerService.reset()
  val failedBackend = Controller(true)
  failedBackend.backend.downFails = true
  check(runCatching { failedBackend.disconnect(false) }.isFailure)
  check(failedBackend.backend.capture && failedBackend.backend.releases == 0)
  check(failedBackend.transitionState == null)
  println("ANDROID_DISCONNECT_STATE=PASS (6 scenarios)")
}
'''


class AndroidDisconnectStateTest(unittest.TestCase):
    def test_disconnect_preserves_capture_and_reports_blocking_until_user_release(self):
        compiler = os.environ.get("VEX_KOTLIN_COMPILER_CLASSPATH")
        stdlib = os.environ.get("VEX_KOTLIN_STDLIB")
        java = os.environ.get("VEX_KOTLIN_JAVA", "java")
        if not compiler or not stdlib:
            self.skipTest("explicit host Kotlin compiler and stdlib required")
        source = disconnect_method(SOURCE.read_text())
        with tempfile.TemporaryDirectory(prefix="vex-disconnect-host-") as directory:
            root = Path(directory)
            fixture = root / "DisconnectFixture.kt"
            fixture.write_text(HARNESS.replace("// PRODUCTION_METHOD", source))
            output = root / "classes"
            compiled = subprocess.run([
                java, "-Xmx256m", "-cp", compiler,
                "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
                "-no-stdlib", "-no-reflect", "-classpath", stdlib,
                "-d", str(output), str(fixture),
            ], capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([
                java, "-Xmx64m", "-cp", str(output) + os.pathsep + stdlib,
                "DisconnectFixtureKt",
            ], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("ANDROID_DISCONNECT_STATE=PASS (6 scenarios)", result.stdout)


if __name__ == "__main__":
    unittest.main()
