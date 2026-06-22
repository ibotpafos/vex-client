#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
VERSIONS_FILE = ROOT_DIR / "versions.json"

PLATFORM_VERSION_SOURCE = {
    "android": "android",
    "desktop-web": "desktop",
    "macos": "desktop",
    "linux": "desktop",
    "windows": "desktop",
}

ARTIFACT_TEMPLATES = {
    "android": {
        "apk": "Vex-Android-{version}.apk",
    },
    "desktop-web": {
        "bundle": "vex-desktop-web-{version}.zip",
    },
    "macos": {
        "dmg": "Vex-macOS-{version}.dmg",
        "updater": "Vex-macOS-{version}.app.tar.gz",
        "compat_zip": "Vex-macOS-{version}.zip",
    },
    "linux": {
        "appimage": "Vex-Linux-{version}.AppImage",
        "deb": "Vex-Linux-{version}.deb",
    },
    "windows": {
        "msi": "Vex-Windows-{version}.msi",
        "setup": "Vex-Windows-{version}-setup.exe",
        "updater": "Vex-Windows-{version}.msi.zip",
    },
}

SCOPE_ARTIFACTS = {
    "all": (
        ("macos", "dmg"),
        ("macos", "updater"),
        ("macos", "updater.sig"),
        ("macos", "compat_zip"),
        ("desktop-web", "bundle"),
        ("desktop-web", "bundle.sha256"),
        ("desktop-web", "bundle.sig"),
        ("linux", "appimage"),
        ("linux", "appimage.sha256"),
        ("linux", "appimage.sig"),
        ("linux", "deb"),
        ("android", "apk"),
        ("android", "apk.sha256"),
        ("android", "apk.sig"),
        ("windows", "msi"),
        ("windows", "setup"),
        ("windows", "updater"),
        ("windows", "updater.sha256"),
        ("windows", "updater.sig"),
    ),
    "macos": (
        ("macos", "dmg"),
        ("macos", "updater"),
        ("macos", "updater.sig"),
        ("macos", "compat_zip"),
    ),
    "linux": (
        ("linux", "appimage"),
        ("linux", "appimage.sha256"),
        ("linux", "appimage.sig"),
        ("linux", "deb"),
    ),
    "android": (
        ("android", "apk"),
        ("android", "apk.sha256"),
        ("android", "apk.sig"),
    ),
    "desktop-web": (
        ("desktop-web", "bundle"),
        ("desktop-web", "bundle.sha256"),
        ("desktop-web", "bundle.sig"),
    ),
    "windows": (
        ("windows", "msi"),
        ("windows", "setup"),
        ("windows", "updater"),
        ("windows", "updater.sha256"),
        ("windows", "updater.sig"),
    ),
}


def load_versions(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def platform_version(platform: str, versions: dict) -> str:
    source = PLATFORM_VERSION_SOURCE[platform]
    return str(versions[source]["version"])


def artifact_name(platform: str, kind: str, version: str) -> str:
    base_kind, _, suffix = kind.partition(".")
    template = ARTIFACT_TEMPLATES[platform][base_kind]
    name = template.format(version=version)
    return f"{name}.{suffix}" if suffix else name


def scoped_artifact_names(scope: str, versions: dict) -> list[str]:
    return [
        artifact_name(platform, kind, platform_version(platform, versions))
        for platform, kind in SCOPE_ARTIFACTS[scope]
    ]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Print canonical VEX release download names.")
    parser.add_argument("--versions-file", default=str(VERSIONS_FILE))

    subparsers = parser.add_subparsers(dest="command", required=True)

    version_parser = subparsers.add_parser("version")
    version_parser.add_argument("platform", choices=sorted(PLATFORM_VERSION_SOURCE))

    name_parser = subparsers.add_parser("name")
    name_parser.add_argument("platform", choices=sorted(ARTIFACT_TEMPLATES))
    name_parser.add_argument("kind")
    name_parser.add_argument("--version")

    url_parser = subparsers.add_parser("url")
    url_parser.add_argument("platform", choices=sorted(ARTIFACT_TEMPLATES))
    url_parser.add_argument("kind")
    url_parser.add_argument("--version")

    scope_parser = subparsers.add_parser("scope")
    scope_parser.add_argument("scope", choices=sorted(SCOPE_ARTIFACTS))

    return parser.parse_args()


def main() -> None:
    args = parse_args()
    versions = load_versions(Path(args.versions_file))

    if args.command == "version":
        print(platform_version(args.platform, versions))
        return

    if args.command in {"name", "url"}:
        version = args.version or platform_version(args.platform, versions)
        name = artifact_name(args.platform, args.kind, version)
        print(f"/downloads/{name}" if args.command == "url" else name)
        return

    for name in scoped_artifact_names(args.scope, versions):
        print(name)


if __name__ == "__main__":
    main()
