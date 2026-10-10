# Run the real local publisher with an isolated unsigned artifact fixture.
# Its signing providers are mocked; no .NET build or real release signing runs.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$publisher = Join-Path $PSScriptRoot '../packaging/publish-native-windows.ps1'
. (Join-Path $PSScriptRoot '../packaging/ReleaseValidation.ps1')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($publisher, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    Invoke-Expression $definition.Extent.Text
}
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Assert-Rejected([scriptblock]$action, [string]$message) {
    $rejected = $false
    try { & $action | Out-Null } catch { $rejected = $true }
    Assert $rejected $message
}
$optional = Get-WindowsReleasePolicy -Version '2.0' -RolloutPercent 10
Assert ($optional.RequiredVersionFloor -eq '0.0.0.0' -and -not $optional.RequiredUpdate -and $optional.RolloutPercent -eq 10) 'An optional cohort must not implicitly force every older client to the release version.'
$mandatory = Get-WindowsReleasePolicy -Version '2.0' -RequiredUpdate $true -RolloutPercent 0
Assert ($mandatory.RequiredUpdate -and $mandatory.RolloutPercent -eq 100) 'An explicit mandatory release must override even a zero-percent cohort.'
$floor = Get-WindowsReleasePolicy -Version '2.0' -MinimumSupportedVersion '1.0' -RequiredVersionFloor '1.5'
Assert ($floor.RequiredVersionFloor -eq '1.5.0.0' -and $floor.MinimumSupportedVersion -eq '1.0.0.0') 'Explicit floors must remain distinct from the install version and normalize consistently.'
Assert ((Get-WindowsReleasePolicy -Version '2.0' -MinimumSupportedVersion '1.0').RequiredVersionFloor -eq '1.0.0.0') 'An explicit supported baseline must be retained.'
foreach ($arguments in @(
    @{ Version = '2.0'; RequiredVersionFloor = '3.0' },
    @{ Version = '2.0'; MinimumSupportedVersion = '3.0' },
    @{ Version = '2.0'; RequiredVersionFloor = '1..0' },
    @{ Version = '2.0'; RequiredVersionFloor = '1.65536' },
    @{ Version = '2.0'; RolloutPercent = -1 }
)) { Assert-Rejected { Get-WindowsReleasePolicy @arguments } 'A release with invalid policy metadata must be rejected.' }

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('vex-release-readiness-' + [guid]::NewGuid().ToString('N'))
$packages = Join-Path $temporary 'packages'
$environmentNames = @('VEX_WINDOWS_UPDATE_ORIGIN','VEX_WINDOWS_UPDATE_KEY_ID','VEX_WINDOWS_UPDATE_PRIVATE_KEY_BASE64',
    'VEX_WINDOWS_UPDATE_PUBLIC_KEY_BASE64','VEX_WINDOWS_MANIFEST_REVISION','VEX_WINDOWS_RELEASE_NOTES',
    'VEX_WINDOWS_MINIMUM_SUPPORTED_VERSION','VEX_WINDOWS_REQUIRED_VERSION_FLOOR','VEX_WINDOWS_UPDATE_REQUIRED','VEX_WINDOWS_ROLLOUT_PERCENT')
$previousEnvironment = @{}
foreach ($name in $environmentNames) { $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }
$global:VexReleaseReadinessSigner = @{ Mode = 'valid'; Calls = @() }
$global:VexReleaseReadinessAuthenticode = @{
    Mode = 'valid'; TargetArchitecture = 'arm64'; Calls = @()
    RawData = [Text.Encoding]::UTF8.GetBytes('Known isolated fixture signing certificate')
}
$certificateSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
    $global:VexReleaseReadinessAuthenticode.RawData))
