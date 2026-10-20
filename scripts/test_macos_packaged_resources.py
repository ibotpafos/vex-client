#!/usr/bin/env python3
"""Exercise production country drawing in relocated app bundles, without VEX startup."""

from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / "macos-native"
BUNDLE_NAME = "VEXNativeMac_VEXNativeMac.bundle"


@unittest.skipUnless(sys.platform == "darwin", "Requires macOS Foundation and SwiftUI")
class PackagedResourcesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.storage = tempfile.TemporaryDirectory(prefix="vex-packaged-resources-")
        cls.addClassCleanup(cls.storage.cleanup)
        cls.root = Path(cls.storage.name)
        cls.binary = cls.root / "ResourceBundleProbe"
        subprocess.run([
            "swiftc", "-parse-as-library", "-swift-version", "5",
            str(NATIVE / "Sources/VEXNativeMac/Support/VEXAppResources.swift"),
            str(NATIVE / "Sources/VEXNativeMac/Views/CountrySilhouette.swift"),
            str(NATIVE / "Tests/ResourceBundleHarness/ResourceBundleProbe.swift"),
            "-o", str(cls.binary),
        ], check=True, timeout=180)

    def setUp(self):
        self.case = self.root / self.id().rsplit(".", 1)[-1]
        self.case.mkdir()

    def app(self, name="VEX Native.app"):
        app = self.case / name
        contents = app / "Contents"
        executable = contents / "MacOS/ResourceBundleProbe"
        executable.parent.mkdir(parents=True)
        shutil.copy2(self.binary, executable)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "app.vex.tests.resources",
            "CFBundleExecutable": executable.name,
            "CFBundlePackageType": "APPL",
        }))
        return app, executable

    def resources(self, parent):
        bundle = parent / BUNDLE_NAME
        bundle.mkdir(parents=True)
        shutil.copy2(NATIVE / "Sources/VEXNativeMac/Resources/country-silhouettes.json", bundle)
        return bundle

    def probe(self, executable, countries=True):
        result = subprocess.run(
            [str(executable), "countries" if countries else "empty"],
            cwd=self.case, capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.strip(), "countries loaded" if countries else "empty shapes")

    def test_packaged_contents_resources(self):
        app, executable = self.app()
        self.resources(app / "Contents/Resources")
        self.probe(executable)

    def test_renamed_and_moved_app_without_build_directory(self):
        app, _ = self.app()
        self.resources(app / "Contents/Resources")
        destination = self.case / "Applications с пробелами/Другой VEX.app"
        destination.parent.mkdir()
        shutil.move(app, destination)
        self.probe(destination / "Contents/MacOS/ResourceBundleProbe")

    def test_swiftpm_executable_sibling_bundle(self):
        executable = self.case / "ResourceBundleProbe"
        shutil.copy2(self.binary, executable)
        self.resources(self.case)
        self.probe(executable)

    def test_legacy_app_root_bundle(self):
        app, executable = self.app()
        self.resources(app)
        self.probe(executable)

    def test_missing_bundle_draws_empty_shapes(self):
        _, executable = self.app()
        self.probe(executable, countries=False)

    def test_missing_catalog_draws_empty_shapes(self):
        app, executable = self.app()
        self.resources(app / "Contents/Resources").joinpath("country-silhouettes.json").unlink()
        self.probe(executable, countries=False)

    def test_invalid_catalog_draws_empty_shapes(self):
        app, executable = self.app()
        self.resources(app / "Contents/Resources").joinpath("country-silhouettes.json").write_text("{broken json")
        self.probe(executable, countries=False)


if __name__ == "__main__":
    unittest.main(verbosity=2)
