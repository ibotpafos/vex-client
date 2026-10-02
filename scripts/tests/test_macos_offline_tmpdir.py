#!/usr/bin/env python3
"""Exercise the real offline runner preamble, without compiling or launching VEX."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) == 2 else Path(__file__).resolve().parents[2]
    source = root / "scripts/test_native_macos_offline.sh"
    # Execute only setup, before mktemp/build/test commands. Production storage
    # must keep rejecting symlink ancestors; normalize the test root, not storage.
    preamble, separator, _ = source.read_text().partition('BUILD="$(mktemp')
    if not separator:
        raise RuntimeError("offline runner setup boundary changed")
    failures = 0
    with tempfile.TemporaryDirectory(prefix="vex-offline-root-") as temporary:
        base = Path(temporary).resolve()
        real = base / "physical temp with spaces"
        real.mkdir()
        link = base / "linked temp"
        link.symlink_to(real, target_is_directory=True)
        probe = base / "probe.sh"
        probe.write_text(preamble + '\nprintf "%s\\n" "$TMPDIR"\n')
        for label, path, expected_success in (
            ("physical", real, True),
            ("symlink", link, True),
            ("missing", base / "does-not-exist", False),
        ):
            env = dict(os.environ, TMPDIR=str(path))
            result = subprocess.run(
                ["bash", str(probe)], env=env, text=True, capture_output=True, timeout=10
            )
            passed = (
                result.returncode == 0 and result.stdout.strip() == str(real)
                if expected_success else result.returncode != 0
            )
            failures += not passed
            print(f"offline_tmpdir case={label} exit={result.returncode} pass={str(passed).lower()}")
    print(f"offline_tmpdir_matrix cases=3 failures={failures} live_network_commands=0")
    return int(failures != 0)


if __name__ == "__main__":
    raise SystemExit(main())