function Get-AuthenticodeSignature {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    $global:VexReleaseReadinessAuthenticode.Calls += $LiteralPath
    $targetName = "VEX.Setup.$($global:VexReleaseReadinessAuthenticode.TargetArchitecture).exe"
    $mode = if ([IO.Path]::GetFileName($LiteralPath) -ceq $targetName) {
        $global:VexReleaseReadinessAuthenticode.Mode
    } else { 'valid' }
    if ($mode -eq 'unsigned') {
        return [pscustomobject]@{ Status = [Management.Automation.SignatureStatus]::NotSigned; SignerCertificate = $null }
    }
    $rawData = if ($mode -eq 'mismatch') { [Text.Encoding]::UTF8.GetBytes('A different valid certificate') }
               else { $global:VexReleaseReadinessAuthenticode.RawData }
    return [pscustomobject]@{
        Status = [Management.Automation.SignatureStatus]::Valid
        SignerCertificate = [pscustomobject]@{ RawData = $rawData }
    }
}
function dotnet {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments)
    $global:VexReleaseReadinessSigner.Calls += [pscustomobject]@{
        Private = [Environment]::GetEnvironmentVariable('VEX_WINDOWS_UPDATE_PRIVATE_KEY_BASE64')
        Public = [Environment]::GetEnvironmentVariable('VEX_WINDOWS_UPDATE_PUBLIC_KEY_BASE64')
    }
    $global:LASTEXITCODE = if ($global:VexReleaseReadinessSigner.Mode -eq 'reject') { 6 } else { 0 }
    if ($global:VexReleaseReadinessSigner.Mode -eq 'malformed') { return 'not-base64!' }
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('mocked verified signature'))
}
try {
    [Environment]::SetEnvironmentVariable('VEX_WINDOWS_UPDATE_ORIGIN', 'https://downloads.vexguard.app/windows/native/')
    [Environment]::SetEnvironmentVariable('VEX_WINDOWS_UPDATE_KEY_ID', 'fixture-p256')
    [Environment]::SetEnvironmentVariable('VEX_WINDOWS_UPDATE_PRIVATE_KEY_BASE64', 'fixture-private')
    [Environment]::SetEnvironmentVariable('VEX_WINDOWS_UPDATE_PUBLIC_KEY_BASE64', 'fixture-public')
    [Environment]::SetEnvironmentVariable('VEX_WINDOWS_MANIFEST_REVISION', '1')
    [Environment]::SetEnvironmentVariable('VEX_WINDOWS_RELEASE_NOTES', 'Isolated unsigned fixture')
    [Environment]::SetEnvironmentVariable('VEX_WINDOWS_MINIMUM_SUPPORTED_VERSION', $null)
    [Environment]::SetEnvironmentVariable('VEX_WINDOWS_REQUIRED_VERSION_FLOOR', $null)
    [Environment]::SetEnvironmentVariable('VEX_WINDOWS_UPDATE_REQUIRED', 'false')
    [Environment]::SetEnvironmentVariable('VEX_WINDOWS_ROLLOUT_PERCENT', '10')
    foreach ($architecture in @('x64','arm64')) {
        $directory = Join-Path $packages $architecture
        $null = New-Item -ItemType Directory -Path $directory -Force
        $metadata = [ordered]@{
            schema = 'vex.windows-package-output.v2'; channel = 'stable'; architecture = $architecture
            version = '2.0.0.0'; package_name = 'VEX.ReadinessFixture'; publisher = 'CN=VEX Fixture'
            package_file = 'fixture.msix'; bootstrap_file = 'bootstrap-native-windows.ps1'
            install_service_script_file = 'install-vpn-service.ps1'; uninstall_service_script_file = 'uninstall-vpn-service.ps1'
            vclibs_dependency_file = "Microsoft.VCLibs.$architecture.14.00.Desktop.appx"; vclibs_dependency_version = '14.0.33728.0'
            update_signing_key_id = 'fixture-p256'; update_signing_public_key_base64 = 'fixture-public'
            client_certificate_sha256 = $certificateSha256
        }
        foreach ($artifact in @('package','bootstrap','install_service_script','uninstall_service_script','vclibs_dependency')) {
            $fileName = [string]$metadata["${artifact}_file"]
            $path = Join-Path $directory $fileName
            [IO.File]::WriteAllText($path, "Unsigned isolated $architecture $artifact fixture")
            $metadata["${artifact}_sha256"] = (Get-FileHash -LiteralPath $path).Hash
            $metadata["${artifact}_size_bytes"] = (Get-Item -LiteralPath $path).Length
        }
        [IO.File]::WriteAllBytes((Join-Path $directory "VEX.Setup.$architecture.exe"),
            [Text.Encoding]::UTF8.GetBytes("Unsigned isolated $architecture native Setup fixture"))
        [IO.File]::WriteAllText((Join-Path $directory 'package-metadata.json'), ($metadata | ConvertTo-Json))
        foreach ($unreferenced in @('do-not-ship.pfx', 'private.env', 'artifact.tmp', 'private-key.pem')) {
            [IO.File]::WriteAllText((Join-Path $directory $unreferenced), "Unreferenced fixture secret: $unreferenced")
        }
    }
    [IO.File]::WriteAllText((Join-Path $packages 'do-not-ship.pfx'), 'Unreferenced root fixture certificate key')
    foreach ($required in @($false, $true)) {
        [Environment]::SetEnvironmentVariable('VEX_WINDOWS_UPDATE_REQUIRED', $required.ToString())
        $output = Join-Path $temporary $(if ($required) { 'mandatory' } else { 'optional' })
        & $publisher -PackagesRoot $packages -PublishRoot $output
        foreach ($architecture in @('x64','arm64')) {
            $manifest = Get-Content -LiteralPath (Join-Path $output "stable/$architecture/update.json") -Raw | ConvertFrom-Json
            Assert ($manifest.required_version_floor -eq '0.0.0.0' -and $manifest.releases[0].required -eq $required -and
                $manifest.releases[0].rollout_percent -eq $(if ($required) { 100 } else { 10 })) 'The actual published manifest must preserve safe optional/mandatory rollout behavior.'
            $versioned = Join-Path $output "stable/2.0.0.0/$architecture"
            $entry = Get-Content -LiteralPath (Join-Path $versioned 'bootstrap-entry.json') -Raw | ConvertFrom-Json
            Assert ($entry.files.vclibs_dependency.uri -eq $manifest.releases[0].vclibs_dependency_uri -and
                $entry.files.vclibs_dependency.sha256 -eq $manifest.releases[0].vclibs_dependency_sha256 -and
                $entry.files.vclibs_dependency.size_bytes -eq $manifest.releases[0].vclibs_dependency_size_bytes) 'Signed entry and updater dependency descriptors must agree.'
            Assert ((Get-FileHash -LiteralPath (Join-Path $versioned "Microsoft.VCLibs.$architecture.14.00.Desktop.appx")).Hash -eq $entry.files.vclibs_dependency.sha256) 'The published dependency bytes must match their descriptor.'
            $setupName = "VEX.Setup.$architecture.exe"
            $setupSource = Join-Path $packages "$architecture/$setupName"
            $setupDestination = Join-Path $versioned $setupName
            $setupUri = "https://downloads.vexguard.app/windows/native/stable/2.0.0.0/$architecture/$setupName"
            $setupHash = (Get-FileHash -LiteralPath $setupSource -Algorithm SHA256).Hash
            $setupSize = (Get-Item -LiteralPath $setupSource).Length
            Assert ($entry.files.setup.uri -ceq $setupUri -and $entry.files.setup.sha256 -ceq $setupHash -and
                $entry.files.setup.size_bytes -eq $setupSize) 'The signed bootstrap entry must bind the native Setup URI, hash and exact size.'
            Assert ($manifest.releases[0].native_setup_uri -ceq $setupUri -and
                $manifest.releases[0].native_setup_sha256 -ceq $setupHash -and
                $manifest.releases[0].native_setup_size_bytes -eq $setupSize) 'The updater must expose the same native Setup descriptor as the signed entry.'
            Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($setupDestination)) -ceq
                [Convert]::ToBase64String([IO.File]::ReadAllBytes($setupSource))) 'Published native Setup must preserve the exact input bytes.'
            Assert ((Test-Path -LiteralPath (Join-Path $versioned 'bootstrap-entry.json.sig') -PathType Leaf)) 'The bootstrap entry containing native Setup must retain its detached signature.'
            $bundleName = "VEX.Native.stable.$architecture.2.0.0.0.zip"
            $bundlePath = Join-Path $versioned $bundleName
            $bundleUri = "https://downloads.vexguard.app/windows/native/stable/2.0.0.0/$architecture/$bundleName"
            $bundleHash = (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash
            $bundleSize = (Get-Item -LiteralPath $bundlePath).Length
            Assert ($bundleSize -gt 0 -and $bundleSize -le (512L * 1024 * 1024)) 'The downloadable native bundle must remain within the 512 MiB installer limit.'
            Assert ($entry.files.bundle.uri -ceq $bundleUri -and $entry.files.bundle.sha256 -ceq $bundleHash -and
                $entry.files.bundle.size_bytes -eq $bundleSize) 'The signed entry must bind the actual ZIP bytes to their same-origin URI, SHA-256 and size.'
            Assert ($manifest.releases[0].native_bundle_uri -ceq $bundleUri -and
                $manifest.releases[0].native_bundle_sha256 -ceq $bundleHash -and
                $manifest.releases[0].native_bundle_size_bytes -eq $bundleSize) 'The signed update manifest must expose the same downloadable ZIP descriptor.'
            $expectedMembers = @($setupName, 'fixture.msix', 'package-metadata.json', 'bootstrap-native-windows.ps1',
                'install-vpn-service.ps1', 'uninstall-vpn-service.ps1', "Microsoft.VCLibs.$architecture.14.00.Desktop.appx")
            $archive = [IO.Compression.ZipFile]::OpenRead($bundlePath)
            try {
                $actualMembers = @($archive.Entries | ForEach-Object { $_.FullName })
                Assert ($actualMembers.Count -eq 7 -and
                    (($actualMembers | Sort-Object) -join '|') -ceq (($expectedMembers | Sort-Object) -join '|')) 'The native bundle must contain exactly seven official root-named files, excluding secrets, keys, temporary files and directories.'
                foreach ($member in $archive.Entries) {
                    $publishedMember = Join-Path $versioned $member.FullName
                    $memberStream = $member.Open()
                    try { $memberHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($memberStream)) }
                    finally { $memberStream.Dispose() }
                    Assert ($member.Length -eq (Get-Item -LiteralPath $publishedMember).Length -and
                        $memberHash -ceq (Get-FileHash -LiteralPath $publishedMember -Algorithm SHA256).Hash) 'Each ZIP member must preserve the exact corresponding published artifact bytes.'
                }
            }
            finally { $archive.Dispose() }
            $appinstaller = [xml](Get-Content -LiteralPath (Join-Path $output "stable/$architecture/VEX.Native.stable.$architecture.appinstaller") -Raw)
            Assert ($appinstaller.AppInstaller.Dependencies.Package.Uri -eq $manifest.releases[0].vclibs_dependency_uri) 'App Installer and the bootstrap must reference the same dependency.'
        }
    }
    Assert ($global:VexReleaseReadinessAuthenticode.Calls.Count -eq 4) 'Both architectures must pass native Setup signature preflight for each successful publication.'
    Assert ($global:VexReleaseReadinessSigner.Calls.Count -eq 10 -and @($global:VexReleaseReadinessSigner.Calls | Where-Object { $_.Public -ne 'fixture-public' -or $_.Private -ne 'fixture-private' }).Count -eq 0) 'Every signing operation must receive the exact shipping public and private inputs.'

    $output = Join-Path $temporary 'invalid-floor'
    [Environment]::SetEnvironmentVariable('VEX_WINDOWS_REQUIRED_VERSION_FLOOR', '3.0.0.0')
    Assert-Rejected { & $publisher -PackagesRoot $packages -PublishRoot $output } 'A floor above the release must reject the whole release before output.'
    Assert (-not (Test-Path -LiteralPath $output)) 'Invalid policy left release output behind.'
    [Environment]::SetEnvironmentVariable('VEX_WINDOWS_REQUIRED_VERSION_FLOOR', $null)
    [Environment]::SetEnvironmentVariable('VEX_WINDOWS_UPDATE_PUBLIC_KEY_BASE64', 'different-shipping-public')
    $output = Join-Path $temporary 'different-shipping-key'
    Assert-Rejected { & $publisher -PackagesRoot $packages -PublishRoot $output } 'The publisher must reject inputs that differ from the bundled keyring.'
    Assert (-not (Test-Path -LiteralPath $output)) 'Mismatched bundled key inputs left release output behind.'
    [Environment]::SetEnvironmentVariable('VEX_WINDOWS_UPDATE_PUBLIC_KEY_BASE64', 'fixture-public')
    foreach ($mode in @('reject','malformed')) {
        $global:VexReleaseReadinessSigner.Mode = $mode
        $output = Join-Path $temporary "invalid-signer-$mode"
        Assert-Rejected { & $publisher -PackagesRoot $packages -PublishRoot $output } 'A signer rejection or malformed result must stop release preparation.'
        Assert (-not (Test-Path -LiteralPath $output)) 'A rejected signing preflight left release output behind.'
        Assert ([Environment]::GetEnvironmentVariable('VEX_WINDOWS_UPDATE_PRIVATE_KEY_BASE64') -eq 'fixture-private' -and
            [Environment]::GetEnvironmentVariable('VEX_WINDOWS_UPDATE_PUBLIC_KEY_BASE64') -eq 'fixture-public') 'Signer failure must restore both environment inputs.'
    }
    $global:VexReleaseReadinessSigner.Mode = 'valid'
    $missingSetup = Join-Path $packages 'arm64/VEX.Setup.arm64.exe'
    $retainedSetup = "$missingSetup.retained"
    [IO.File]::Move($missingSetup, $retainedSetup)
    try {
        $output = Join-Path $temporary 'missing-native-setup'
        Assert-Rejected { & $publisher -PackagesRoot $packages -PublishRoot $output } 'A missing native Setup in either architecture must reject the entire release.'
        Assert (-not (Test-Path -LiteralPath $output)) 'Missing native Setup left partial release output behind.'
    }
    finally { [IO.File]::Move($retainedSetup, $missingSetup) }
    foreach ($mode in @('unsigned','mismatch')) {
        $global:VexReleaseReadinessAuthenticode.Mode = $mode
        $output = Join-Path $temporary "invalid-native-setup-$mode"
        Assert-Rejected { & $publisher -PackagesRoot $packages -PublishRoot $output } 'An unsigned Setup or a valid Setup with a different signer must reject both architectures before output.'
        Assert (-not (Test-Path -LiteralPath $output)) 'Invalid native Setup signer left partial release output behind.'
    }
    $global:VexReleaseReadinessAuthenticode.Mode = 'valid'
    Write-Host 'Windows release readiness tests passed: safe rollout/floors, bundled signing inputs, preflight rejection, exact native Setup/bundle publication and secret exclusion.'
}
finally {
    Remove-Variable -Name VexReleaseReadinessSigner -Scope Global
    Remove-Variable -Name VexReleaseReadinessAuthenticode -Scope Global
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name]) }
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
