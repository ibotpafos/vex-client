#!/usr/bin/env python3
"""Run real XCTest baseline/modified/rollback on disposable Git snapshots.

Uses SwiftPM, Git and Python's standard library. No helper installation, signing,
production credentials, network configuration or live VPN commands are invoked.
"""
import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile

FILES = [
    "macos-native/Tests/VEXNativeMacTests/SwiftHelperContractTests.swift",
    "macos-native/Tests/VEXPrivilegedHelperTests/VEXPrivilegedHelperCoreTests.swift",
    ".github/workflows/native-reliability-ci.yml",
    ".github/workflows/native-macos-release.yml",
    "tests/client-ci-contract.mjs",
    "scripts/verify_macos_contract_transaction.py",
]
TESTS = [
    "testOwnerAuthenticationSessionFlowIsDeclaredInContract",
    "testInstallerReferencesPackagedSwiftHelperBinaryAndProgramArguments",
    "testSwiftTunnelUsesQuickScriptAndRollsBackAfterPFEnableFailure",
    "testPartialUpFailurePreservesRecoveryArtifactsUntilTunnelCleanupSucceeds",
]
EVENTS = []
OUTPUT = None


def command(args, cwd):
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True, check=False)
    event = dict(command=args, cwd=str(cwd), stdout=result.stdout,
                 stderr=result.stderr, exit_status=result.returncode)
    EVENTS.append(event)
    print(json.dumps(dict(command=args, exit_status=result.returncode)), flush=True)
    return event


def require(event):
    if event["exit_status"]:
        raise RuntimeError("command failed: " + json.dumps(event))


def snapshot(repo, revision, destination):
    result = subprocess.run(["git", "archive", "--format=tar", revision],
                            cwd=repo, capture_output=True, check=True)
    destination.mkdir()
    with tarfile.open(fileobj=io.BytesIO(result.stdout)) as archive:
        for member in archive.getmembers():
            path = Path(member.name)
            if path.is_absolute() or ".." in path.parts:
                raise ValueError("unsafe archive member")
            if member.issym() or member.islnk():
                link = Path(member.linkname)
                if link.is_absolute() or ".." in link.parts:
                    raise ValueError("unsafe archive link")
            if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                raise ValueError("special archive member rejected")
        archive.extractall(destination)


def hashes(tree):
    return {name: hashlib.sha256((tree / name).read_bytes()).hexdigest()
            if (tree / name).is_file() else None for name in FILES}


def rollback_script(tree):
    contents = {name: dict(data=base64.b64encode((tree / name).read_bytes()).decode(),
                           mode=(tree / name).stat().st_mode & 0o777)
                if (tree / name).is_file() else None for name in FILES}
    payload = json.dumps(contents, sort_keys=True)
    return """#!/bin/sh
set -eu
[ "$#" -eq 1 ] || { echo "usage: ROLLBACK.sh disposable-target-copy" >&2; exit 2; }
python3 - "$1" <<'PY'
import base64,json,os
from pathlib import Path
target=Path(os.path.abspath(os.path.expanduser(os.sys.argv[1])))
if not target.is_dir() or target.is_symlink():
    raise SystemExit("target must be an existing non-symlink disposable copy")
if (target/'.git').exists():
    raise SystemExit("refusing a Git checkout; use a disposable copy")
contents=json.loads(%r)
for name,value in contents.items():
    path=target/name
    if path.is_symlink() or any(p.is_symlink() for p in path.parents):
        raise SystemExit("symlink target rejected")
    if value is None:
        path.unlink(missing_ok=True)
    else:
        path.parent.mkdir(parents=True,exist_ok=True)
        path.write_bytes(base64.b64decode(value['data'],validate=True))
        path.chmod(value['mode'])
print("pristine bytes restored")
PY
""" % payload


