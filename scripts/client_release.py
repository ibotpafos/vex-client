#!/usr/bin/env python3
"""GitHub-native client release glue; builders/verifiers remain authoritative."""
import argparse
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPO = "ibotpafos/vex-client"
SIGNER = "cc569dfaa4c2c82379669b7c13606eb268cc3eba90a9c88e20a2d4500daf8470"


def sha(path):
    with path.open("rb") as stream:
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def android_version_code(version, counter):
    match = re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", version)
    if not match or type(counter) is not int or not 1 <= counter <= 99:
        raise ValueError("Android encoded build policy is violated")
    major, minor, patch = map(int, match.groups())
    if max(major, minor, patch) > 99:
        raise ValueError("Android encoded build policy is violated")
    return major * 1000000 + minor * 10000 + patch * 100 + counter


def plan(tag, dry_run, root=ROOT):
    versions = json.loads((root / "versions.json").read_text())
    match = re.fullmatch(r"(android|macos)-v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", tag)
    if not match:
        raise ValueError("Only android-vX.Y.Z / macos-vX.Y.Z releases are supported")
    platform = match[1]
    version = ".".join(match.groups()[1:])
    source = versions["android" if platform == "android" else "native_macos"]
    if not dry_run and source.get("release_status") == "published":
        raise ValueError("Version already marked published; prepare a new version/build before tagging")
    if source["version"] != version:
        raise ValueError("Tag/version source mismatch; commit release metadata first")
    if not source.get("release_notes", "").strip():
        raise ValueError("User-facing release notes are required")
    build = source["build"]
    if not isinstance(build, int) or isinstance(build, bool) or build <= 0:
        raise ValueError("Positive numeric build required")
    if platform == "android":
        build = android_version_code(version, build)
        app = json.loads((root / "app.json").read_text())["expo"]
        if (app["version"], app["android"]["versionCode"], app["android"]["package"]) != (version, build, "com.vexguard.app"):
            raise ValueError("Android source/versionCode/package mismatch")
    return {"schema_version": 1, "repository": REPO, "platform": platform, "version": version,
            "build": build, "tag": tag, "dry_run": dry_run,
            "min_supported_build": source.get("min_supported_build", 1),
            "core_version": source.get("core_version", "0.1.0"),
            "config_schema_version": source.get("config_schema_version", 1),
            "min_config_schema_version": source.get("min_config_schema_version", 1),
            "changelog": source["release_notes"]}


def verify_bundle(directory, expected):
    manifest = json.loads((directory / "vex-release.json").read_text())
    for key in ("schema_version", "repository", "platform", "version", "build", "tag", "source_commit", "dry_run", "min_supported_build", "core_version", "config_schema_version", "min_config_schema_version", "changelog"):
        if manifest.get(key) != expected.get(key):
            raise ValueError(f"Release manifest mismatch: {key}")
    if not re.fullmatch(r"[0-9a-f]{40}", manifest["source_commit"]):
        raise ValueError("An exact source commit is required")
    if not manifest.get("assets"):
        raise ValueError("Empty release is forbidden")
    seen = set()
    for asset in manifest["assets"]:
        name = asset["name"]
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name) or Path(name).name != name or name in seen or name in (".", "..", "vex-release.json"):
            raise ValueError("Unsafe/duplicate asset name")
        seen.add(name)
        path = directory / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size != asset["size"] or sha(path) != asset["sha256"]:
            raise ValueError(f"Artifact checksum/size mismatch: {name}")
        if asset["url"] != f"https://github.com/{REPO}/releases/download/{manifest['tag']}/{name}":
            raise ValueError("Only immutable exact repository release URLs are allowed")
    actual_files = {p.name for p in directory.iterdir() if p.is_file()}
    if actual_files != seen | {"vex-release.json"}:
        raise ValueError("Unverified extra assets are forbidden")
    return manifest


