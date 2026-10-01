const assert = require("node:assert/strict");
const { mkdtempSync, readFileSync, rmSync } = require("node:fs");
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

function createApk(path, embeddedText, javascriptText = embeddedText) {
  const script = [
    "import sys, zipfile",
    "with zipfile.ZipFile(sys.argv[1], 'w') as apk:",
    "    apk.writestr('classes.dex', sys.argv[2].encode('utf-8'))",
    "    apk.writestr('AndroidManifest.xml', b'manifest')",
    "    apk.writestr('assets/index.android.bundle', sys.argv[3].encode('utf-8'))",
  ].join("\n");
  const result = spawnSync("python3", ["-c", script, path, embeddedText, javascriptText], {
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
  const missingArtifact = runVerifier(["apk", missingApk], {
    EXPO_PUBLIC_SENTRY_DSN: "https://public-key@errors.vexguard.app/1",
  });
  assert.equal(missingArtifact.status, 2);
  assert.match(missingArtifact.stderr, /missing the approved Bugsink DSN/);

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

  const releaseWorkflow = readFileSync(
    join(root, ".github", "workflows", "android-sign-candidate.yml"),
    "utf8",
  );
  assert.match(
    releaseWorkflow,
    /EXPO_PUBLIC_SENTRY_DSN:\s*\$\{\{ secrets\.EXPO_PUBLIC_SENTRY_DSN \}\}/,
  );

  const validApk = join(work, "valid.apk");
  createApk(
    validApk,
    "release=1.0.59|https://public-key@errors.vexguard.app/1|",
  );
  const validArtifact = runVerifier(["apk", validApk], {
    EXPO_PUBLIC_SENTRY_DSN: "https://public-key@errors.vexguard.app/1",
  });
  assert.equal(validArtifact.status, 0, validArtifact.stderr);
  assert.match(validArtifact.stdout, /ANDROID_BUGSINK_APK=PASS/);
  assert.doesNotMatch(validArtifact.stdout, /public-key/);

  const approved = "https://public-key@errors.vexguard.app/1";
  for (const malformed of [
    "http://public-key@errors.vexguard.app/1",
    "https://public-key:secret@errors.vexguard.app/1",
    "https://public-key@errors.vexguard.app:bad/1",
    "https://public-key@errors.vexguard.app:443/1",
    "https://public-key@errors.vexguard.app/1?token=secret",
    "https://public-key@errors.vexguard.app/1#secret",
    "https://public-key@errors.vexguard.app/01",
    "https://public-key@errors.vexguard.app/0",
    "https://public-key@errors.vexguard.app/1/",
    "https://public-key@errors.vexguard.app/not-a-project",
    "https://public-key@errors.vexguard.app/1\nsecret",
  ]) {
    const result = runVerifier(["env"], { EXPO_PUBLIC_SENTRY_DSN: malformed });
    assert.equal(result.status, 2);
    assert.doesNotMatch(result.stdout + result.stderr, /public-key|secret|Traceback/);
  }
  for (const [name, native, javascript] of [
    ["native-only", approved, "unconfigured"],
    ["js-only", "unconfigured", approved],
    ["wrong-project", approved.replace("/1", "/2"), approved.replace("/1", "/2")],
    ["wrong-project-prefix", approved.replace("/1", "/12"), approved.replace("/1", "/12")],
    ["wrong-key", approved.replace("public-key", "other-key"), approved],
  ]) {
    const apk = join(work, name + ".apk");
    createApk(apk, native, javascript);
    const result = runVerifier(["apk", apk], { EXPO_PUBLIC_SENTRY_DSN: approved });
    assert.equal(result.status, 2, name);
    assert.doesNotMatch(result.stdout + result.stderr, /public-key|other-key/);
  }
  const noExpectedProject = runVerifier(["apk", validApk]);
  assert.equal(noExpectedProject.status, 2);
  const corrupt = runVerifier(["apk", verifier], { EXPO_PUBLIC_SENTRY_DSN: approved });
  assert.equal(corrupt.status, 2);
  assert.match(corrupt.stderr, /valid archive/);
  const absent = runVerifier(["apk", join(work, "absent.apk")], { EXPO_PUBLIC_SENTRY_DSN: approved });
  assert.equal(absent.status, 2);
  const unknown = runVerifier(["unknown"], { EXPO_PUBLIC_SENTRY_DSN: approved });
  assert.equal(unknown.status, 2);
  assert.match(unknown.stderr, /usage:/);
  assert.match(validArtifact.stdout, /native=present javascript=present/);
  const jsSdk = readFileSync(join(root, "src", "observability", "sentry.ts"), "utf8");
  assert.match(jsSdk, /sendDefaultPii: false/);
  assert.match(jsSdk, /enableAutoSessionTracking: false/);
  assert.match(jsSdk, /tracesSampleRate: 0/);
  const nativeSdk = readFileSync(join(root, "android", "app", "src", "main", "java", "com", "vexguard", "app", "MainApplication.kt"), "utf8");
  assert.match(nativeSdk, /options.isSendDefaultPii = false/);
  assert.match(nativeSdk, /options.isEnableAutoSessionTracking = false/);
  assert.match(nativeSdk, /options.tracesSampleRate = 0.0/);
  assert.match(releaseWorkflow, /EXPO_PUBLIC_SENTRY_ENVIRONMENT: production/);
  assert.match(releaseWorkflow, /EXPO_PUBLIC_SENTRY_RELEASE="vex-android@/);

  console.log(
    "ANDROID_OBSERVABILITY_RELEASE_CONTRACT=PASS: env and APK gates reject missing Bugsink configuration",
  );
} finally {
  rmSync(work, { recursive: true, force: true });
}