def main():
    global OUTPUT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--output", required=True)
    options = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", options.base):
        parser.error("--base must be an exact Git commit")
    repo = Path(__file__).resolve().parents[1]
    output = Path(options.output).resolve()
    if output == repo or repo in output.parents:
        parser.error("--output must be outside the repository")
    if output.exists():
        parser.error("--output must be a fresh disposable directory")
    output.mkdir(parents=True)
    OUTPUT = output
    require(command(["xcrun", "--find", "xctest"], repo))
    require(command(["git", "diff", "--exit-code"], repo))
    head_event = command(["git", "rev-parse", "HEAD"], repo)
    require(head_event)
    head = head_event["stdout"].strip()
    patch_event = command(["git", "diff", "--binary", options.base, head, "--", *FILES], repo)
    require(patch_event)
    (output / "DIFF_FILE.patch").write_text(patch_event["stdout"])
    trees = {role: output / (role + "_TREE") for role in ("BASELINE", "MODIFIED", "ROLLBACK")}
    snapshot(repo, options.base, trees["BASELINE"])
    snapshot(repo, head, trees["MODIFIED"])
    snapshot(repo, head, trees["ROLLBACK"])
    original = hashes(trees["BASELINE"])
    modified = hashes(trees["MODIFIED"])
    rollback = output / "ROLLBACK.sh"
    rollback.write_text(rollback_script(trees["BASELINE"]))
    rollback.chmod(0o755)
    # Validate reconstruction with the actual native patch tool, not a hash-only claim.
    proof = output / "PATCH_TREE"
    snapshot(repo, options.base, proof)
    require(command(["git", "apply", str(output / "DIFF_FILE.patch")], proof))
    if hashes(proof) != modified:
        raise RuntimeError("patch reconstruction does not match modified sources")
    require(command([str(rollback), str(trees["ROLLBACK"])], output))
    if hashes(trees["ROLLBACK"]) != original:
        raise RuntimeError("rollback bytes differ from baseline")
    results = {}
    for role, tree in trees.items():
        event = command(["swift", "test", "--filter", "|".join(TESTS)], tree / "macos-native")
        results[role] = event
        text = event["stdout"] + event["stderr"]
        if not re.search(r"Executed 4 tests?, with \d+ failures?", text):
            raise RuntimeError(role + ": XCTest did not execute the four requested tests")
        for name in TESTS:
            if not re.search(r"Test Case '.+" + re.escape(name) + r".+' (?:passed|failed)", text):
                raise RuntimeError(role + ": missing XCTest event " + name)
    if results["MODIFIED"]["exit_status"] != 0:
        raise RuntimeError("modified XCTest failed")
    if results["BASELINE"]["exit_status"] != results["ROLLBACK"]["exit_status"]:
        raise RuntimeError("rollback behavior differs from baseline")
    # Retain each individual outcome as well as total exit code; reject partial runs.
    def outcomes(event):
        return {name: re.findall(r"Test Case '.+" + re.escape(name) +
                                r".+' (passed|failed)", event["stdout"] + event["stderr"])
                for name in TESTS}
    if outcomes(results["BASELINE"]) != outcomes(results["ROLLBACK"]):
        raise RuntimeError("rollback XCTest outcomes differ from baseline")
    if hashes(trees["MODIFIED"]) != modified:
        raise RuntimeError("modified sources changed during verification")
    shutil.copyfile(trees["MODIFIED"] / FILES[0], output / "MODIFIED_FILE.swift")
    summary = dict(base=options.base, head=head, original_hashes=original,
                   modified_hashes=modified, rollback_hashes=hashes(trees["ROLLBACK"]),
                   exits={role: event["exit_status"] for role, event in results.items()},
                   outcomes={role: outcomes(event) for role, event in results.items()},
                   rollback_hashes_match=True, patch_reconstructs=True,
                   production_mutation=False, live_vpn_commands=False)
    (output / "RESULT.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary), flush=True)


if __name__ == "__main__":
    try:
        main()
    finally:
        # Preserve literal commands/stdout/stderr/status even on a failed attempt.
        import sys
        if OUTPUT is not None:
            output = OUTPUT
            if output.is_dir():
                (output / "COMMAND_EVENTS.json").write_text(json.dumps(EVENTS, indent=2) + "\n")
                (output / "VERIFICATION.txt").write_text(
                    "Native SwiftPM/XCTest transaction; all paths are disposable copies.\n" +
                    "\n".join(json.dumps(event, indent=2) for event in EVENTS) + "\n" +
                    ((output / "RESULT.json").read_text() if (output / "RESULT.json").exists()
                     else "Acceptance not achieved; see observed command events.\n"))
