#!/usr/bin/env python3
"""Explicitly run an already-installed preview test APK; never build/install/start JS."""
import argparse
import re
import subprocess

TARGET = 'com.vexguard.app.sdk58preview'
COMPONENT = TARGET + '.test/com.vexguard.app.vpn.NativeHttpInstrumentation'
SUCCESS = 'NATIVE_HTTP_OK tests=21 failures=0'


def run(serial, execute=subprocess.run):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:-]*', serial):
        raise ValueError('EXPLICIT_SERIAL_REQUIRED')
    prefix = ['adb', '-s', serial, 'shell']
    def command(args, timeout):
        result = execute(prefix + args, capture_output=True, text=True, timeout=timeout)
        if result.returncode:
            raise ValueError('ADB_COMMAND_FAILED')
        return result.stdout
    dump = command(['dumpsys', 'package', TARGET], 15)
    if not re.search(r'(?<![\w.])' + re.escape(TARGET) + r'(?![\w.])', dump) or not re.search(r'(?m)^\s*flags=\[[^\]\n]*\bDEBUGGABLE\b[^\]\n]*\]', dump):
        raise ValueError('EXACT_DEBUG_PREVIEW_REQUIRED')
    output = command(['am', 'instrument', '-w', '-r', COMPONENT], 180)
    if (not re.search(r'(?m)^' + re.escape(SUCCESS) + r'\r?$', output)
            or not re.search(r'INSTRUMENTATION_CODE: -1\s*$', output)
            or 'NATIVE_HTTP_FAIL' in output or 'INSTRUMENTATION_FAILED' in output):
        raise ValueError('NATIVE_HTTP_ACCEPTANCE_MISSING')
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--execute', action='store_true', required=True,
                        help='main/operator coordination required; APKs must already be installed')
    args = parser.parse_args()
    try:
        print(run(args.serial), end='')
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f'NATIVE_HTTP_FAIL {error}\n')


if __name__ == '__main__':
    main()
