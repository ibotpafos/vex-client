const assert = require("node:assert/strict");
const { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } = require("node:fs");
const { createHash } = require("node:crypto");
const { tmpdir } = require("node:os");
const { join, resolve } = require("node:path");
const { spawnSync } = require("node:child_process");

const root = resolve(__dirname, "..");
const verifier = join(root, "scripts", "verify_android_observability.sh");
const work = mkdtempSync(join(tmpdir(), "vex-android-observability-"));

function runVerifier(args, env = {}) {
  const childEnv = { ...process.env, ...env };
  if (env.EXPO_PUBLIC_SENTRY_DSN === undefined) {
    delete childEnv.EXPO_PUBLIC_SENTRY_DSN;
  }
  return spawnSync("bash", [verifier, ...args], {
    cwd: root,
    env: childEnv,
    encoding: "utf8",
  });
}

function createApk(path, embeddedText) {
  const script = [
    "import sys, zipfile",
    "with zipfile.ZipFile(sys.argv[1], 'w') as apk:",
    "    apk.writestr('classes.dex', sys.argv[2].encode('utf-8'))",
    "    apk.writestr('AndroidManifest.xml', b'manifest')",
  ].join("\n");
  const result = spawnSync("python3", ["-c", script, path, embeddedText], {
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);
}

try {
  const missingEnv = runVerifier(["env"], {
    EXPO_PUBLIC_SENTRY_DSN: undefined,
  });
  assert.equal(missingEnv.status, 2);
  assert.match(missingEnv.stderr, /EXPO_PUBLIC_SENTRY_DSN is required/);

  const wrongHost = runVerifier(["env"], {
    EXPO_PUBLIC_SENTRY_DSN: "https://public-key@example.invalid/1",
  });
  assert.equal(wrongHost.status, 2);
  assert.match(wrongHost.stderr, /errors\.vexguard\.app/);
  assert.doesNotMatch(wrongHost.stderr, /public-key/);

  const validEnv = runVerifier(["env"], {
    EXPO_PUBLIC_SENTRY_DSN: "https://public-key@errors.vexguard.app/1",
  });
  assert.equal(validEnv.status, 0, validEnv.stderr);
  assert.match(validEnv.stdout, /ANDROID_BUGSINK_ENV=PASS/);
  assert.doesNotMatch(validEnv.stdout, /public-key/);

  const missingApk = join(work, "missing.apk");
  createApk(missingApk, "release=1.0.57");
  const missingArtifact = runVerifier(["apk", missingApk]);
  assert.equal(missingArtifact.status, 2);
  assert.match(missingArtifact.stderr, /missing Bugsink DSN/);

  const releaseEnv = {
    ...process.env,
    VEX_RELEASE_USE_LOCAL_CACHE: "0",
    ANDROID_RELEASE_VARIANT: "release",
    VEX_UPLOAD_STORE_FILE: "test-store.jks",
    VEX_UPLOAD_STORE_PASSWORD: "test-password",
    VEX_UPLOAD_KEY_ALIAS: "test-alias",
    VEX_UPLOAD_KEY_PASSWORD: "test-password",
  };
  delete releaseEnv.EXPO_PUBLIC_SENTRY_DSN;
  const releaseGate = spawnSync(
    "bash",
    [join(root, "scripts", "build_android_release.sh")],
    { cwd: root, env: releaseEnv, encoding: "utf8" },
  );
  assert.equal(releaseGate.status, 2);
  assert.match(releaseGate.stderr, /EXPO_PUBLIC_SENTRY_DSN is required/);

  const easEnv = {
    ...process.env,
    EAS_BUILD_PLATFORM: "android",
    VEX_BUILD_PROFILE: "production",
  };
  delete easEnv.EXPO_PUBLIC_SENTRY_DSN;
  const easGate = spawnSync("npm", ["run", "eas-build-pre-install", "--silent"], {
    cwd: root,
    env: easEnv,
    encoding: "utf8",
  });
  assert.equal(easGate.status, 2);
  assert.match(easGate.stderr, /EXPO_PUBLIC_SENTRY_DSN is required/);

  const easValid = spawnSync("npm", ["run", "eas-build-pre-install", "--silent"], {
    cwd: root,
    env: {
      ...easEnv,
      EXPO_PUBLIC_SENTRY_DSN: "https://public-key@errors.vexguard.app/1",
    },
    encoding: "utf8",
  });
  assert.equal(easValid.status, 0, easValid.stderr);

  const iosEnv = { ...easEnv, EAS_BUILD_PLATFORM: "ios" };
  delete iosEnv.EXPO_PUBLIC_SENTRY_DSN;
  const iosUnaffected = spawnSync(
    "npm",
    ["run", "eas-build-pre-install", "--silent"],
    { cwd: root, env: iosEnv, encoding: "utf8" },
  );
  assert.equal(iosUnaffected.status, 0, iosUnaffected.stderr);

  const fakeBin = join(work, "bin");
  const mkdir = spawnSync("mkdir", ["-p", fakeBin], { encoding: "utf8" });
  assert.equal(mkdir.status, 0, mkdir.stderr);
  const fakeGh = join(fakeBin, "gh");
  writeFileSync(
    fakeGh,
    [
      "#!/usr/bin/env bash",
      "set -euo pipefail",
      'dest=""',
      'while [[ "$#" -gt 0 ]]; do',
      '  if [[ "$1" == "--dir" ]]; then shift; dest="$1"; fi',
      "  shift",
      "done",
      'cp "$VEX_TEST_INPUT_APK" "$dest/input.apk"',
    ].join("\n"),
  );
  chmodSync(fakeGh, 0o755);
  const missingSha = createHash("sha256")
    .update(readFileSync(missingApk))
    .digest("hex");
  const signingGate = spawnSync(
    "bash",
    [
      join(root, "scripts", "sign_android_candidate_ci.sh"),
      missingSha,
      "test-input",
    ],
    {
      cwd: root,
      env: {
        ...process.env,
        PATH: `${fakeBin}:${process.env.PATH}`,
        GITHUB_REPOSITORY: "vex/test",
        VEX_TEST_INPUT_APK: missingApk,
      },
      encoding: "utf8",
    },
  );
  assert.equal(signingGate.status, 2);
  assert.match(signingGate.stderr, /missing Bugsink DSN/);

  const validApk = join(work, "valid.apk");
  createApk(
    validApk,
    "release=1.0.58|https://public-key@errors.vexguard.app/1|",
  );
  const validArtifact = runVerifier(["apk", validApk]);
  assert.equal(validArtifact.status, 0, validArtifact.stderr);
  assert.match(validArtifact.stdout, /ANDROID_BUGSINK_APK=PASS/);
  assert.doesNotMatch(validArtifact.stdout, /public-key/);

  console.log(
    "ANDROID_OBSERVABILITY_RELEASE_CONTRACT=PASS: env and APK gates reject missing Bugsink configuration",
  );
} finally {
  rmSync(work, { recursive: true, force: true });
}
