import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('network_recovery', ROOT / 'scripts/test_android_network_recovery.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
ENV = {'VEX_ANDROID_DEVICE_QA': '1'}


class Device:
    """Controlled host fixture only; never invokes adb or a physical network."""
    def __init__(self):
        self.settings = {'wifi_on': '1', 'airplane_mode_on': '0', 'mobile_data': '1', 'mobile_data1': '1', 'mobile_data2': '1', 'mobile_data_always_on': '1'}
        self.before = self.settings.copy()
        self.calls, self.https, self.sleeps = [], [], []
        self.packages = 'package:com.vexguard.app.sdk58qa uid:10182\npackage:com.vexguard.app uid:10181\n'
        self.sub = 'mDefaultDataSubId=1'
        self.owner, self.extra_vpn, self.cell, self.unknown = 10182, False, False, False
        self.states = None
        self.fail_on, self.cancel_sleep, self.restore_error = None, False, False

    def networks(self):
        if self.unknown:
            return 'unrecognized vendor dump'
        rows = ['Active networks:']
        if self.settings['wifi_on'] == '1':
            rows.append('NetworkAgentInfo [WIFI () - 101] CONNECTED/CONNECTED Transports: WIFI VALIDATED')
        if self.cell:
            rows.append('NetworkAgentInfo [MOBILE (LTE) - 102] CONNECTED/CONNECTED Transports: CELLULAR')
        rows.append(f'NetworkAgentInfo [VPN () - 103] CONNECTED/CONNECTED Transports: VPN OwnerUid: {self.owner}')
        if self.extra_vpn:
            rows.append('NetworkAgentInfo [VPN () - 104] CONNECTED/CONNECTED Transports: VPN OwnerUid: 10999')
        return '\n'.join(rows)

    def execute(self, args, **kwargs):
        if args[:4] != ['adb', '-s', 'owned-device', 'shell']:
            raise AssertionError('Unexpected executor scope')
        command = args[4:]
        self.calls.append(command)
        if command == ['settings', 'list', 'global']:
            output = '\n'.join(f'{k}={v}' for k, v in self.settings.items())
        elif command == ['pm', 'list', 'packages', '-U']:
            output = self.packages
        elif command == ['dumpsys', 'phone']:
            output = self.sub
        elif command == ['dumpsys', 'telephony.registry']:
            output = self.states if self.states is not None else 'mDataConnectionState=0\nmDataConnectionState=0'
        elif command == ['dumpsys', 'connectivity']:
            output = self.networks()
        elif command == ['which', 'curl']:
            output = '/system/bin/curl'
        elif command[:2] == ['svc', 'data']:
            if command[2] == 'enable' and self.restore_error:
                return subprocess.CompletedProcess(args, 1, '', 'private diagnostic must not leak')
            self.settings['mobile_data1'] = '1' if command[2] == 'enable' else '0'
            output = ''
        elif command[:2] == ['svc', 'wifi']:
            self.settings['wifi_on'] = '1' if command[2] == 'enable' else '0'
            output = ''
        elif command[0] == 'curl':
            self.https.append(self.settings['wifi_on'] == '1' and self.settings['mobile_data1'] == '0')
            output = '204'
        else:
            raise AssertionError('Unexpected command')
        if self.fail_on == command:
            self.fail_on = None
            raise OSError('private endpoint diagnostic must not leak')
        return subprocess.CompletedProcess(args, 0, output, '')

    def pause(self, seconds):
        self.sleeps.append(seconds)
        if self.cancel_sleep:
            raise KeyboardInterrupt()

    def run(self):
        return m.run('owned-device', execute=True, env=ENV, executor=self.execute, pause=self.pause)


def current_dump(owner=' EstablishingAppUid: 10182', vpn_caps='INTERNET&TRUSTED&VALIDATED', extra=''):
    return ('Current Networks:\n'
            '  NetworkAgentInfo{ ni{[type: VPN[], state: CONNECTED/CONNECTED, reason: (unspecified)]} network{103} nc{[ Transports: VPN Capabilities: ' + vpn_caps + ' Unwanted:  Uids: <{0-99999}>' + owner + ']} Score{101} everValidated{true} }\n'
            '    Requests: 2\n      request details omitted\n'
            '  NetworkAgentInfo{ ni{[type: WIFI[], state: CONNECTED/CONNECTED, reason: (unspecified)]} network{101} nc{[ Transports: WIFI Capabilities: INTERNET&NOT_VPN&VALIDATED SSID: <REDACTED>]} Score{60} }\n'
            + extra + '\nNetwork Requests:\n  unrelated OwnerUid: 10999\n')


class GuardTests(unittest.TestCase):
    def test_current_networks_braced_api28_owner_capabilities_and_boundary(self):
        self.assertEqual(m.live_networks(current_dump()), [('VPN', 10182, True), ('WIFI', None, True)])
        device = Device()
        def networks():
            if device.settings['wifi_on'] == '1':
                return current_dump()
            return 'Current Networks:\n\nNetwork Requests:\n  ignored disconnected history'
        device.networks = networks
        self.assertEqual(device.run()['status'], 'PASS')

    def test_nc_owner_cannot_be_spoofed_by_ssid_uid_ranges_or_outer_fields(self):
        for owner in ['', ' SSID: EstablishingAppUid: 10182', ' OwnerUid: 10182',
                      ' EstablishingAppUid: 10999 SSID: EstablishingAppUid: 10182',
                      ' EstablishingAppUid: 10182 EstablishingAppUid: 10999']:
            device = Device()
            device.networks = lambda: current_dump(owner).replace('Score{101}', 'Score{101} EstablishingAppUid: 10182')
            result = device.run()
            self.assertEqual(result['status'], 'NOTRUN')
            self.assertFalse(any(c[:1] == ['svc'] for c in device.calls))

    def test_uid_range_payload_and_ssid_validation_are_not_authority(self):
        device = Device()
        device.networks = lambda: current_dump(owner='').replace('Uids: <{0-99999}>', 'Uids: <{0-99999 EstablishingAppUid: 10182 }>')
        self.assertEqual(device.run()['status'], 'NOTRUN')
        self.assertFalse(any(c[:1] == ['svc'] for c in device.calls))
        text = current_dump().replace('INTERNET&NOT_VPN&VALIDATED SSID: <REDACTED>', 'INTERNET&NOT_VPN SSID: VALIDATED EstablishingAppUid: 10182')
        self.assertFalse(m.live_networks(text)[1][2])

    def test_current_networks_unknown_mixed_and_capability_spoofs_refused(self):
        for text in [current_dump().replace('Transports: VPN', 'Transports: VPN|CELLULAR'),
                     current_dump().replace('type: VPN[]', 'type: WIFI[]'),
                     current_dump(extra='  unrecognized network record\n'),
                     current_dump(extra='    NetworkAgentInfo unexpected\n'),
                     current_dump().replace('Network Requests:', 'Unknown Boundary:'),
                     current_dump().replace('Transports: WIFI', 'Transports: WIFI|VPN')]:
            device = Device()
            device.networks = lambda: text
            self.assertEqual(device.run()['status'], 'NOTRUN')
            self.assertFalse(any(c[:1] == ['svc'] for c in device.calls))
        self.assertFalse(m.live_networks(current_dump(vpn_caps='INTERNET&NOT_VALIDATED'))[0][2])

    def test_all_execution_gates_precede_any_executor_io(self):
        for serial, execute, env in [('', True, ENV), ('-d', True, ENV), ('a b', True, ENV), ('a;reboot', True, ENV), ('a', False, ENV), ('a', True, {}), ('a', True, {'VEX_ANDROID_DEVICE_QA': 'true'})]:
            fake = Mock()
            result = m.run(serial, execute=execute, env=env, executor=fake)
            self.assertEqual(result['status'], 'NOTRUN')
            fake.assert_not_called()

    def test_active_sub_data_key_not_stale_global_controls_proof(self):
        device = Device()
        result = device.run()
        self.assertEqual(result['status'], 'PASS')
        self.assertTrue(result['checks']['dataDisabled'])
        self.assertEqual(device.settings, device.before)
        self.assertEqual(device.settings['mobile_data'], '1')
        self.assertIn(5, device.sleeps)
        self.assertTrue(device.https and all(device.https))

    def test_unknown_or_invalid_active_subscription_never_turns_wifi_off(self):
        for sub in ['', 'mDefaultDataSubId=-1', 'mDefaultDataSubId=2\nmDefaultDataSubId=1', 'mDefaultDataSubId=3']:
            device = Device()
            device.sub = sub
            result = device.run()
            self.assertEqual(result['status'], 'NOTRUN')
            self.assertFalse(any(c[:1] == ['svc'] for c in device.calls))

    def test_unproved_owner_shared_uid_and_lookalikes_never_mutate(self):
        for mode in ['other-owner', 'lookalike', 'shared-uid', 'extra-vpn', 'unknown']:
            device = Device()
            if mode == 'other-owner': device.owner = 10181
            if mode == 'lookalike': device.packages = 'package:com.vexguard.app.sdk58qa.other uid:10182'
            if mode == 'shared-uid': device.packages += 'package:other.app uid:10182\n'
            if mode == 'extra-vpn': device.extra_vpn = True
            if mode == 'unknown': device.unknown = True
            result = device.run()
            self.assertEqual(result['status'], 'NOTRUN')
            self.assertFalse(any(c[:1] == ['svc'] for c in device.calls))

    def test_cell_or_any_unproved_telephony_state_blocks_wifi_off_and_restores_data(self):
        for states, cell in [('', False), ('mDataConnectionState=2\nmDataConnectionState=0', False), ('mDataConnectionState=0', True)]:
            device = Device()
            device.states, device.cell = states, cell
            result = device.run()
            self.assertNotEqual(result['status'], 'PASS')
            self.assertNotIn(['svc', 'wifi', 'disable'], device.calls)
            self.assertEqual(device.settings, device.before)

    def test_unknown_network_lines_and_mixed_cellular_never_count_as_offline(self):
        for extra in ['VendorNetwork CELLULAR CONNECTED', 'NetworkAgentInfo [unknown] CONNECTED/CONNECTED Transports: WIFI|CELLULAR', 'NetworkAgentInfo [unknown] CONNECTED/CONNECTED Transports: WIFI VPN', '\nVendorNetwork unknown']:
            device = Device()
            original = device.networks
            device.networks = lambda: original() + '\n' + extra
            self.assertEqual(device.run()['status'], 'NOTRUN')
            self.assertFalse(any(c[:1] == ['svc'] for c in device.calls))

    def test_original_active_data_off_is_restored_off_with_stale_global_on(self):
        device = Device()
        device.settings['mobile_data1'] = '0'
        device.before = device.settings.copy()
        self.assertEqual(device.run()['status'], 'PASS')
        self.assertEqual(device.settings, device.before)
        self.assertEqual(device.calls[-2], ['svc', 'data', 'disable'])

    def test_recovery_timeout_restores_without_claiming_success(self):
        device = Device()
        original = device.execute
        def fail_https(args, **kwargs):
            reply = original(args, **kwargs)
            if args[4] == 'curl':
                return subprocess.CompletedProcess(args, 1, '', 'private diagnostic')
            return reply
        result = m.run('owned-device', execute=True, env=ENV, executor=fail_https, pause=device.pause)
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(result['code'], 'RECOVERY_UNPROVEN')
        self.assertTrue(result['checks']['restored'])
        self.assertEqual(device.settings, device.before)
        self.assertEqual(len(device.https), 8)

    def test_os_error_after_wifi_disable_restores_both_flags(self):
        device = Device()
        device.fail_on = ['svc', 'wifi', 'disable']
        result = device.run()
        self.assertEqual(result['status'], 'FAIL')
        self.assertTrue(result['checks']['restored'])
        self.assertEqual(device.settings, device.before)
        self.assertEqual(device.https, [])
        self.assertNotIn('private', json.dumps(result))

    def test_cancellation_during_offline_wait_restores_both_flags(self):
        device = Device()
        device.cancel_sleep = True
        result = device.run()
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(result['code'], 'CANCELLED')
        self.assertTrue(result['checks']['restored'])
        self.assertEqual(device.settings, device.before)
        self.assertEqual(device.https, [])

    def test_restoration_failure_is_fatal_even_after_recovery(self):
        device = Device()
        device.restore_error = True
        result = device.run()
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(result['code'], 'RESTORE_FAILED')
        self.assertFalse(result['checks']['restored'])
        self.assertEqual(device.settings['wifi_on'], '1')

    def test_airplane_unknown_setting_or_original_wifi_off_never_mutates(self):
        for key, value in [('airplane_mode_on', '1'), ('wifi_on', '0'), ('mobile_data2', 'null')]:
            device = Device()
            device.settings[key] = value
            result = device.run()
            self.assertEqual(result['status'], 'NOTRUN')
            self.assertFalse(any(c[:1] == ['svc'] for c in device.calls))

    def test_cli_without_execute_or_serial_emits_json_notrun(self):
        for args in [[], ['--serial', 'owned-device'], ['--execute']]:
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/test_android_network_recovery.py'), *args], capture_output=True, text=True, env={**os.environ, 'VEX_ANDROID_DEVICE_QA': '1'})
            self.assertEqual(result.returncode, 2)
            self.assertEqual(json.loads(result.stdout)['status'], 'NOTRUN')


if __name__ == '__main__':
    unittest.main()
