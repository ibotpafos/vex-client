"""Exercise build functions with stale output and a failing Swift process."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class BuildFailureTests(unittest.TestCase):
    def test_failed_build_never_returns_stale_product(self):
        for filename, function, product in [
            ("build_native_macos_app.sh", "build_app_arch", "VEXNativeMac"),
            ("build_swift_macos_helper.sh", "build_arch", "VEXPrivilegedHelper"),
        ]:
            with self.subTest(script=filename), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                output = root / "arm64/arm64-apple-macosx/release" / product
                output.parent.mkdir(parents=True)
                output.write_text("#!/bin/sh\nexit 0\n")
                output.chmod(0o755)
                fake = root / "swift"
                fake.write_text("#!/bin/sh\nexit 42\n")
                fake.chmod(0o755)
                source = (ROOT / "scripts" / filename).read_text()
                body = re.search(rf"{function}\(\) \{{.*?^\}}", source, re.S | re.M).group()
                body = body.replace("/usr/bin/swift", '"$FAKE_SWIFT"')
                script = 'set -euo pipefail\nPACKAGE_DIR="$1"; APP_SCRATCH_ROOT="$1"; SCRATCH_ROOT="$1"; FAKE_SWIFT="$1/swift"\n'
                script += f'APP_NAME={product}; PRODUCT={product}\n' + body
                script += f'\nartifact="$({function} arm64)"\nprintf "PACKAGED:%s" "$artifact"\n'
                result = subprocess.run(["bash", "-c", script, "test", str(root)], text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("PACKAGED:", result.stdout)

if __name__ == "__main__":
    unittest.main()
