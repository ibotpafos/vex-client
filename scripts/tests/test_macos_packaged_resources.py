"""Probe relocated and damaged disposable bundles, without starting GUI/helper."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="vex-bundle-regression-") as directory:
    app = Path(directory) / "Moved VEX.app"
    subprocess.run(["ditto", str(source), str(app)], check=True)
    executable = app / "Contents/MacOS/VEXNativeMac"
    def probe(expected):
        result = subprocess.run([str(executable), "--resource-bundle-probe"], capture_output=True, text=True, timeout=15)
        assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
        return result
    assert "country_resources=ok" in probe(0).stdout
    update = Path(directory) / "update.json"
    update.write_text('{"updateAvailable":false}')
    result = subprocess.run([str(executable), "--update-response-probe", str(update)], capture_output=True, text=True, timeout=15)
    assert result.returncode == 0 and "update_response=valid" in result.stdout, result.stderr
    update.write_text('{"updateAvailable":true}')
    result = subprocess.run([str(executable), "--update-response-probe", str(update)], capture_output=True, text=True, timeout=15)
    assert result.returncode == 1, (result.returncode, result.stderr)
    print("PASS: release binary accepts sparse no-update responses and rejects incomplete available-update metadata")
    bundle = app / "Contents/Resources/VEXNativeMac_VEXNativeMac.bundle"
    # Absence must not fall back to resources in the developer's existing cache.
    shutil.rmtree(bundle)
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True, capture_output=True)
    assert "country_resources=missing" in probe(1).stdout
    print("PASS: relocated app loads bundled resources; missing bundle exits cleanly without cache fallback or crash")
