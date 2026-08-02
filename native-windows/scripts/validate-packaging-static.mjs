#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptsDirectory = path.dirname(fileURLToPath(import.meta.url));
const windowsRoot = path.resolve(scriptsDirectory, "..");
const packagingDirectory = path.join(windowsRoot, "packaging");

const read = (file) => fs.readFileSync(file, "utf8");
const requireText = (text, expression, message) =>
  assert.match(text, expression, message);

const scriptPaths = [
  path.join(scriptsDirectory, "bootstrap-native-windows.ps1"),
  path.join(scriptsDirectory, "install-vpn-service.ps1"),
  path.join(scriptsDirectory, "uninstall-vpn-service.ps1"),
  path.join(packagingDirectory, "package-native-windows.ps1"),
  path.join(packagingDirectory, "publish-native-windows.ps1"),
];

for (const scriptPath of scriptPaths) {
  const source = read(scriptPath);
  assert.ok(!source.startsWith("\uFEFF"), `${scriptPath} must be UTF-8 without BOM`);
  assert.ok(!/^(<{7}|={7}|>{7})/m.test(source), `${scriptPath} has conflict markers`);
  assert.ok(source.includes("Set-StrictMode -Version Latest"), `${scriptPath} must use strict mode`);
}

const packageScript = read(path.join(packagingDirectory, "package-native-windows.ps1"));
assert.doesNotMatch(
  packageScript,
  /Refusing to emit a production artifact|MSIX-safe ProgramData\/IPC bootstrap is not implemented/,
  "production packaging must not contain the retired unconditional fail-closed gate",
);
assert.doesNotMatch(
  packageScript,
  /makepri(?:\.exe)?\s+(?:new|createconfig)/i,
  "packager must preserve compiled WinUI PRI files instead of generating duplicate entries",
);
requireText(packageScript, /Invoke-SignTool[\s\S]+Vex\.Windows\.App\.exe/, "client must be signed");
requireText(packageScript, /Invoke-SignTool[\s\S]+Vex\.Windows\.Service\.exe/, "service must be signed");
requireText(packageScript, /schema = 'vex\.windows-package-output\.v2'/, "v2 metadata required");
for (const metadataRequirement of [
  /install_entrypoint = 'elevated_bootstrap'/,
  /service_ownership = 'manual_sc_bootstrap'/,
  /raw_msix_provisions_service = \$false/,
  /raw_appinstaller_provisions_service = \$false/,
  /bootstrap_sha256 = ConvertTo-HexSha256/,
  /install_service_script_sha256 = ConvertTo-HexSha256/,
  /uninstall_service_script_sha256 = ConvertTo-HexSha256/,
]) {
  requireText(
    packageScript,
    metadataRequirement,
    `bootstrap metadata requirement missing: ${metadataRequirement}`,
  );
}

const publishScript = read(path.join(packagingDirectory, "publish-native-windows.ps1"));
assert.ok(
  fs.existsSync(
    path.join(packagingDirectory, "UpdateManifestSigner", "UpdateManifestSigner.csproj"),
  ),
  "cross-PowerShell update manifest signer is missing",
);
for (const publishRequirement of [
  /schema = 'vex\.windows-bootstrap-entry\.v1'/,
  /bootstrap_entry_signature_uri/,
  /package_metadata_sha256/,
  /install_service_script_sha256/,
  /uninstall_service_script_sha256/,
  /VEX_WINDOWS_MANIFEST_REVISION/,
  /manifest_revision = \$manifestRevision/,
  /required_version_floor = \$effectiveRequiredVersionFloor/,
  /VEX_WINDOWS_RELEASE_NOTES/,
  /changelog = \$releaseNotes/,
  /requiredArchitectures = @\('x64', 'arm64'\)/,
  /Incomplete Windows release set/,
  /Package identity differs between architectures/,
  /ConvertTo-Base64Signature/,
]) {
  requireText(
    publishScript,
    publishRequirement,
    `signed bootstrap publication requirement missing: ${publishRequirement}`,
  );
}

const installScript = read(path.join(scriptsDirectory, "install-vpn-service.ps1"));
for (const requirement of [
  /DataProtectionScope\]::LocalMachine/,
  /RandomNumberGenerator/,
  /SetAccessRuleProtection\(\$true, \$false\)/,
  /app-executable-sha256/,
  /service-executable-sha256/,
  /profile-signing-keys-sha256/,
  /WaitForStatus/,
]) {
  requireText(installScript, requirement, `installer requirement missing: ${requirement}`);
}

