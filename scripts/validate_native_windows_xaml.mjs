import fs from "node:fs";
import path from "node:path";

const appRoot = path.resolve(
  process.cwd(),
  "native-windows/src/Vex.Windows.App",
);

function walk(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const absolute = path.join(directory, entry.name);
    if (entry.isDirectory() && ["bin", "obj"].includes(entry.name)) {
      return [];
    }
    return entry.isDirectory() ? walk(absolute) : [absolute];
  });
}

const failures = [];
const serviceInstallerPath = path.resolve(
  process.cwd(),
  "native-windows/scripts/install-vpn-service.ps1",
);
const serviceInstallerSource = fs.readFileSync(serviceInstallerPath, "utf8");
for (const localizedAccountName of ["'SYSTEM'", "'BUILTIN\\Administrators'"]) {
  if (serviceInstallerSource.includes(localizedAccountName)) {
    failures.push(
      `${serviceInstallerPath}: ACLs must use well-known SIDs instead of localized account ${localizedAccountName}`,
    );
  }
}

const processAttestorPath = path.resolve(
  process.cwd(),
  "native-windows/src/Vex.Windows.Service/Security/ClientProcessAttestor.cs",
);
const processAttestorSource = fs.readFileSync(processAttestorPath, "utf8");
if (!/GetNamedPipeClientProcessId[\s\S]*OpenProcessToken/u.test(
  processAttestorSource,
)) {
  failures.push(
    `${processAttestorPath}: named-pipe owner attestation must read the kernel-reported client process token`,
  );
}

const serviceClientPath = path.resolve(
  process.cwd(),
  "native-windows/src/Vex.Windows.App/Services/VpnServiceClient.cs",
);
const serviceClientSource = fs.readFileSync(serviceClientPath, "utf8");
if (!/TokenImpersonationLevel\.Identification/u.test(serviceClientSource)) {
  failures.push(
    `${serviceClientPath}: the service must receive an identification token for owner attestation`,
  );
}

const profileKeyringPath = path.resolve(
  process.cwd(),
  "native-windows/packaging/profile-signing-keys.json",
);
if (!fs.existsSync(profileKeyringPath)) {
  failures.push(
    `${profileKeyringPath}: the production VPN profile signing keyring is missing`,
  );
} else {
  try {
    const keyring = JSON.parse(fs.readFileSync(profileKeyringPath, "utf8"));
    const keys = Array.isArray(keyring.keys) ? keyring.keys : [];
    if (
      keyring.schema !== "vex.profile-signing-keyring.v1" ||
      keys.length < 1 ||
      keys.some(
        (key) =>
          typeof key.key_id !== "string" ||
          key.key_id.length < 1 ||
          key.algorithm !== "ECDSA_P256_SHA256_DER" ||
          typeof key.subject_public_key_info_base64 !== "string" ||
          key.subject_public_key_info_base64.length < 1,
      )
    ) {
      failures.push(
        `${profileKeyringPath}: invalid production VPN profile signing keyring`,
      );
    }
  } catch {
    failures.push(
      `${profileKeyringPath}: production VPN profile signing keyring is not valid JSON`,
    );
  }
}

const projectPath = path.join(appRoot, "Vex.Windows.App.csproj");
const projectSource = fs.readFileSync(projectPath, "utf8");
for (const property of [
  "EnableMsixTooling",
  "SelfContained",
  "WindowsAppSDKSelfContained",
]) {
  const enabledProperty = new RegExp(
    `<${property}>\\s*true\\s*</${property}>`,
    "u",
  );
  if (!enabledProperty.test(projectSource)) {
    failures.push(
      `${projectPath}: ${property} must be true so publish output is launchable`,
    );
  }
}

if (!/DISABLE_XAML_GENERATED_MAIN/u.test(projectSource)) {
  failures.push(
    `${projectPath}: single-instance activation must run before XAML initialization`,
  );
}
for (const [property, expected] of [
  ["Version", "0.1.74"],
  ["AssemblyVersion", "0.1.74.0"],
  ["FileVersion", "0.1.74.74"],
]) {
  const versionProperty = new RegExp(
    `<${property}>\\s*${expected.replaceAll(".", "\\.")}\\s*</${property}>`,
    "u",
  );
  if (!versionProperty.test(projectSource)) {
    failures.push(
      `${projectPath}: ${property} must describe the current 0.1.74 build 74 release`,
    );
  }
}
const programPath = path.join(appRoot, "Program.cs");
if (!fs.existsSync(programPath)) {
  failures.push(`${programPath}: custom single-instance entry point is missing`);
} else {
  const programSource = fs.readFileSync(programPath, "utf8");
  for (const token of [
    'FindOrRegisterForKey("main")',
    "RedirectActivationToAsync",
    "Application.Start",
    "HandleRedirectedActivation",
  ]) {
    if (!programSource.includes(token)) {
      failures.push(
        `${programPath}: missing single-instance activation token ${token}`,
      );
    }
  }
}

