#!/usr/bin/env python3
"""Fetch and verify the exact upstream Android library; never builds a Go runtime."""
import argparse
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import struct
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
VERSION = "v26.10.31"
ARCHIVE_SHA256 = "fb99f04acf379cc2957c1e1d0ce2b3c0005d3f49974a44c09a11242a0562c1ca"
AAR_SHA256 = "4c90532f61ff8363e7fcf52e064ff1aa66d065e06afbadc0ea4c6acf384c452f"
SOURCES_SHA256 = "14641c3977eee0e7ce9c2e1bf2d3399c0158f11a1a500b4ba9b9d5d651c1a9dc"
ARCHIVE_BYTES = 52277046
URL = f"https://github.com/XTLS/libXray/releases/download/{VERSION}/libxray-android.zip"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_elf(data, abi):
    expected_class, expected_machine = {"arm64-v8a": (2, 183), "armeabi-v7a": (1, 40)}[abi]
    if len(data) < 64 or data[:4] != b"\x7fELF" or data[4:6] != bytes((expected_class, 1)):
        raise ValueError("Native library ELF class/endianness differs from its ABI")
    if struct.unpack_from("<H", data, 18)[0] != expected_machine:
        raise ValueError("Native library machine differs from its ABI")
    is64 = expected_class == 2
    offset = struct.unpack_from("<Q" if is64 else "<I", data, 32 if is64 else 28)[0]
    entry_size = struct.unpack_from("<H", data, 54 if is64 else 42)[0]
    count = struct.unpack_from("<H", data, 56 if is64 else 44)[0]
    if not count or entry_size < (56 if is64 else 32) or offset + count * entry_size > len(data):
        raise ValueError("Native library program headers are invalid")
    alignments = [struct.unpack_from("<Q" if is64 else "<I", data, offset + i * entry_size + (48 if is64 else 28))[0]
                  for i in range(count) if struct.unpack_from("<I", data, offset + i * entry_size)[0] == 1]
    if not alignments or any(alignment < 16384 for alignment in alignments):
        raise ValueError("Native library is not aligned for 16 KiB Android pages")


def verify_aar(path):
    if digest(path) != AAR_SHA256:
        raise ValueError("libXray AAR digest differs from the reviewed artifact")
    with zipfile.ZipFile(path) as archive:
        for abi in ("arm64-v8a", "armeabi-v7a"):
            verify_elf(archive.read(f"jni/{abi}/libgojni.so"), abi)
        with zipfile.ZipFile(io.BytesIO(archive.read("classes.jar"))) as classes:
            for name in ("libXray/LibXray.class", "libXray/DialerController.class", "go/Seq.class"):
                if name not in classes.namelist():
                    raise ValueError("libXray generated Android API is missing")


def atomic_write(path, data):
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def bootstrap(verify_only=False):
    pin = json.loads((ROOT / "android/xray-android.lock.json").read_text())
    if (pin.get("version"), pin.get("archive_sha256"), pin.get("aar_sha256"), pin.get("url"), pin.get("archive_bytes")) != (
            VERSION, ARCHIVE_SHA256, AAR_SHA256, URL, ARCHIVE_BYTES):
        raise ValueError("Android Xray pin differs from the reviewed bootstrap contract")
    default = (Path("/Volumes/D/projects/.dev-cache/vex/releases/vex-client/xray")
               if Path("/Volumes/D/projects").is_dir() else Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "vex/xray")
    folder = Path(os.environ.get("VEX_XRAY_CACHE_ROOT", str(default))) / VERSION
    folder.mkdir(parents=True, exist_ok=True)
    with (folder / "bootstrap.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        artifact = folder / "libXray.aar"
        sources = folder / "libXray-sources.jar"
        if not artifact.exists() or not sources.exists():
            if verify_only:
                raise ValueError("Pinned Android Xray dependency has not been bootstrapped")
            archive = folder / "libxray-android.zip"
            if not archive.exists():
                fd, temporary = tempfile.mkstemp(prefix="download.", dir=folder)
                try:
                    request = urllib.request.Request(URL, headers={"User-Agent": "VEX-pinned-native-dependency"})
                    with urllib.request.urlopen(request, timeout=60) as response, os.fdopen(fd, "wb") as stream:
                        total = 0
                        while chunk := response.read(1024 * 1024):
                            total += len(chunk)
                            if total > ARCHIVE_BYTES:
                                raise ValueError("Xray download exceeds its pinned size")
                            stream.write(chunk)
                    if total != ARCHIVE_BYTES or digest(Path(temporary)) != ARCHIVE_SHA256:
                        raise ValueError("Xray download differs from its pinned size/digest")
                    os.replace(temporary, archive)
                finally:
                    Path(temporary).unlink(missing_ok=True)
            if archive.stat().st_size != ARCHIVE_BYTES or digest(archive) != ARCHIVE_SHA256:
                raise ValueError("Cached Xray archive differs from the pinned artifact")
            with zipfile.ZipFile(archive) as bundle:
                # Read fixed members, never extract paths supplied by an archive.
                atomic_write(artifact, bundle.read("libxray-android/libXray.aar"))
                atomic_write(sources, bundle.read("libxray-android/libXray-sources.jar"))
        verify_aar(artifact)
        if digest(sources) != SOURCES_SHA256:
            raise ValueError("libXray generated sources differ from the reviewed artifact")
        target = ROOT / "external/xray" / VERSION
        target.mkdir(parents=True, exist_ok=True)
        for name in ("libXray.aar", "libXray-sources.jar"):
            destination = target / name
            if destination.is_symlink() and destination.resolve() == folder / name:
                continue
            if destination.exists() or destination.is_symlink():
                raise ValueError("Refusing to replace an unrelated Xray dependency path")
            destination.symlink_to(folder / name)
        return target / "libXray.aar"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    print(bootstrap(args.verify_only))