def bundle(directory, release):
    native = json.loads((directory / "release-manifest.json").read_text())
    if native["version"] != release["version"] or type(release["build"]) is not int:
        raise ValueError("Builder manifest does not match planned release")
    # The Android builder emits versions.json's counter, not the APK versionCode.
    # Website metadata deliberately uses the encoded code for upgrade ordering.
    if release["platform"] == "android":
        build = android_version_code(native["version"], native["build"])
    else:
        # The maintained Sparkle builder writes CFBundleVersion as a digit string.
        build = native["build"]
        if isinstance(build, str) and re.fullmatch(r"[0-9]+", build):
            build = int(build)
        if type(build) is not int or build <= 0:
            raise ValueError("Builder manifest does not match planned release")
    if build != release["build"]:
        raise ValueError("Builder manifest does not match planned release")
    if release["platform"] == "android":
        if native.get("variant") != "release":
            raise ValueError("Debug/local APK cannot be published")
        name = native["updater"]
        signature = (directory / (name + ".sig")).read_text()
        if f"certificate SHA-256 digest: {SIGNER}" not in signature:
            raise ValueError("Missing verified production signer report")
    else:
        name = native["archive"]
        if native.get("updateSignatureScheme") != "sparkle-ed25519" or not native.get("sparklePublicEDKey"):
            raise ValueError("Missing stable Sparkle signature contract")
        if native.get("selfSigned") is not True or any(native.get(k) is not False for k in ("notarized", "appleDeveloperSigned", "gatekeeperReady")):
            raise ValueError("Existing self-signed distribution policy must not be misrepresented")
    files = sorted(p for p in directory.iterdir() if p.is_file() and p.name != "vex-release.json")
    if any(p.is_symlink() for p in files):
        raise ValueError("Symlink assets are forbidden")
    release = {**release, "download_asset": name,
               "signer_sha256": SIGNER if release["platform"] == "android" else os.environ["VEX_SELF_SIGNED_APP_CERT_SHA256"],
               "assets": [{"name": p.name, "size": p.stat().st_size, "sha256": sha(p),
                           "url": f"https://github.com/{REPO}/releases/download/{release['tag']}/{p.name}"} for p in files]}
    (directory / "vex-release.json").write_text(json.dumps(release, ensure_ascii=False, indent=2) + "\n")
    verify_bundle(directory, release)
    return release


def publish(directory, release):
    if release["dry_run"] or os.environ.get("GITHUB_REF_TYPE") != "tag" or os.environ.get("GITHUB_REF_NAME") != release["tag"]:
        raise ValueError("Publishing requires an exact version-tag event, never a dry-run/branch")
    verify_bundle(directory, release)
    ref = json.loads(command("gh", "api", f"repos/{REPO}/git/ref/tags/{release['tag']}"))["object"]
    for _ in range(3):
        if ref["type"] != "tag":
            break
        ref = json.loads(command("gh", "api", f"repos/{REPO}/git/tags/{ref['sha']}"))["object"]
    if ref.get("type") != "commit" or ref.get("sha") != release["source_commit"]:
        raise ValueError("Tag moved or does not resolve to the verified source commit")
    # No clobber/delete/latest retag: refuse already-published versions.
    probe = subprocess.run(["gh", "release", "view", release["tag"], "--repo", REPO], capture_output=True)
    if probe.returncode == 0:
        raise ValueError("Release already exists; preserve it and use a new version/build")
    if b"release not found" not in probe.stderr.lower() and b"404" not in probe.stderr:
        raise ValueError("Release existence could not be established; fail closed")
    command("gh", "release", "create", release["tag"], "--repo", REPO, "--verify-tag", "--target", release["source_commit"],
            "--draft", "--latest=false", "--title", f"VEX {release['platform']} {release['version']}", "--notes", release["changelog"])
    command("gh", "release", "upload", release["tag"], "--repo", REPO, *[str(p) for p in sorted(directory.iterdir()) if p.is_file()])
    remote = json.loads(command("gh", "api", f"repos/{REPO}/releases/tags/{release['tag']}"))
    expected = {p.name: sha(p) for p in directory.iterdir() if p.is_file()}
    actual = {a["name"]: a for a in remote["assets"]}
    if set(actual) != set(expected) or any(actual[n].get("digest") != "sha256:" + digest for n, digest in expected.items()):
        raise ValueError("Uploaded asset digests mismatch; leave private draft, do not publish")
    command("gh", "release", "edit", release["tag"], "--repo", REPO, "--draft=false", "--latest=false")
    return {"status": "published", "tag": release["tag"], "website_delivery": "signed GitHub release.published webhook; separately verified receiver required"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["plan", "bundle", "verify", "publish"])
    parser.add_argument("--tag", default=os.environ.get("RELEASE_TAG", ""))
    parser.add_argument("--dry-run", choices=["true", "false"], default="true")
    parser.add_argument("--plan", type=Path, default=Path("release-plan.json"))
    parser.add_argument("--directory", type=Path)
    args = parser.parse_args()
    if args.action == "plan":
        release = plan(args.tag, args.dry_run == "true")
        release["source_commit"] = command("git", "rev-parse", "HEAD")
        command("git", "merge-base", "--is-ancestor", release["source_commit"], "origin/main")
        args.plan.write_text(json.dumps(release, ensure_ascii=False, indent=2) + "\n")
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                for key in ("platform", "version", "build", "tag", "source_commit", "dry_run"):
                    output.write(f"{key}={str(release[key]).lower() if isinstance(release[key], bool) else release[key]}\n")
    else:
        release = json.loads(args.plan.read_text())
        release = bundle(args.directory, release) if args.action == "bundle" else verify_bundle(args.directory, release) if args.action == "verify" else publish(args.directory, release)
    print(json.dumps({k: release[k] for k in ("status", "platform", "version", "build", "tag", "dry_run") if k in release}))


if __name__ == "__main__":
    main()
