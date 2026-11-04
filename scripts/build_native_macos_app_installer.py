#!/usr/bin/env python3
"""Package an existing, pinned release. Never install it or execute app code."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "packaging/macos/app-installer"
RESERVE = 5 * 1024**3
MAX_UNPACKED = 256 * 1024**2
IDENTIFIER = "app.vex.vpn.native"
PKG_ID = IDENTIFIER + ".app-installer"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE, timeout=90).strip()


def hash_file(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def inspect_archive(archive):
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        require(0 < len(entries) <= 2048 and sum(x.file_size for x in entries) <= MAX_UNPACKED,
                "Archive exceeds the bounded application inventory")
        seen = set()
        for entry in entries:
            p = PurePosixPath(entry.filename)
            require(not p.is_absolute() and p.parts and p.parts[0] == "VEXNativeMac.app" and
                    ".." not in p.parts and "/./" not in entry.filename and "\\" not in entry.filename and "\x00" not in entry.filename and
                    entry.filename not in seen and not entry.flag_bits & 1,
                    "Archive has an unsafe or duplicate path")
            seen.add(entry.filename)
            kind = stat.S_IFMT(entry.external_attr >> 16)
            require(kind in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK), "Special archive file is forbidden")
            if kind == stat.S_IFLNK:
                require(entry.file_size <= 4096, "Oversized link")
                target = source.read(entry).decode("utf-8")
                resolved = list(p.parent.parts)
                for part in PurePosixPath(target).parts:
                    require(part != "/", "Absolute archive link")
                    if part == "..":
                        require(len(resolved) > 1, "Archive link escapes the app")
                        resolved.pop()
                    elif part != ".":
                        resolved.append(part)
        require(source.getinfo("VEXNativeMac.app/Contents/Info.plist").file_size <= 128 * 1024, "Oversized app metadata")
        info = plistlib.loads(source.read("VEXNativeMac.app/Contents/Info.plist"))
    return info, sum(x.file_size for x in entries)


def plan(request):
    require(set(request) == {"schema", "client_commit", "archive", "archive_sha256", "signer_sha256",
                             "version", "build", "output_directory"}, "Installer request fields changed")
    require(request["schema"] == "vex.macos-app-installer.v1", "Unknown installer schema")
    require(re.fullmatch(r"[a-f0-9]{40}", request["client_commit"]) and
            all(re.fullmatch(r"[a-f0-9]{64}", request[k]) for k in ("archive_sha256", "signer_sha256")),
            "Invalid source or public digest")
    require(re.fullmatch(r"(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})", request["version"]) and
            type(request["build"]) is int and 0 < request["build"] <= 2147483647, "Invalid release version/build")
    require(run("git", "-C", str(ROOT), "rev-parse", "HEAD") == request["client_commit"] and
            not run("git", "-C", str(ROOT), "status", "--porcelain"), "Builder requires its exact clean committed source")
    archive = Path(request["archive"])
    require(archive.is_absolute() and archive.resolve(strict=True) == archive and archive.is_file() and
            archive.stat().st_uid == os.getuid() and archive.stat().st_nlink == 1 and
            0 < archive.stat().st_size <= 64 * 1024**2, "Archive must be an owned bounded regular file")
    require(hash_file(archive) == request["archive_sha256"], "Published archive digest mismatch")
    output = Path(request["output_directory"])
    require(Path("/Volumes/D").is_mount() and output.is_absolute() and str(output).startswith("/Volumes/D/") and
            output.resolve() == output and not output.exists() and not output.is_symlink() and output.parent.is_dir() and
            output.parent.stat().st_uid == os.getuid() and not output.parent.stat().st_mode & 0o022,
            "Output must be a new directory under an owned physical D parent")
    info, size = inspect_archive(archive)
    require(info.get("CFBundleIdentifier") == IDENTIFIER and
            info.get("CFBundleShortVersionString") == request["version"] and
            info.get("CFBundleVersion") == str(request["build"]) and
            info.get("SUPublicEDKey") == (ROOT / "macos-native/sparkle-public-ed-key.txt").read_text().strip() and
            info.get("SUVerifyUpdateBeforeExtraction") is True, "App identity or Sparkle policy mismatch")
    minimum = info.get("LSMinimumSystemVersion", "")
    require(re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", minimum), "Missing minimum macOS version")
    free = shutil.disk_usage(output.parent).free
    # TODO(macos-installer): record downloaded-PKG GUI/first-launch acceptance
    # in a clean guest. This host's policy override and active VPN preclude it.
    return {"status": "ready" if free >= RESERVE + size * 3 else "blocked",
            "summary": "App-only GUI package; the package itself may need a one-time macOS security exception",
            "free_bytes": free, "required_free_bytes": RESERVE + size * 3, "unpacked_bytes": size,
            "minimum_macos": minimum, "archive_sha256": request["archive_sha256"],
            "first_open_exception_may_be_required": True, "universal_single_confirmation_verified": False,
            "application_installed": False, "vpn_mutations": 0}


def cdhash_requirement(app):
    hashes = []
    for arch in ("arm64", "x86_64"):
        details = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", "--arch", arch, str(app)],
                                 capture_output=True, text=True, check=True).stderr
        match = re.search(r"^CDHash=([a-f0-9]{40})$", details, re.M)
        require(match is not None, "Missing architecture code-directory hash")
        hashes.append(match[1])
    return 'identifier "' + IDENTIFIER + '" and (' + " or ".join('cdhash H"' + h + '"' for h in hashes) + ")"


def render_scripts(directory, version, build, requirement):
    directory.mkdir()
    for name in ("common.sh", "preinstall", "postinstall"):
        text = (RESOURCES / name).read_text()
        for token, value in {"@VERSION@": version, "@BUILD@": str(build), "@REQUIREMENT@": requirement}.items():
            text = text.replace(token, value)
        (directory / name).write_text(text)
        (directory / name).chmod(0o755)


def distribution(minimum, version, build):
    root = ET.Element("installer-gui-script", minSpecVersion="2")
    ET.SubElement(root, "title").text = "VEX VPN " + version
    ET.SubElement(root, "options", customize="never", hostArchitectures="arm64,x86_64", **{"require-scripts": "false"})
    ET.SubElement(root, "domains", enable_anywhere="false", enable_currentUserHome="true", enable_localSystem="false")
    for tag in ("welcome", "conclusion"):
        ET.SubElement(root, tag, file=tag + ".html", **{"mime-type": "text/html"})
    check = ET.SubElement(root, "volume-check")
    ET.SubElement(ET.SubElement(check, "allowed-os-versions"), "os-version", min=minimum)
    ET.SubElement(ET.SubElement(root, "choices-outline"), "line", choice="app")
    ET.SubElement(ET.SubElement(root, "choice", id="app", title="VEX VPN", visible="false"), "pkg-ref", id=PKG_ID)
    ET.SubElement(root, "pkg-ref", id=PKG_ID, version=f"{version}.{build}", onConclusion="none").text = "application.pkg"
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def build(request, evidence):
    require(evidence["status"] == "ready", "D free space is below the fixed 5-GiB reserve plus staging budget")
    require(sys.platform == "darwin" and os.environ.get("VEX_MACOS_INSTALLER_BUILD") == "1", "Local installer build gate is closed")
    output = Path(request["output_directory"])
    with tempfile.TemporaryDirectory(prefix=".vex-installer-", dir=output.parent) as temporary:
        work = Path(temporary)
        run("/usr/bin/ditto", "-x", "-k", request["archive"], str(work / "unpacked"))
        require(hash_file(Path(request["archive"])) == request["archive_sha256"], "Archive changed while staging")
        app = work / "unpacked/VEXNativeMac.app"
        for entry in app.rglob("*"):
            require(entry.resolve().is_relative_to(app.resolve()), "Extracted link escapes the application")
        run("/usr/bin/codesign", "--verify", "--all-architectures", "--deep", "--strict", str(app))
        run("/usr/bin/codesign", "-d", "--extract-certificates=" + str(work / "signer-"), str(app))
        require(hash_file(work / "signer-0") == request["signer_sha256"], "Application signer differs from the approved release pin")
        requirement = cdhash_requirement(app)
        root = work / "root/Applications"
        root.mkdir(parents=True)
        app.rename(root / "VEX Native.app")
        render_scripts(work / "scripts", request["version"], request["build"], requirement)
        component = [{"RootRelativeBundlePath": "Applications/VEX Native.app", "BundleIsRelocatable": False,
                      "BundleIsVersionChecked": False, "BundleHasStrictIdentifier": True, "BundleOverwriteAction": "upgrade"}]
        (work / "components.plist").write_bytes(plistlib.dumps(component))
        (work / "Distribution").write_bytes(distribution(evidence["minimum_macos"], request["version"], request["build"]))
        require(shutil.disk_usage(work).free >= RESERVE, "D reserve changed during staging")
        run("/usr/bin/pkgbuild", "--root", str(work / "root"), "--component-plist", str(work / "components.plist"),
            "--scripts", str(work / "scripts"), "--identifier", PKG_ID, "--version", f'{request["version"]}.{request["build"]}',
            "--install-location", "/", "--ownership", "recommended", str(work / "application.pkg"))
        require(shutil.disk_usage(work).free >= RESERVE, "D reserve changed during package preparation")
        name = f'VEXVPN-{request["version"]}-{request["build"]}-Installer.pkg'
        package = work / name
        run("/usr/bin/productbuild", "--distribution", str(work / "Distribution"), "--package-path", str(work),
            "--resources", str(RESOURCES), str(package))
        digest = hash_file(package)
        output.mkdir(mode=0o700)
        package = package.rename(output / name)
        (output / (name + ".sha256")).write_text(f"{digest}  {name}\n")
        receipt = {**evidence, "status": "built", "package": str(package), "package_sha256": digest,
                   "package_bytes": package.stat().st_size, "builder_commit": request["client_commit"],
                   "app_signer_sha256": request["signer_sha256"], "package_signed": False, "notarized": False,
                   "helper_installed": False, "application_executed": False}
        (output / "installer-manifest.json").write_text(json.dumps(receipt, indent=2) + "\n")
        return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("plan", "build"), default="plan")
    mode = parser.parse_args().mode
    request = json.loads(sys.stdin.buffer.read(32769))
    evidence = plan(request)
    print(json.dumps(build(request, evidence) if mode == "build" else evidence))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        raise SystemExit("Installer preparation failed: " + str(error)) from None