const uninstallScript = read(path.join(scriptsDirectory, "uninstall-vpn-service.ps1"));
for (const requirement of [
  /uninstall-runtime/,
  /function Remove-StagingDirectory/,
  /Start-Sleep -Milliseconds 250/,
  /Copy-Item[\s\S]+-LiteralPath \$vendorExecutable[\s\S]+-Destination \$stagedVendorExecutable/,
  /Copy-Item[\s\S]+-LiteralPath \$wintunLibrary[\s\S]+-Destination \$stagedWintunLibrary/,
  /Get-FileHash[\s\S]+stagedVendorExecutable/,
  /Get-Service[\s\S]+AmneziaWGTunnel\$vex/,
  /& \$stagedVendorExecutable \/uninstalltunnelservice vex/,
]) {
  requireText(
    uninstallScript,
    requirement,
    `uninstaller staging requirement missing: ${requirement}`,
  );
}

const bootstrapScript = read(path.join(scriptsDirectory, "bootstrap-native-windows.ps1"));
for (const action of ["Install", "Repair", "Verify", "Uninstall", "Rollback"]) {
  assert.ok(bootstrapScript.includes(`'${action}'`), `bootstrap action ${action} is missing`);
}
requireText(bootstrapScript, /Assert-Hash[\s\S]+package_sha256/, "MSIX hash must be checked");
requireText(bootstrapScript, /Add-AppxPackage/, "MSIX installation is missing");
requireText(bootstrapScript, /Remove-AppxPackage/, "MSIX removal is missing");
requireText(
  bootstrapScript,
  /\[switch\]\$RelaunchAfterInstall[\s\S]+shell:AppsFolder[\s\S]+VexWindowsApp/,
  "successful in-app updates must relaunch the packaged client",
);

const updateService = read(
  path.join(windowsRoot, "src", "Vex.Windows.App", "Services", "NativeUpdateService.cs"),
);
requireText(
  updateService,
  /RelaunchAfterInstall/,
  "the in-app updater must request a post-install relaunch",
);

const replacements = {
  "__PACKAGE_NAME__": "ORG.APP",
  "__PACKAGE_VERSION__": "1.2.3.4",
  "__PUBLISHER__": "CN=ORG",
  "__ARCHITECTURE__": "TARGET_ARCH",
  "__DISPLAY_NAME__": "APP",
  "__PUBLISHER_DISPLAY_NAME__": "ORG",
};
const render = (template, values) =>
  Object.entries(values).reduce(
    (result, [placeholder, value]) => result.replaceAll(placeholder, value),
    template,
  );

const manifestTemplate = read(path.join(packagingDirectory, "AppxManifest.xml.template"));
requireText(
  manifestTemplate,
  /<Resource Language="ru-ru"\s*\/>[\s\S]*<Resource Language="en-us"\s*\/>/,
  "packaged Windows resources must declare Russian and English",
);
for (const architecture of ["x64", "arm64"]) {
  const manifest = render(manifestTemplate, {
    ...replacements,
    "__ARCHITECTURE__": architecture,
  });
  assert.ok(!/__[_A-Z]+__/.test(manifest), `${architecture} manifest has placeholders`);
  assert.ok(
    manifest.includes(`ProcessorArchitecture="${architecture}"`),
    `${architecture} manifest architecture mismatch`,
  );
  assert.ok(
    !manifest.includes('Category="windows.service"'),
    "manual service ownership forbids an MSIX service extension",
  );
  assert.ok(
    !manifest.includes('Name="packagedServices"') &&
      !manifest.includes('Name="localSystemServices"'),
    "manual service ownership forbids packaged/localSystem service capabilities",
  );
  assert.ok(manifest.includes('Name="runFullTrust"'), "full-trust app capability missing");
}

const appInstallerTemplate = read(
  path.join(packagingDirectory, "AppInstaller.template.xml"),
);
assert.doesNotMatch(
  appInstallerTemplate,
  /AutomaticBackgroundTask|<OnLaunch\b/,
  "raw App Installer updates must not bypass verified service provisioning",
);
for (const architecture of ["x64", "arm64"]) {
  const output = render(appInstallerTemplate, {
    "__APPINSTALLER_VERSION__": "1.2.3.4",
    "__APPINSTALLER_URI__": `https://HOST/${architecture}/APP.appinstaller`,
    "__PACKAGE_NAME__": "ORG.APP",
    "__PUBLISHER__": "CN=ORG",
    "__PACKAGE_VERSION__": "1.2.3.4",
    "__ARCHITECTURE__": architecture,
    "__PACKAGE_URI__": `https://HOST/${architecture}/APP.msix`,
  });
  assert.ok(!/__[_A-Z]+__/.test(output), `${architecture} AppInstaller has placeholders`);
  assert.ok(output.includes(`ProcessorArchitecture="${architecture}"`));
}

