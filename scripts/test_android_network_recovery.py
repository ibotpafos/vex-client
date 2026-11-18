#!/usr/bin/env python3
"""Finite, opt-in WiFi interruption for the already-active QA VPN; never starts a VPN."""
import argparse
import json
import os
import re
import subprocess
import time

TARGET = 'com.vexguard.app.sdk58qa'


def snapshot(text):
    pairs = [line.split('=', 1) for line in text.splitlines() if '=' in line]
    pairs = [(k, v) for k, v in pairs if k in ('wifi_on', 'airplane_mode_on') or k.startswith('mobile_data')]
    values = dict(pairs)
    if len(values) != len(pairs) or not {'wifi_on', 'airplane_mode_on', 'mobile_data'} <= values.keys() or any(v not in ('0', '1') for v in values.values()):
        raise ValueError('SETTINGS_UNPROVEN')
    return values


def live_networks(text):
    # API28 nested request details are not networks; only exact top-level records count.
    current = re.search(r'(?m)^Current Networks:[ \t]*\n(.*?)^Network Requests:', text, re.S)
    if current:
        records = []
        for line in current[1].splitlines():
            if not line.strip():
                continue
            if line.startswith('  NetworkAgentInfo{') and line.endswith('}'):
                records.append(line.strip())
            elif not records or not line.startswith('    ') or 'NetworkAgentInfo' in line:
                raise ValueError('NETWORK_SCHEMA_UNPROVEN')
    elif 'Active networks:' in text and 'Current Networks:' not in text:
        records = [line.strip() for line in text.split('Active networks:', 1)[1].splitlines() if line.strip()]
    else:
        raise ValueError('NETWORK_SCHEMA_UNPROVEN')
    networks = []
    for record in records:
        if current:
            ni = re.findall(r'ni\{\[type: (VPN|WIFI|MOBILE|ETHERNET|BLUETOOTH)\[.*?\], state: CONNECTED/CONNECTED,.*?\]\}', record)
            nc = re.findall(r'\bnc\{\[(.*?)\]\}', record)
            if len(ni) != 1 or len(nc) != 1:
                raise ValueError('LIVE_NETWORK_UNPROVEN')
            caps = nc[0].split(' SSID:', 1)[0]
            fields = re.fullmatch(r' Transports: (VPN|WIFI|CELLULAR|ETHERNET|BLUETOOTH) Capabilities: ([A-Z_&]+)(?: .*?)?', caps)
            if not fields or fields[1] != ('CELLULAR' if ni[0] == 'MOBILE' else ni[0]):
                raise ValueError('NETWORK_SCHEMA_UNPROVEN')
            caps = re.sub(r'\bUids: <\{[0-9, -]+\}>', '', caps)
            if 'Uids:' in caps:
                raise ValueError('NETWORK_SCHEMA_UNPROVEN')
            owner = re.findall(r'(?:^| )EstablishingAppUid: (\d+)(?= |$)', caps)
            transport, valid = fields[1], 'VALIDATED' in fields[2].split('&')
        else:
            fields = re.fullmatch(r'NetworkAgentInfo \[[^\n]*?\] CONNECTED/CONNECTED Transports: (WIFI|CELLULAR|VPN|ETHERNET|BLUETOOTH)(?: (VALIDATED))?(?: OwnerUid: (\d+))?', record)
            if not fields:
                raise ValueError('LIVE_NETWORK_UNPROVEN')
            transport, valid, owner = fields[1], bool(fields[2]), [fields[3]] if fields[3] else []
        networks.append((transport, int(owner[0]) if len(owner) == 1 else None, valid))
    return networks


def qa_uid(text):
    packages = re.findall(r'(?m)^package:([\w.]+) uid:(\d+)\s*$', text)
    exact = [int(uid) for package, uid in packages if package == TARGET]
    if len(exact) != 1 or exact[0] < 10000 or sum(int(uid) == exact[0] for _, uid in packages) != 1:
        raise ValueError('EXACT_QA_UID_UNPROVEN')
    return exact[0]


