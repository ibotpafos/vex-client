import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('native_http', ROOT / 'scripts/test_android_native_http.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class GuardTests(unittest.TestCase):
    def run_probe(self, dump=None, output=None, code=0):
        calls = []
        def execute(args, **kwargs):
            calls.append(args)
            return subprocess.CompletedProcess(args, code, dump if len(calls) == 1 else output, '')
        result = m.run('emulator-5558', execute)
        return result, calls

    def test_exact_debug_preview(self):
        result, calls = self.run_probe(m.TARGET + '\nflags=[ DEBUGGABLE HAS_CODE ]', m.SUCCESS + '\nINSTRUMENTATION_CODE: -1')
        self.assertEqual(result, m.SUCCESS + '\nINSTRUMENTATION_CODE: -1')
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[1], ['adb', '-s', 'emulator-5558', 'shell', 'am', 'instrument', '-w', '-r', m.COMPONENT])

    def test_raw_result_stream_requires_final_success_code(self):
        dump = m.TARGET + '\nflags=[ DEBUGGABLE HAS_CODE ]'
        raw_stream = 'INSTRUMENTATION_RESULT: stream=\n' + m.SUCCESS + '\n\n'
        output = raw_stream + 'INSTRUMENTATION_CODE: -1\n'
        result, calls = self.run_probe(dump, output)
        self.assertEqual(result, output)
        self.assertEqual(calls[1][-3:], ['-w', '-r', m.COMPONENT])
        for incomplete in [raw_stream, raw_stream + 'INSTRUMENTATION_CODE: 0\n']:
            with self.assertRaises(ValueError): self.run_probe(dump, incomplete)

    def test_missing_or_release_package_stops_before_instrumentation(self):
        for dump in ['', m.TARGET, 'com.vexguard.app\nflags=[ DEBUGGABLE ]', m.TARGET + '\nprivateFlags=[ DEBUGGABLE ]']:
            fake = Mock(return_value=subprocess.CompletedProcess([], 0, dump, ''))
            with self.assertRaises(ValueError): m.run('owned-device', fake)
            self.assertEqual(fake.call_count, 1)

    def test_invalid_serial_zero_commands(self):
        for serial in ['', '-d', 'device;reboot', 'a b']:
            fake = Mock()
            with self.assertRaises(ValueError): m.run(serial, fake)
            fake.assert_not_called()

    def test_adb_failure(self):
        with self.assertRaises(ValueError): self.run_probe('anything', code=1)

    def test_incomplete_results_rejected(self):
        for output in ['', 'INSTRUMENTATION_CODE: -1', 'NATIVE_HTTP_OK tests=18 failures=0', 'NATIVE_HTTP_OK tests=21 failures=1', m.SUCCESS, m.SUCCESS + '\nINSTRUMENTATION_CODE: 0']:
            with self.assertRaises(ValueError): self.run_probe(m.TARGET + '\nflags=[ DEBUGGABLE ]', output)

    def test_cli_requires_explicit_execution_without_adb(self):
        for args in [[], ['--serial', 'owned-device']]:
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/test_android_native_http.py'), *args], capture_output=True)
            self.assertEqual(result.returncode, 2)

    def test_only_real_selected_tests_are_reused(self):
        gradle = (ROOT / 'android/app/build.gradle').read_text()
        self.assertIn("tasks.register('prepareNativeHttpTestSources', Sync)", gradle)
        self.assertIn("from('src/test/java')", gradle)
        self.assertIn("dependsOn nativeHttpTestSources", gradle)
        for name in ['ApiHttpSafetyTest.kt', 'ApiRecoveryPolicyTest.kt']:
            self.assertIn('com/vexguard/app/vpn/' + name, gradle)
            self.assertFalse(list((ROOT / 'android/app/src/androidTest').rglob(name)))
        self.assertIn("androidTestImplementation 'junit:junit:4.13.2'", gradle)

    def test_runner_blocks_automatic_provider_initialization(self):
        source = (ROOT / 'android/app/src/androidTest/java/com/vexguard/app/vpn/NativeHttpInstrumentation.kt').read_text()
        self.assertIn('PackageManager.GET_PROVIDERS', source)
        self.assertIn('getComponentEnabledSetting', source)
        self.assertIn('ENABLED_TARGET_PROVIDER_FORBIDDEN', source)

    def test_runner_failure_diagnostics_are_bounded_and_assertions_identified(self):
        runner = (ROOT / 'android/app/src/androidTest/java/com/vexguard/app/vpn/NativeHttpInstrumentation.kt').read_text()
        for token in ['nativeHttpFailureDetails', 'error.message.orEmpty()', 'stackTrace.take(8)',
                      '.take(256)', '.take(1536)', 'result.failures.take(3)', 'error.message.orEmpty().take(4096)']:
            self.assertIn(token, runner)
        source = (ROOT / 'android/app/src/test/java/com/vexguard/app/vpn/ApiHttpSafetyTest.kt').read_text()
        for label in ['TLS_FACTORY_IDENTITY', 'TLS_HOSTNAME_VERIFIER_IDENTITY', 'TLS_CERTIFICATE_PINNER',
                      'PLATFORM_DEFAULT_SOCKET_FACTORY_IDENTITY', 'NO_INHERITED_INTERCEPTORS']:
            self.assertIn('"' + label + '"', source)
        self.assertIn('assertSame("TLS_FACTORY_IDENTITY", base.sslSocketFactory, client.sslSocketFactory)', source)
        self.assertIn('assertSame("PLATFORM_DEFAULT_SOCKET_FACTORY_IDENTITY", javax.net.SocketFactory.getDefault(), client.socketFactory)', source)

    def test_fixture_uses_portable_strict_exact_read(self):
        source = (ROOT / 'android/app/src/test/java/com/vexguard/app/vpn/ApiHttpSafetyTest.kt').read_text()
        self.assertNotIn('readNBytes', source)
        self.assertIn('import java.io.DataInputStream', source)
        self.assertIn('val body = ByteArray(length)\n            DataInputStream(input).readFully(body)', source)
        self.assertLess(source.index('readFully(body)'), source.index('check(body.size == length)'))
        self.assertLess(source.index('readFully(body)'), source.index('requests.add(Received(method, headers, body))'))
        policy = (ROOT / 'android/app/src/test/java/com/vexguard/app/vpn/ApiRecoveryPolicyTest.kt').read_text()
        self.assertEqual(source.count('@Test') + policy.count('@Test'), 18)

    def test_runner_guards_before_application_and_tests(self):
        source = (ROOT / 'android/app/src/androidTest/java/com/vexguard/app/vpn/NativeHttpInstrumentation.kt').read_text()
        self.assertIn('ApplicationInfo.FLAG_DEBUGGABLE', source)
        self.assertIn('com.vexguard.app.sdk58preview', source)
        self.assertLess(source.index('guard(context)'), source.index('super.newApplication'))
        self.assertLess(source.index('guard(targetContext)'), source.index('JUnitCore().run'))
        self.assertIn('Application::class.java.name', source)
        self.assertIn('TODO', source)
        self.assertIn('Build.VERSION.SDK_INT >= 24', source)

if __name__ == '__main__': unittest.main()