const appRoot = path.join(windowsRoot, "src", "Vex.Windows.App");
const mainWindowCode = read(path.join(appRoot, "MainWindow.xaml.cs"));
assert.doesNotMatch(
  mainWindowCode,
  /args\.NewSize\.Width\s*\/\s*scale/,
  "WinUI SizeChanged reports device-independent pixels and must not be DPI-scaled twice",
);
requireText(mainWindowCode, /DefaultWidth = 920;/, "default window width must match the current parity canvas");
requireText(mainWindowCode, /DefaultHeight = 620;/, "default window height must fit the current parity canvas");
requireText(mainWindowCode, /AppWindow\.SetIcon\(iconPath\)/, "title bar must use the VEX icon");
const appProject = read(path.join(appRoot, "Vex.Windows.App.csproj"));
requireText(appProject, /<ApplicationIcon>[\s\S]*icon\.ico/, "native executable icon is missing");
const backgroundUpdater = read(
  path.join(appRoot, "Services", "NativeUpdateBackgroundHost.cs"),
);
const preferencesStore = read(
  path.join(appRoot, "Services", "NativeClientPreferencesStore.cs"),
);
const settingsPage = read(path.join(appRoot, "Views", "SettingsPage.xaml"));
const homePageCode = read(path.join(appRoot, "Views", "HomePage.xaml.cs"));
requireText(
  homePageCode,
  /UpdateService\.CurrentSnapshot/,
  "VPN connect must use the last verified update state without blocking on network I/O",
);
assert.doesNotMatch(
  homePageCode,
  /OnPowerButtonClick[\s\S]{0,900}await\s+_services\.UpdateService\.RefreshAsync/,
  "VPN connect must not wait up to the updater HTTP timeout before opening the tunnel",
);
for (const [source, requirement, message] of [
  [backgroundUpdater, /NativeUpdateCheckPolicy\.StartupDelay/, "startup update check missing"],
  [backgroundUpdater, /NativeUpdateCheckPolicy\.NextDelay/, "periodic update cadence missing"],
  [preferencesStore, /AutoUpdatesEnabled:\s*true/, "automatic updates must default on"],
  [settingsPage, /OnAutoUpdatesToggled/, "automatic update preference UI missing"],
]) {
  requireText(source, requirement, message);
}

const profileKeyring = JSON.parse(
  read(path.join(packagingDirectory, "profile-signing-keys.json")),
);
assert.equal(profileKeyring.schema, "vex.profile-signing-keyring.v1");
assert.ok(Array.isArray(profileKeyring.keys) && profileKeyring.keys.length > 0);
assert.ok(
  !/(private|secret|password|token)/i.test(JSON.stringify(profileKeyring)),
  "packaged profile keyring contains secret-looking fields",
);

const repositoryRoot = path.resolve(windowsRoot, "..");
const workflow = read(
  path.join(repositoryRoot, ".github", "workflows", "native-windows-ci.yml"),
);
for (const [requirement, message] of [
  [/manifest_revision:/, "release workflow must accept a monotonic manifest revision"],
  [/release_notes:/, "release workflow must require release notes"],
  [/rollout_percent:/, "release workflow must accept a staged rollout percentage"],
  [/VEX_WINDOWS_MANIFEST_REVISION:.*inputs\.manifest_revision/, "manifest revision is not passed to publisher"],
  [/VEX_WINDOWS_RELEASE_NOTES:.*inputs\.release_notes/, "release notes are not passed to publisher"],
  [/validate-packaging-static\.mjs/, "packaging static validator is not part of CI"],
  [/validate_native_windows_xaml\.mjs/, "XAML validator is not part of CI"],
]) {
  requireText(workflow, requirement, message);
}

const versions = JSON.parse(read(path.join(repositoryRoot, "versions.json")));
const windowsStable = versions.app?.compatibility_matrix?.find(
  (entry) => entry.platform === "windows" && entry.channel === "stable",
);
assert.ok(windowsStable, "stable Windows compatibility matrix entry is missing");
assert.ok(
  windowsStable.supportedApiClientVersions.includes("windows-native-1"),
  "stable backend compatibility must include windows-native-1",
);

console.log(
  `Native Windows packaging static/dry-run validation passed for ${scriptPaths.length} scripts, x64, and arm64.`,
);