def run(serial=None, execute=False, env=None, executor=subprocess.run, pause=time.sleep):
    result = {'status': 'NOTRUN', 'code': 'EXPLICIT_EXECUTION_REQUIRED', 'checks': {}}
    if not execute or (os.environ if env is None else env).get('VEX_ANDROID_DEVICE_QA') != '1' or not isinstance(serial, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}', serial):
        return result
    prefix = ['adb', '-s', serial, 'shell']
    before, mutated, attempted = None, False, False

    def command(args):
        reply = executor(prefix + args, capture_output=True, text=True, timeout=10)
        if reply.returncode:
            raise ValueError('ADB_COMMAND_FAILED')
        return reply.stdout.strip()

    def observe():
        settings = snapshot(command(['settings', 'list', 'global']))
        registry = command(['dumpsys', 'telephony.registry'])
        states = re.findall(r'\bmDataConnectionState\s*=\s*(\d+)\b', registry)
        disconnected = bool(states) and len(states) == registry.count('mDataConnectionState') and all(state == '0' for state in states)
        return settings, live_networks(command(['dumpsys', 'connectivity'])), disconnected

    def owned(networks):
        return [owner for transport, owner, _ in networks if transport == 'VPN'] == [uid]

    def data_off(settings, networks, disconnected):
        return settings.get(active_key) == '0' and disconnected and not any(t == 'CELLULAR' for t, _, _ in networks)

    try:
        uid = qa_uid(command(['pm', 'list', 'packages', '-U']))
        before, networks, _ = observe()
        subscriptions = re.findall(r'\bmDefaultDataSubId\s*=\s*(-?\d+)\b', command(['dumpsys', 'phone']))
        if len(subscriptions) != 1 or int(subscriptions[0]) < 0:
            raise ValueError('ACTIVE_SUBSCRIPTION_UNPROVEN')
        active_key = 'mobile_data' + subscriptions[0]
        if active_key not in before or before['wifi_on'] != '1' or before['airplane_mode_on'] != '0' or not owned(networks) or not any(t == 'WIFI' and valid for t, _, valid in networks):
            raise ValueError('ACTIVE_QA_WIFI_GUARD_UNPROVEN')
        if not command(['which', 'curl']):
            raise ValueError('HTTPS_PROBE_UNAVAILABLE')
        result['checks']['ownerVerified'] = True
        mutated = True
        command(['svc', 'data', 'disable'])
        for _ in range(6):
            current, networks, disconnected = observe()
            if data_off(current, networks, disconnected):
                break
            pause(1)
        else:
            raise ValueError('DATA_OFF_UNPROVEN')
        result['checks']['dataDisabled'] = True
        attempted = True
        command(['svc', 'wifi', 'disable'])
        pause(5)
        current, networks, disconnected = observe()
        if current['wifi_on'] != '0' or not data_off(current, networks, disconnected) or any(t != 'VPN' for t, _, _ in networks):
            raise ValueError('OFFLINE_UNPROVEN')
        result['checks']['offline'] = True
        command(['svc', 'wifi', 'enable'])
        for _ in range(8):
            current, networks, disconnected = observe()
            if current['wifi_on'] == '1' and data_off(current, networks, disconnected) and owned(networks) and any(t == 'WIFI' and valid for t, _, valid in networks):
                try:
                    code = command(['curl', '--proto', '=https', '--max-time', '5', '--silent', '--fail', '--output', '/dev/null', '--write-out', '%{http_code}', 'https://connectivitycheck.gstatic.com/generate_204'])
                    if code == '204':
                        result.update(status='PASS', code='WIFI_VPN_HTTPS_RECOVERED')
                        result['checks']['recovery'] = True
                        break
                except ValueError:
                    pass
            pause(2)
        else:
            raise ValueError('RECOVERY_UNPROVEN')
    except (ValueError, OSError, subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        code = 'CANCELLED' if isinstance(error, KeyboardInterrupt) else str(error) if isinstance(error, ValueError) and re.fullmatch(r'[A-Z_]+', str(error)) else 'ADB_COMMAND_FAILED'
        result.update(status='FAIL' if attempted else 'NOTRUN', code=code)
    finally:
        if mutated:
            restored = True
            for args in (['svc', 'wifi', 'enable' if before['wifi_on'] == '1' else 'disable'], ['svc', 'data', 'enable' if before[active_key] == '1' else 'disable']):
                try:
                    command(args)
                except (ValueError, OSError, subprocess.TimeoutExpired, KeyboardInterrupt):
                    restored = False
            try:
                restored = snapshot(command(['settings', 'list', 'global'])) == before and restored
            except (ValueError, OSError, subprocess.TimeoutExpired, KeyboardInterrupt):
                restored = False
            result['checks']['restored'] = restored
            if not restored:
                result.update(status='FAIL', code='RESTORE_FAILED')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--serial')
    args = parser.parse_args()
    result = run(args.serial, args.execute)
    print(json.dumps(result, sort_keys=True))
    return 0 if result['status'] == 'PASS' else 2 if result['status'] == 'NOTRUN' else 1


if __name__ == '__main__':
    raise SystemExit(main())