const homePagePath = path.join(appRoot, "Views", "HomePage.xaml");
const homePageSource = fs.readFileSync(homePagePath, "utf8");
if (!/<ScrollViewer\b/u.test(homePageSource)) {
  failures.push(
    `${homePagePath}: the connection card must remain scrollable when notices wrap`,
  );
}
const homePageCodeBehindPath = `${homePagePath}.cs`;
const homePageCodeBehindSource = fs.readFileSync(
  homePageCodeBehindPath,
  "utf8",
);
if (!/if\s*\(response\.Success\)\s*\{\s*HideNotice\(\);\s*\}/u.test(
  homePageCodeBehindSource,
)) {
  failures.push(
    `${homePageCodeBehindPath}: a successful VPN retry must clear the previous failure notice`,
  );
}
for (const parityToken of [
  'x:Name="FocusPulseHero"',
  'x:Name="LocationCarousel"',
  'x:Name="CountryArtwork"',
  'AutomationProperties.AutomationId="PowerButton"',
]) {
  if (!homePageSource.includes(parityToken)) {
    failures.push(
      `${homePagePath}: missing current macOS-parity home token ${parityToken}`,
    );
  }
}

for (const pageName of [
  "AccountPage.xaml",
  "SupportPage.xaml",
  "SettingsPage.xaml",
]) {
  const pagePath = path.join(appRoot, "Views", pageName);
  const pageSource = fs.readFileSync(pagePath, "utf8");
  if (/\bWidth="430"/u.test(pageSource) || !/\bMaxWidth="430"/u.test(pageSource)) {
    failures.push(
      `${pagePath}: page content must shrink responsively below the macOS-parity 430px maximum`,
    );
  }
}
if (!/\bMaxWidth="1120"/u.test(homePageSource)) {
  failures.push(
    `${homePagePath}: the current home composition must use the wide macOS-parity canvas`,
  );
}

const mainWindowPath = path.join(appRoot, "MainWindow.xaml");
const mainWindowSource = fs.readFileSync(mainWindowPath, "utf8");
const mainWindowCodeSource = fs.readFileSync(`${mainWindowPath}.cs`, "utf8");
for (const responsiveToken of [
  'SizeChanged="OnShellRootSizeChanged"',
  'x:Name="FocusPulseHeader"',
  'x:Name="BottomNavigationDock"',
  'x:Name="PageTitleText"',
]) {
  if (!mainWindowSource.includes(responsiveToken)) {
    failures.push(
      `${mainWindowPath}: missing responsive shell token ${responsiveToken}`,
    );
  }
}
if (mainWindowSource.includes('x:Name="SidebarColumn"')) {
  failures.push(
    `${mainWindowPath}: the legacy sidebar must not remain in the current macOS-parity shell`,
  );
}
if (
  !mainWindowCodeSource.includes("DisplayVersion()") ||
  !mainWindowCodeSource.includes('" · build "')
) {
  failures.push(
    `${mainWindowPath}.cs: footer must show the current release version and build`,
  );
}

for (const xamlPath of walk(appRoot).filter((file) => file.endsWith(".xaml"))) {
  const source = fs.readFileSync(xamlPath, "utf8");
  const classMatch = source.match(/\bx:Class="([^"]+)"/u);
  if (!classMatch) {
    failures.push(`${xamlPath}: missing x:Class`);
    continue;
  }

  const codeBehindPath = `${xamlPath}.cs`;
  if (!fs.existsSync(codeBehindPath)) {
    failures.push(`${xamlPath}: missing ${path.basename(codeBehindPath)}`);
    continue;
  }

  const codeBehind = fs.readFileSync(codeBehindPath, "utf8");
  const className = classMatch[1].split(".").at(-1);
  const classPattern = new RegExp(
    `\\bpartial\\s+class\\s+${className}\\b`,
    "u",
  );
  if (!classPattern.test(codeBehind)) {
    failures.push(
      `${codeBehindPath}: does not define partial class ${classMatch[1]}`,
    );
  }

  for (const match of source.matchAll(/\b[A-Za-z]+="(On[A-Z][A-Za-z0-9_]*)"/gu)) {
    const handler = match[1];
    const handlerPattern = new RegExp(`\\b${handler}\\s*\\(`, "u");
    if (!handlerPattern.test(codeBehind)) {
      failures.push(`${xamlPath}: handler ${handler} is missing in code-behind`);
    }
  }
}

if (failures.length > 0) {
  for (const failure of failures) {
    console.error(failure);
  }
  process.exitCode = 1;
} else {
  console.log("Native Windows XAML/code-behind surface is consistent.");
}
