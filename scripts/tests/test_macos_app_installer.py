import importlib.util
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile

SPEC = importlib.util.spec_from_file_location("app_installer", Path(__file__).resolve().parents[1] / "build_native_macos_app_installer.py")
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


class ArchiveTests(unittest.TestCase):
    def test_rejects_paths_that_can_write_outside_payload(self):
        for name in ("../outside", "/Applications/outside", "VEXNativeMac.app/../outside", "VEXNativeMac.app\\outside"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temp:
                path = Path(temp) / "bad.zip"
                with zipfile.ZipFile(path, "w") as z:
                    z.writestr(name, b"bad")
                with self.assertRaises(ValueError):
                    installer.inspect_archive(path)

    def test_rejects_escaping_framework_link(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "bad.zip"
            entry = zipfile.ZipInfo("VEXNativeMac.app/Contents/escape")
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            with zipfile.ZipFile(path, "w") as z:
                z.writestr(entry, "../../../../Applications")
            with self.assertRaisesRegex(ValueError, "escapes"):
                installer.inspect_archive(path)

    def test_user_domain_and_no_system_installation(self):
        import xml.etree.ElementTree as ET
        root = ET.fromstring(installer.distribution("15.0", "0.1.90", 120))
        self.assertEqual(root.find("domains").attrib, {"enable_anywhere": "false", "enable_currentUserHome": "true", "enable_localSystem": "false"})
        self.assertEqual(root.find("pkg-ref").attrib["onConclusion"], "none")
        self.assertIsNone(root.find("script"))


@unittest.skipUnless(sys.platform == "darwin", "Real codesign/xattr fixtures require macOS")
class InstallScriptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.storage = tempfile.TemporaryDirectory(prefix="vex-installer-tests-")
        cls.root = Path(cls.storage.name).resolve()
        cls.template = cls.root / "template.app"
        binary = cls.template / "Contents/MacOS/VEXNativeMac"
        binary.parent.mkdir(parents=True)
        shutil.copyfile("/usr/bin/true", binary)
        binary.chmod(0o755)
        cls.info = {"CFBundleIdentifier": "app.vex.vpn.native", "CFBundleExecutable": "VEXNativeMac",
                    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.1.90", "CFBundleVersion": "120"}
        (cls.template / "Contents/Info.plist").write_bytes(plistlib.dumps(cls.info))
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(cls.template)], check=True, capture_output=True)
        archs = subprocess.check_output(["/usr/bin/lipo", "-archs", str(binary)], text=True).split()
        hashes = []
        for arch in archs:
            r = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", "--arch", arch, str(cls.template)], check=True, capture_output=True, text=True)
            hashes.append(re.search(r"^CDHash=([a-f0-9]+)$", r.stderr, re.M)[1])
        cls.requirement = 'identifier "app.vex.vpn.native" and (' + " or ".join('cdhash H"' + h + '"' for h in hashes) + ")"
        cls.scripts = cls.root / "scripts"
        installer.render_scripts(cls.scripts, "0.1.90", 120, cls.requirement)

    @classmethod
    def tearDownClass(cls):
        cls.storage.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=self.root)
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.app = self.home / "Applications/VEX Native.app"
        self.app.parent.mkdir()
        shutil.copytree(self.template, self.app)
        self.mark(self.app)

    @staticmethod
    def mark(path):
        subprocess.run(["/usr/bin/xattr", "-w", "com.apple.quarantine", "0083;12345678;VEXTests;", str(path)], check=True)

    @staticmethod
    def marked(path):
        return subprocess.run(["/usr/bin/xattr", "-p", "com.apple.quarantine", str(path)], capture_output=True).returncode == 0

    def execute(self, name, extra=None):
        env = dict(os.environ, HOME=str(self.home))
        env.pop("BASH_ENV", None)
        command = ["/bin/bash", str(self.scripts / name)] if extra is None else ["/bin/bash", "-c", 'source "$1"; check_existing_version', "test", str(self.scripts / "common.sh")]
        return subprocess.run(command, env=env, capture_output=True, text=True)

    def test_real_signed_fixture_is_approved_only_inside_app(self):
        unrelated = self.home / "other.txt"
        unrelated.write_text("keep")
        self.mark(unrelated)
        result = self.execute("postinstall")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.marked(self.app))
        self.assertTrue(self.marked(unrelated))
        self.assertEqual(unrelated.read_text(), "keep")

    def test_modified_executable_is_not_approved(self):
        with (self.app / "Contents/MacOS/VEXNativeMac").open("ab") as stream:
            stream.write(b"tampered")
        self.assertNotEqual(self.execute("postinstall").returncode, 0)
        self.assertTrue(self.marked(self.app))

    def test_different_valid_signature_cannot_replace_pinned_content(self):
        (self.app / "Contents/Resources").mkdir()
        (self.app / "Contents/Resources/extra.txt").write_text("different signed payload")
        result = subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(self.app)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(self.execute("postinstall").returncode, 0)
        self.assertTrue(self.marked(self.app))

    def test_application_directory_link_is_rejected_before_changes(self):
        original = self.home / "original"
        self.app.parent.rename(original)
        self.app.parent.symlink_to(original, target_is_directory=True)
        self.assertNotEqual(self.execute("postinstall").returncode, 0)
        self.assertTrue(self.marked(original / "VEX Native.app"))

    def test_marketing_upgrade_accepts_old_manual_build_number(self):
        info = dict(self.info, CFBundleShortVersionString="0.1.87", CFBundleVersion="132")
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        result = self.execute("common.sh", extra=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_downgrade_is_rejected_without_touching_old_copy(self):
        for version, build in (("0.1.91", "1"), ("0.1.90", "121")):
            with self.subTest(version=version):
                (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(self.info, CFBundleShortVersionString=version, CFBundleVersion=build)))
                self.assertNotEqual(self.execute("preinstall").returncode, 0)
                self.assertTrue(self.marked(self.app))


if __name__ == "__main__":
    unittest.main()
