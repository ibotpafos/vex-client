import fs from 'node:fs';

const root = new URL('../', import.meta.url);
const versionsPath = new URL('../versions.json', import.meta.url);
const packageJsonPath = new URL('../package.json', import.meta.url);
const packageLockPath = new URL('../package-lock.json', import.meta.url);
const appJsonPath = new URL('../app.json', import.meta.url);
const tauriConfigPath = new URL('../src-tauri/tauri.conf.json', import.meta.url);
const androidGradlePath = new URL('../android/app/build.gradle', import.meta.url);
const iosInfoPlistPath = new URL('../ios/VEX/Info.plist', import.meta.url);
const iosProjectPath = new URL('../ios/VEX.xcodeproj/project.pbxproj', import.meta.url);

const versions = readJson(versionsPath);

const mobileVersion = String(versions.android.version);
const mobileBuild = Number(versions.android.build);
const desktopVersion = String(versions.desktop.version);
const iosVersion = String(versions.ios.version);
const iosBuild = String(versions.ios.build);

if (!Number.isInteger(mobileBuild) || mobileBuild <= 0) {
  throw new Error(`Invalid Android build in versions.json: ${versions.android.build}`);
}

const androidVersionCode = buildAndroidVersionCode(mobileVersion, mobileBuild);

const packageJson = readJson(packageJsonPath);
packageJson.version = mobileVersion;
writeJson(packageJsonPath, packageJson);

const packageLock = readJson(packageLockPath);
packageLock.version = mobileVersion;
if (packageLock.packages?.['']) {
  packageLock.packages[''].version = mobileVersion;
}
writeJson(packageLockPath, packageLock);

const appJson = readJson(appJsonPath);
appJson.expo.version = mobileVersion;
appJson.expo.android = appJson.expo.android || {};
appJson.expo.android.versionCode = androidVersionCode;
writeJson(appJsonPath, appJson);

const tauriConfig = readJson(tauriConfigPath);
tauriConfig.version = desktopVersion;
writeJson(tauriConfigPath, tauriConfig);

let androidGradle = fs.readFileSync(androidGradlePath, 'utf8');
androidGradle = replaceFirst(androidGradle, /versionCode\s+\d+/, `versionCode ${androidVersionCode}`);
androidGradle = replaceFirst(androidGradle, /versionName\s+"[^"]+"/, `versionName "${mobileVersion}"`);
androidGradle = replaceFirst(androidGradle, /vexRuntimeVersion:\s*vexBuildValue\('VEX_RUNTIME_VERSION',\s*"[^"]+"\)/, `vexRuntimeVersion: vexBuildValue('VEX_RUNTIME_VERSION', "${mobileVersion}")`);
androidGradle = replaceAllRequired(androidGradle, /vexBuildValue\('VEX_RUNTIME_VERSION',\s*'[^']+'\)/g, `vexBuildValue('VEX_RUNTIME_VERSION', '${mobileVersion}')`);
fs.writeFileSync(androidGradlePath, androidGradle);

let iosInfoPlist = fs.readFileSync(iosInfoPlistPath, 'utf8');
iosInfoPlist = replaceFirst(
  iosInfoPlist,
  /<key>CFBundleShortVersionString<\/key>\s*<string>[^<]+<\/string>/,
  `<key>CFBundleShortVersionString</key>\n    <string>${iosVersion}</string>`,
);
iosInfoPlist = replaceFirst(
  iosInfoPlist,
  /<key>CFBundleVersion<\/key>\s*<string>[^<]+<\/string>/,
  `<key>CFBundleVersion</key>\n    <string>${iosBuild}</string>`,
);
fs.writeFileSync(iosInfoPlistPath, iosInfoPlist);

let iosProject = fs.readFileSync(iosProjectPath, 'utf8');
iosProject = iosProject.replaceAll(/CURRENT_PROJECT_VERSION = [^;]+;/g, `CURRENT_PROJECT_VERSION = ${iosBuild};`);
iosProject = iosProject.replaceAll(/MARKETING_VERSION = [^;]+;/g, `MARKETING_VERSION = ${iosVersion};`);
fs.writeFileSync(iosProjectPath, iosProject);

console.log(
  JSON.stringify(
    {
      mobileVersion,
      mobileBuild,
      androidVersionCode,
      desktopVersion,
      iosVersion,
      iosBuild,
      cwd: fileUrlPath(root),
    },
    null,
    2,
  ),
);

function buildAndroidVersionCode(version, build) {
  const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(version);
  if (!match) {
    throw new Error(`Unsupported Android version format: ${version}`);
  }
  const [, majorText, minorText, patchText] = match;
  const major = Number(majorText);
  const minor = Number(minorText);
  const patch = Number(patchText);
  return major * 1_000_000 + minor * 10_000 + patch * 100 + build;
}

function replaceFirst(input, pattern, replacement) {
  if (!pattern.test(input)) {
    throw new Error(`Pattern not found: ${pattern}`);
  }
  pattern.lastIndex = 0;
  return input.replace(pattern, replacement);
}

function replaceAllRequired(input, pattern, replacement) {
  if (!pattern.test(input)) {
    throw new Error(`Pattern not found: ${pattern}`);
  }
  pattern.lastIndex = 0;
  return input.replace(pattern, replacement);
}

function readJson(path) {
  return JSON.parse(fs.readFileSync(path, 'utf8'));
}

function writeJson(path, value) {
  fs.writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}

function fileUrlPath(url) {
  return decodeURIComponent(url.pathname);
}
