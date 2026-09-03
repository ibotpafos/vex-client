#!/usr/bin/env python3
"""Nonprivileged real-signature policy checks. Args: signed correct-ID probe, signed wrong-ID probe."""
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
GOOD, WRONG_ID = map(pathlib.Path, sys.argv[1:3])
SHA1 = 'c6fd1853a177fbcfb04c5d4f78fbe405777b3a3e'
REQUIREMENT = f'identifier "app.vex.vpn.native" and (certificate leaf = H"{SHA1}" or (anchor apple generic and certificate leaf[subject.OU] = "3JLW9XNU53"))'


def run(*args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, **kwargs)


with tempfile.TemporaryDirectory(prefix='vex-signing-policy-') as temporary:
    tmp = pathlib.Path(temporary)
    probe = tmp / 'probe'
    build = run('swiftc', str(ROOT / 'macos-native/Sources/VEXHelperCore/PeerAuthenticator.swift'), str(ROOT / 'scripts/tests/vex_local_signing_policy_probe.swift'), '-framework', 'Security', '-framework', 'SystemConfiguration', '-lbsm', '-o', str(probe))
    assert build.returncode == 0, build.stderr
    adhoc = tmp / 'adhoc'
    shutil.copyfile(GOOD, adhoc)
    adhoc.chmod(0o755)
    assert run('/usr/bin/codesign', '--force', '--sign', '-', '--identifier', 'app.vex.vpn.native', str(adhoc)).returncode == 0
    tampered = tmp / 'tampered'
    shutil.copyfile(GOOD, tampered)
    data = bytearray(tampered.read_bytes())
    data[4096] ^= 1
    tampered.write_bytes(data)
    for name, path, expectation in [('correct-cert', GOOD, 'accept'), ('wrong-identifier', WRONG_ID, 'reject'), ('adhoc-correct-id', adhoc, 'reject'), ('tampered', tampered, 'reject')]:
        result = run(str(probe), str(path), expectation)
        assert result.returncode == 0, (name, result.stdout, result.stderr)
        signature = run('/usr/bin/codesign', '--verify', '--deep', '--strict', '-R=' + REQUIREMENT, str(path))
        assert (signature.returncode == 0) == (expectation == 'accept'), signature.stderr
        print(f'{name}: {result.stdout.strip()}; codesign exit={signature.returncode}')
    # Isolate the certificate predicate against an unrelated, valid Apple certificate.
    wrong_cert = run('/usr/bin/codesign', '--verify', '--strict', '-R=certificate leaf = H"' + SHA1 + '"', '/bin/echo')
    assert wrong_cert.returncode != 0
    print('wrong-certificate: reject')
    import os
    env = dict(os.environ, PROBE_EXPECT='reject', VEX_EXPECTED_TEAM_ID='3JLW9XNU53" or true /*', VEX_HELPER_ALLOW_ADHOC_CLIENT='1', VEX_EXPECTED_CERT_SHA256='anything')
    result = run(str(probe), env=env)
    assert result.returncode == 0, result.stderr
    print('environment-injection: ' + result.stdout.strip())
    installer = (ROOT / 'scripts/install_native_macos_helper_from_app.sh').read_text()
    quote_function = re.search(r'shell_quote\(\) \{.*?\n\}', installer, re.S).group()
    marker = tmp / 'injection-executed'
    for value in ["a'b", 'spaces and \\"quotes', 'line1\nline2', '$(touch ' + str(marker) + ')', '; touch ' + str(marker)]:
        quoted = run('/bin/bash', '-c', quote_function + '\nshell_quote "$1"', 'test', value)
        result = run('/bin/bash', '-c', "printf '%s' " + quoted.stdout)
        assert result.returncode == 0 and result.stdout == value
        assert not marker.exists()
    print('shell-input-injection: 5/5 literal round trips; no execution')
    for path in ['macos-native/Sources/VEXHelperCore/PeerAuthenticator.swift', 'macos-native/Sources/VEXNativeMac/Services/VEXHelperInstaller.swift', 'macos-native/HelperResources/install-vex-vpn-helper.sh', 'scripts/install_native_macos_helper_from_app.sh']:
        assert SHA1 in (ROOT / path).read_text(), path
    print('fixed-pin-consistency: 4/4 files')
print('PASS: local signing policy matrix')
