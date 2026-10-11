#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][Alias('ExplicitlyDisposableRunner')][switch]$DisposableRunner,
    [Parameter(Mandatory = $true)][string]$CandidateBundleDirectory,
    [Parameter(Mandatory = $true)][string]$PrecedingBundleDirectory,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [switch]$PrecedingIsSynthetic
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-AcceptanceRegularPath {
    param([string]$Path, [switch]$Directory)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ([bool]$item.PSIsContainer -ne [bool]$Directory) { throw 'Acceptance input has the wrong file type.' }
    $current = $item
    while ($null -ne $current) {
        if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($null -ne $current.PSObject.Properties['LinkType'] -and $current.LinkType -eq 'HardLink')) {
            throw 'Acceptance input contains a link or reparse point.'
        }
        $current = if ($current -is [IO.DirectoryInfo]) { $current.Parent } else { $current.Directory }
    }
    return $item.FullName
}

function Read-AcceptanceMetadata {
    param([string]$Path)
    $null = Assert-AcceptanceRegularPath $Path
    if ((Get-Item -LiteralPath $Path).Length -gt 64KB) { throw 'Acceptance metadata is too large.' }
    $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($name in @('schema', 'architecture', 'version', 'package_name', 'publisher',
        'install_entrypoint', 'service_ownership', 'raw_msix_provisions_service', 'raw_appinstaller_provisions_service',
        'package_file', 'package_sha256', 'client_certificate_sha256', 'app_executable_sha256',
        'service_executable_sha256', 'amneziawg_sha256', 'wintun_sha256', 'profile_signing_keyring_sha256',
        'bootstrap_file', 'bootstrap_sha256', 'install_service_script_file', 'install_service_script_sha256',
        'uninstall_service_script_file', 'uninstall_service_script_sha256',
        'vclibs_dependency_file', 'vclibs_dependency_sha256', 'vclibs_dependency_version', 'vclibs_dependency_size_bytes')) {
        if ($name -notin $value.PSObject.Properties.Name -or [string]::IsNullOrWhiteSpace([string]$value.$name)) {
            throw 'Acceptance metadata is incomplete.'
        }
    }
    if ($value.schema -cne 'vex.windows-package-output.v2' -or $value.architecture -cne 'x64' -or
        $value.install_entrypoint -cne 'elevated_bootstrap' -or $value.service_ownership -cne 'manual_sc_bootstrap' -or
        $value.raw_msix_provisions_service -isnot [bool] -or $value.raw_msix_provisions_service -ne $false -or
        $value.raw_appinstaller_provisions_service -isnot [bool] -or $value.raw_appinstaller_provisions_service -ne $false -or
        $value.version -notmatch '^\d+\.\d+\.\d+\.\d+$' -or
        $value.package_name -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{2,49}$' -or
        $value.publisher -notmatch '^CN=') { throw 'Acceptance package contract is invalid.' }
    $version = [version]$value.version
    if (@($version.Major, $version.Minor, $version.Build, $version.Revision | Where-Object { $_ -gt 65535 }).Count) {
        throw 'Acceptance package version is invalid.'
    }
    foreach ($property in $value.PSObject.Properties) {
        if ($property.Name.EndsWith('_sha256') -and [string]$property.Value -notmatch '^[A-Fa-f0-9]{64}$') {
            throw 'Acceptance metadata has an invalid SHA256 pin.'
        }
    }
    foreach ($name in @('package_file', 'bootstrap_file', 'install_service_script_file',
        'uninstall_service_script_file', 'vclibs_dependency_file')) {
        $file = [string]$value.$name
        if ($file -in @('.', '..') -or $file -match '[\\/:]' -or [IO.Path]::GetFileName($file) -cne $file) {
            throw 'Acceptance artifacts must be direct bundle files.'
        }
    }
    if ($value.bootstrap_file -cne 'bootstrap-native-windows.ps1' -or
        $value.install_service_script_file -cne 'install-vpn-service.ps1' -or
        $value.uninstall_service_script_file -cne 'uninstall-vpn-service.ps1' -or
        $value.vclibs_dependency_file -cne 'Microsoft.VCLibs.x64.14.00.Desktop.appx' -or
        -not ([string]$value.package_file).EndsWith('.msix', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Acceptance artifact names do not match the release contract.'
    }
    if ($value.vclibs_dependency_version -notmatch '^\d+\.\d+\.\d+\.\d+$' -or
        $value.vclibs_dependency_size_bytes -isnot [long] -and $value.vclibs_dependency_size_bytes -isnot [int] -or
        $value.vclibs_dependency_size_bytes -le 0 -or $value.vclibs_dependency_size_bytes -gt 64MB) {
        throw 'Acceptance dependency metadata is invalid.'
    }
    return $value
}

function Assert-AcceptanceHash {
    param([string]$Path, [string]$Expected)
    $null = Assert-AcceptanceRegularPath $Path
    if ($Expected -notmatch '^[A-Fa-f0-9]{64}$' -or
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $Expected) {
        throw 'Acceptance artifact hash does not match its release metadata.'
    }
}

function Assert-AcceptanceSignature {
    param([string]$Path, [string]$CertificateSha256)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
        $null -eq $signature.SignerCertificate) { throw 'Acceptance requires valid Authenticode signatures.' }
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { $actual = [BitConverter]::ToString($sha256.ComputeHash($signature.SignerCertificate.RawData)).Replace('-', '') }
    finally { $sha256.Dispose() }
    if ($actual -ine $CertificateSha256) { throw 'Acceptance artifact signer does not match the release pin.' }
}

function Read-AcceptancePackageIdentity {
    param([string]$Path)
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entries = @($archive.Entries | Where-Object FullName -CEQ 'AppxManifest.xml')
        if ($entries.Count -ne 1 -or $entries[0].Length -le 0 -or $entries[0].Length -gt 1MB -or
            @($archive.Entries | Where-Object FullName -CEQ 'AppxSignature.p7x').Count -ne 1) {
            throw 'Acceptance requires one bounded manifest and a signed MSIX.'
        }
        $settings = [Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $stream = $entries[0].Open()
        $reader = [Xml.XmlReader]::Create($stream, $settings)
        try {
            $document = [Xml.XmlDocument]::new()
            $document.XmlResolver = $null
            $document.Load($reader)
        }
        finally { $reader.Dispose(); $stream.Dispose() }
        $identity = $document.SelectSingleNode('/*[local-name()="Package"]/*[local-name()="Identity"]')
        if ($null -eq $identity) { throw 'Acceptance MSIX identity is missing.' }
        return [pscustomobject]@{
            Name = $identity.GetAttribute('Name'); Publisher = $identity.GetAttribute('Publisher')
            Version = $identity.GetAttribute('Version'); Architecture = $identity.GetAttribute('ProcessorArchitecture')
        }
    }
    finally { $archive.Dispose() }
}

function Read-AcceptanceBundle {
    param([string]$Directory)
    $root = Assert-AcceptanceRegularPath -Path $Directory -Directory
    $metadataPath = Join-Path $root 'package-metadata.json'
    $metadata = Read-AcceptanceMetadata $metadataPath
    foreach ($pair in @(@('package_file', 'package_sha256'), @('bootstrap_file', 'bootstrap_sha256'),
        @('install_service_script_file', 'install_service_script_sha256'),
        @('uninstall_service_script_file', 'uninstall_service_script_sha256'),
        @('vclibs_dependency_file', 'vclibs_dependency_sha256'))) {
        Assert-AcceptanceHash (Join-Path $root $metadata.($pair[0])) $metadata.($pair[1])
    }
    foreach ($name in @('bootstrap_file', 'install_service_script_file', 'uninstall_service_script_file', 'package_file')) {
        Assert-AcceptanceSignature (Join-Path $root $metadata.$name) $metadata.client_certificate_sha256
    }
    $package = Join-Path $root $metadata.package_file
    $identity = Read-AcceptancePackageIdentity $package
    if ($identity.Name -cne $metadata.package_name -or $identity.Publisher -cne $metadata.publisher -or
        $identity.Version -cne $metadata.version -or $identity.Architecture -cne 'x64') {
        throw 'Acceptance metadata does not match the actual signed package identity.'
    }
    return [pscustomobject]@{ Root = $root; MetadataPath = $metadataPath; Metadata = $metadata; PackagePath = $package }
}

function Assert-AcceptanceBundlePair {
    param($Candidate, $Preceding)
    if ($Candidate.Metadata.package_name -cne $Preceding.Metadata.package_name -or
        $Candidate.Metadata.publisher -cne $Preceding.Metadata.publisher -or
        $Candidate.Metadata.client_certificate_sha256 -ine $Preceding.Metadata.client_certificate_sha256 -or
        [version]$Preceding.Metadata.version -ge [version]$Candidate.Metadata.version) {
        throw 'Acceptance requires older and newer signed packages with the same identity, publisher and signer.'
    }
}

function Copy-AcceptanceDownloadedBundle {
    param($Bundle, [string]$Destination)
    if (Test-Path -LiteralPath $Destination) { throw 'Acceptance private bundle directory already exists.' }
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    $files = @('package-metadata.json', $Bundle.Metadata.package_file, $Bundle.Metadata.bootstrap_file,
        $Bundle.Metadata.install_service_script_file, $Bundle.Metadata.uninstall_service_script_file,
        $Bundle.Metadata.vclibs_dependency_file)
    $setupFile = 'VEX.Setup.' + $Bundle.Metadata.architecture + '.exe'
    if (Test-Path -LiteralPath (Join-Path $Bundle.Root $setupFile)) {
        Assert-AcceptanceSignature (Join-Path $Bundle.Root $setupFile) $Bundle.Metadata.client_certificate_sha256
        $files += $setupFile
    }
    foreach ($file in $files) {
        $source = Join-Path $Bundle.Root $file
        $null = Assert-AcceptanceRegularPath $source
        $copy = Join-Path $Destination $file
        Copy-Item -LiteralPath $source -Destination $copy
        # ADS models a downloaded release without modifying signed/hash-pinned
        # content bytes. Never mark or rewrite the caller's original inputs.
        Set-Content -LiteralPath $copy -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3" -Encoding ASCII
        if ((Get-Content -LiteralPath $copy -Stream Zone.Identifier -Raw) -notmatch 'ZoneId=3') {
            throw 'Acceptance downloaded-file marker could not be verified.'
        }
    }
    return Read-AcceptanceBundle $Destination
}

function New-AcceptancePrivateDirectory {
    param([string]$FixtureId)
    $path = Join-Path $env:RUNNER_TEMP ('vex-signed-install-' + $FixtureId)
    if (Test-Path -LiteralPath $path) { throw 'Acceptance fixture directory collision.' }
    [IO.Directory]::CreateDirectory($path) | Out-Null
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.Principal.SecurityIdentifier]::new('S-1-5-18'), [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl',
            'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $path -AclObject $acl
    [IO.File]::WriteAllText((Join-Path $path 'owned-fixture'), $FixtureId)
    return $path
}

function Remove-AcceptancePrivateDirectory {
    param([string]$Path, [string]$FixtureId)
    if ([string]::IsNullOrEmpty($Path)) { return }
    $null = Assert-AcceptanceRegularPath -Path $Path -Directory
    $marker = Join-Path $Path 'owned-fixture'
    $null = Assert-AcceptanceRegularPath $marker
    if ([IO.File]::ReadAllText($marker) -cne $FixtureId -or
        [IO.Path]::GetFileName($Path) -cne ('vex-signed-install-' + $FixtureId)) {
        throw 'Acceptance refuses to remove a private directory without its own marker.'
    }
    foreach ($child in @(Get-ChildItem -LiteralPath $Path -Recurse -Force)) {
        $null = Assert-AcceptanceRegularPath -Path $child.FullName -Directory:$child.PSIsContainer
    }
    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Assert-AcceptanceRunner {
    param([bool]$ExplicitlyDisposable)
    if (-not $ExplicitlyDisposable -or -not $IsWindows -or $env:GITHUB_ACTIONS -cne 'true' -or
        $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or
        [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP) -or
        [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64) {
        throw 'Signed install acceptance requires an explicitly disposable GitHub-hosted Windows x64 runner.'
    }
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Signed install acceptance requires the disposable runner administrator account.'
    }
}

function Assert-AcceptanceFreshHost {
    param([string]$PackageName)
    if (@(Get-AppxPackage -AllUsers | Where-Object { $_.Name -eq $PackageName -or $_.Name -match '(?i)vex' }).Count -or
        @(Get-Service | Where-Object { $_.Name -match '^(?i)(VEX|Amnezia|WireGuard|OpenVPN|Tailscale|ZeroTier)' }).Count -or
        @(Get-Process -Name 'Vex.Windows.App' -ErrorAction SilentlyContinue).Count) {
        throw 'Acceptance refuses an existing VEX installation or VPN service.'
    }
    foreach ($path in @(
        (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'VEX'),
        (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'VEX'),
        (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'AmneziaWG'),
        'HKLM:\SOFTWARE\VEX\VPN')) {
        if (Test-Path -LiteralPath $path) { throw 'Acceptance refuses existing VEX or vendor state.' }
    }
    if (@(Get-NetAdapter -IncludeHidden | Where-Object { $_.Name -ieq 'vex' -or
        $_.InterfaceDescription -match '(?i)wintun|wireguard|amnezia|openvpn|tap-windows|tailscale|zerotier|proton|nordvpn' }).Count) {
        throw 'Acceptance refuses an existing VPN adapter.'
    }
    $connections = @(Get-VpnConnection) + @(Get-VpnConnection -AllUserConnection)
    if (@($connections | Where-Object ConnectionStatus -NE 'Disconnected').Count) {
        throw 'Acceptance refuses an active Windows VPN connection.'
    }
}

function Stop-AcceptanceProcess {
    param($Process)
    if (-not $Process.HasExited) {
        $Process.Kill($true)
        if (-not $Process.WaitForExit(5000)) { throw 'Acceptance child termination could not be confirmed.' }
    }
}

function Invoke-AcceptanceProcess {
    param([string]$Executable, [string[]]$Arguments, [ValidateRange(1, 600)][int]$TimeoutSeconds = 240)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-AcceptanceProcess $process
            throw 'Acceptance phase exceeded its process deadline.'
        }
        # Arbitrary installer/app output is never included in uploaded evidence.
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), 5000)) {
            throw 'Acceptance child output handles did not close.'
        }
        if ($process.ExitCode -ne 0) { throw 'Acceptance child reported failure.' }
    }
    finally { $process.Dispose() }
}

function Get-AcceptanceSystemPowerShellPath {
    return Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
}

function Open-AcceptanceBundleLocks {
    param($Bundle)
    $streams = [Collections.Generic.List[IO.FileStream]]::new()
    try {
        $null = Assert-AcceptanceRegularPath $Bundle.MetadataPath
        $streams.Add([IO.File]::Open($Bundle.MetadataPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
        $metadata = Read-AcceptanceMetadata $Bundle.MetadataPath
        foreach ($name in @('bootstrap_file', 'install_service_script_file', 'uninstall_service_script_file', 'package_file', 'vclibs_dependency_file')) {
            $path = Join-Path $Bundle.Root $metadata.$name
            $null = Assert-AcceptanceRegularPath $path
            $streams.Add([IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
        }
        return $streams.ToArray()
    }
    catch { foreach ($stream in $streams) { $stream.Dispose() }; throw }
}

function Open-AcceptanceNativeSetupLocks {
    param($Bundle)
    $streams = @(Open-AcceptanceBundleLocks $Bundle)
    try {
        $path = Join-Path $Bundle.Root ('VEX.Setup.' + $Bundle.Metadata.architecture + '.exe')
        $null = Assert-AcceptanceRegularPath $path
        $streams += [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        return $streams
    }
    catch { foreach ($stream in $streams) { $stream.Dispose() }; throw }
}

function Read-AcceptanceNativeSetup {
    param($Bundle)
    $path = Join-Path $Bundle.Root ('VEX.Setup.' + $Bundle.Metadata.architecture + '.exe')
    $null = Assert-AcceptanceRegularPath $path
    Assert-AcceptanceSignature $path $Bundle.Metadata.client_certificate_sha256
    return [pscustomobject]@{
        Path = $path
        Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        MetadataSha256 = (Get-FileHash -LiteralPath $Bundle.MetadataPath -Algorithm SHA256).Hash
    }
}

function Assert-AcceptanceNativeVerification {
    param($Result, $Metadata)
    foreach ($name in @('schema', 'passed', 'embedded_metadata_present', 'metadata_matches_embedded',
        'bundle_hashes_verified', 'bootstrap_signature_verified', 'setup_signature_verified', 'architecture', 'version')) {
        if ($name -notin $Result.PSObject.Properties.Name) { throw 'Native setup verification evidence is incomplete.' }
    }
    if ($Result.schema -cne 'vex.windows-setup-verification.v1' -or
        $Result.architecture -cne $Metadata.architecture -or $Result.version -cne $Metadata.version) {
        throw 'Native setup verification evidence does not match the candidate.'
    }
    foreach ($name in @('passed', 'embedded_metadata_present', 'metadata_matches_embedded',
        'bundle_hashes_verified', 'bootstrap_signature_verified', 'setup_signature_verified')) {
        if ($Result.$name -isnot [bool] -or $Result.$name -ne $true) {
            throw 'Native setup did not verify its signature, embedded metadata and external bundle.'
        }
    }
}

function Invoke-AcceptanceNativeVerification {
    param($Bundle, [string]$PrivateDirectory)
    $locks = @(Open-AcceptanceNativeSetupLocks $Bundle)
    try {
        $setup = Read-AcceptanceNativeSetup $Bundle
        $resultPath = Join-Path $PrivateDirectory ('native-setup-verification-' + [Guid]::NewGuid().ToString('N') + '.json')
        if (Test-Path -LiteralPath $resultPath) { throw 'Native setup verification result collision.' }
        Invoke-AcceptanceProcess -Executable $setup.Path -Arguments @('--verify-bundle', '--result-path', $resultPath) -TimeoutSeconds 180
        $null = Assert-AcceptanceRegularPath $resultPath
        if ((Get-Item -LiteralPath $resultPath).Length -gt 16KB) { throw 'Native setup verification result is too large.' }
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -Depth 8
        Assert-AcceptanceNativeVerification -Result $result -Metadata $Bundle.Metadata
        # The embedded digest belongs to the signed Setup resource. Keeping the
        # Setup hash out of package-metadata avoids a circular content hash.
        return [ordered]@{ sha256 = $setup.Sha256; metadata_sha256 = $setup.MetadataSha256; bundle_verified = $true }
    }
    finally { foreach ($stream in $locks) { $stream.Dispose() } }
}

function Invoke-AcceptanceNativeSetupUi {
    param($Bundle, [switch]$Install)
    $locks = @(Open-AcceptanceNativeSetupLocks $Bundle)
    try {
        $setup = Read-AcceptanceNativeSetup $Bundle
        $payload = [pscustomobject]@{
            executable = $setup.Path; sha256 = $setup.Sha256; install = [bool]$Install
            package_name = $Bundle.Metadata.package_name; publisher = $Bundle.Metadata.publisher; version = $Bundle.Metadata.version
        } | ConvertTo-Json -Compress
        $encodedPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
        $probe = @'
$ErrorActionPreference = 'Stop'
$inputValue = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__')) | ConvertFrom-Json
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$owned = $null
try {
    $owned = Start-Process -FilePath $inputValue.executable -WorkingDirectory (Split-Path -Parent $inputValue.executable) -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds($(if ($inputValue.install) { 180 } else { 35 }))
    do {
        $owned.Refresh()
        if ($owned.HasExited) { throw 'Native setup exited before its UI was inspected.' }
        if ($owned.MainModule.FileName -ine $inputValue.executable -or
            (Get-FileHash -LiteralPath $inputValue.executable -Algorithm SHA256).Hash -ine $inputValue.sha256) { throw 'Unexpected setup process image.' }
        if ($owned.MainWindowHandle -ne [IntPtr]::Zero) {
            $window = [Windows.Automation.AutomationElement]::FromHandle($owned.MainWindowHandle)
            $ready = $window.Current.AutomationId -ceq 'VexSetupWindow' -or $window.Current.Name -ceq 'VexSetupWindow'
            foreach ($id in @('SetupInstallButton', 'SetupRepairButton', 'SetupUninstallButton', 'SetupVerifyButton', 'SetupStatusText')) {
                $condition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
                $element = $window.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
                if ($null -eq $element -or $element.Current.IsOffscreen) { $ready = $false }
                if ($id -ceq 'SetupInstallButton') { $installButton = $element }
            }
            if ($inputValue.install -and ($null -eq $installButton -or -not $installButton.Current.IsEnabled)) { $ready = $false }
            if ($ready) { break }
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $ready) { throw 'Native setup window and action controls were not available.' }
    if ($inputValue.install) {
        if (@(Get-AppxPackage -Name $inputValue.package_name).Count -or
            @(Get-Service -Name 'VEX VPN Service' -ErrorAction SilentlyContinue).Count) { throw 'Native install requires the fresh acceptance baseline.' }
        ([Windows.Automation.InvokePattern]$installButton.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)).Invoke()
        $deadline = [DateTime]::UtcNow.AddSeconds(360)
        $installed = $false
        do {
            $owned.Refresh()
            if ($owned.HasExited) { throw 'Native setup exited during its Install action.' }
            $package = @(Get-AppxPackage -Name $inputValue.package_name)
            $service = Get-Service -Name 'VEX VPN Service' -ErrorAction SilentlyContinue
            try {
                $installed = $package.Count -eq 1 -and $package[0].Publisher -ceq $inputValue.publisher -and
                    [version]$package[0].Version -eq [version]$inputValue.version -and $null -ne $service -and
                    $service.Status -eq 'Running' -and $installButton.Current.IsEnabled
            }
            finally { if ($null -ne $service) { $service.Dispose() } }
            if ($installed) { break }
            Start-Sleep -Milliseconds 250
        } while ([DateTime]::UtcNow -lt $deadline)
        if (-not $installed) { throw 'Native Install did not complete with the expected package and running service.' }
        # The parent independently verifies protected state, signatures, hashes,
        # actual SCM image and the signed-out app before accepting this action.
    }
}
finally {
    if ($null -ne $owned) {
        try {
            if (-not $owned.HasExited) {
                [void]$owned.CloseMainWindow()
                if (-not $owned.WaitForExit(5000)) { $owned.Kill(); [void]$owned.WaitForExit(5000) }
            }
        }
        finally { $owned.Dispose() }
    }
}
'@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe.Replace('__PAYLOAD__', $encodedPayload)))
        Invoke-AcceptanceProcess -Executable (Get-AcceptanceSystemPowerShellPath) -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -TimeoutSeconds $(if ($Install) { 600 } else { 50 })
    }
    finally { foreach ($stream in $locks) { $stream.Dispose() } }
}

function Invoke-AcceptanceBootstrap {
    param($Bundle, [ValidateSet('Install', 'Verify', 'Repair', 'Rollback', 'Uninstall')][string]$Action, $RollbackBundle)
    $locks = @(Open-AcceptanceBundleLocks $Bundle)
    try {
        # Hold non-writable/non-deletable metadata and script handles while
        # verifying and throughout the child and any UAC service-phase wait.
        $validated = Read-AcceptanceBundle $Bundle.Root
        if ($validated.Metadata.package_sha256 -ine $Bundle.Metadata.package_sha256 -or
            $validated.Metadata.bootstrap_sha256 -ine $Bundle.Metadata.bootstrap_sha256 -or
            $validated.Metadata.client_certificate_sha256 -ine $Bundle.Metadata.client_certificate_sha256) {
            throw 'Acceptance input changed after initial verification.'
        }
        $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $Bundle.Root $Bundle.Metadata.bootstrap_file), '-Phase', 'User', '-Action', $Action,
            '-MetadataPath', $Bundle.MetadataPath, '-PackagePath', $Bundle.PackagePath)
        if ($Action -eq 'Rollback') {
            if ($null -eq $RollbackBundle) { throw 'Acceptance rollback requires the verified preceding release.' }
            $locks += @(Open-AcceptanceBundleLocks $RollbackBundle)
            $null = Read-AcceptanceBundle $RollbackBundle.Root
            $arguments += @('-RollbackPackagePath', $RollbackBundle.PackagePath, '-RollbackMetadataPath', $RollbackBundle.MetadataPath)
        }
        Invoke-AcceptanceProcess -Executable (Get-AcceptanceSystemPowerShellPath) -Arguments $arguments
    }
    finally { foreach ($stream in $locks) { $stream.Dispose() } }
}

function Invoke-AcceptanceNativeInstall {
    param($Bundle, [string]$OwnerSid, $Evidence)
    Add-AcceptancePhase 'native_setup_install_action' { Invoke-AcceptanceNativeSetupUi -Bundle $Bundle -Install } $Evidence
    $Evidence.native_setup_window_verified = $true
    Add-AcceptancePhase 'verify_native_installed_candidate' { Invoke-AcceptanceBootstrap -Bundle $Bundle -Action Verify } $Evidence
    Add-AcceptancePhase 'native_installed_signed_out_app' { Invoke-AcceptanceInstalledUi $Bundle } $Evidence
    $shared = @(Get-AcceptanceSharedDependencies)
    if ($shared.Count -eq 0) { throw 'Native Install did not register its required Microsoft framework.' }
    Add-AcceptancePhase 'uninstall_native_installed_candidate' {
        Stop-AcceptanceInstalledApplication -Bundle $Bundle -OwnerSid $OwnerSid
        Invoke-AcceptanceBootstrap -Bundle $Bundle -Action Uninstall
    } $Evidence
    Add-AcceptancePhase 'verify_native_install_clean_baseline' { Assert-AcceptanceRemoved $Bundle.Metadata.package_name $shared } $Evidence
    # A window-only smoke never qualifies the consumer Install path. Commit
    # these flags only after its actual action, independent Verify and cleanup.
    $Evidence.native_consumer_installation_verified = $true
    $Evidence.native_double_click_installer_acceptance = $true
}

function Get-AcceptanceOwnedBundle {
    param([object[]]$Bundles, [string]$OwnerSid)
    $packages = @(Get-AppxPackage -Name $Bundles[0].Metadata.package_name)
    if ($packages.Count -eq 0) { return $null }
    if ($packages.Count -ne 1) { throw 'Acceptance cleanup refuses ambiguous package ownership.' }
    $package = $packages[0]
    $matching = @($Bundles | Where-Object { $_.Metadata.package_name -ceq $package.Name -and
        $_.Metadata.publisher -ceq $package.Publisher -and [version]$_.Metadata.version -eq [version]$package.Version })
    if ($matching.Count -ne 1) { throw 'Acceptance cleanup refuses a package outside the verified releases.' }
    $bundle = $matching[0]
    $null = Assert-AcceptanceRegularPath -Path $package.InstallLocation -Directory
    foreach ($pair in @(@('Vex.Windows.App.exe', 'app_executable_sha256'), @('Vex.Windows.Service.exe', 'service_executable_sha256'))) {
        Assert-AcceptanceHash (Join-Path $package.InstallLocation $pair[0]) $bundle.Metadata.($pair[1])
        Assert-AcceptanceSignature (Join-Path $package.InstallLocation $pair[0]) $bundle.Metadata.client_certificate_sha256
    }
    $state = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'VEX\VPN'
    $serviceKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\VEX VPN Service'
    if (Test-Path -LiteralPath $state) {
        $null = Assert-AcceptanceRegularPath -Path $state -Directory
        $owner = Join-Path $state 'owner-sid'
        $null = Assert-AcceptanceRegularPath $owner
        if ([IO.File]::ReadAllText($owner).Trim() -cne $OwnerSid) { throw 'Acceptance cleanup refuses another service owner.' }
    }
    if (Test-Path -LiteralPath $serviceKey) {
        $configuration = Get-ItemProperty -LiteralPath $serviceKey
        $expectedImage = '"' + (Join-Path $package.InstallLocation 'Vex.Windows.Service.exe') + '"'
        if ($configuration.ImagePath -ine $expectedImage -or $configuration.ObjectName -ine 'LocalSystem' -or
            -not (Test-Path -LiteralPath $state)) { throw 'Acceptance cleanup refuses an unbound service.' }
    }
    # The signed uninstall performs the complete ACL, protected-pin and vendor
    # ownership checks itself. Never replace it with blanket sc/Remove-Item calls.
    return $bundle
}

function Invoke-AcceptanceOwnedCleanup {
    param([bool]$MutationStarted, [object[]]$Bundles, [string]$OwnerSid)
    if (-not $MutationStarted) { return }
    $bundle = Get-AcceptanceOwnedBundle -Bundles $Bundles -OwnerSid $OwnerSid
    if ($null -ne $bundle) {
        Stop-AcceptanceInstalledApplication -Bundle $bundle -OwnerSid $OwnerSid
        Invoke-AcceptanceBootstrap -Bundle $bundle -Action Uninstall
    }
}

function Get-AcceptanceSharedDependencies {
    @(Get-AppxPackage -AllUsers -Name 'Microsoft.VCLibs.140.00.UWPDesktop' | Sort-Object PackageFullName |
        Select-Object -ExpandProperty PackageFullName)
}

function Stop-AcceptanceInstalledApplication {
    param($Bundle, [string]$OwnerSid)
    $processes = @(Get-Process -Name 'Vex.Windows.App' -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) { return }
    $packages = @(Get-AppxPackage -Name $Bundle.Metadata.package_name)
    if ($packages.Count -ne 1) { throw 'Acceptance app cleanup requires an owned registered package.' }
    $image = Join-Path $packages[0].InstallLocation 'Vex.Windows.App.exe'
    foreach ($process in $processes) {
        try {
            if ($process.MainModule.FileName -ine $image) { throw 'Acceptance refuses to stop an unrelated app image.' }
            Assert-AcceptanceHash $image $Bundle.Metadata.app_executable_sha256
            Assert-AcceptanceSignature $image $Bundle.Metadata.client_certificate_sha256
            $native = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId='+$process.Id)
            $owner = Invoke-CimMethod -InputObject $native -MethodName GetOwnerSid
            if ($owner.ReturnValue -ne 0 -or $owner.Sid -cne $OwnerSid) { throw 'Acceptance refuses to stop another user application.' }
            if (-not $process.HasExited) {
                $process.Kill()
                if (-not $process.WaitForExit(5000)) { throw 'Acceptance app shutdown was not confirmed.' }
            }
        }
        finally { $process.Dispose() }
    }
}

function Assert-AcceptanceRemoved {
    param([string]$PackageName, [string[]]$SharedDependencies)
    if (@(Get-AppxPackage -AllUsers -Name $PackageName).Count -or
        @(Get-Service -Name 'VEX VPN Service', 'AmneziaWGTunnel$vex' -ErrorAction SilentlyContinue).Count -or
        (Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'VEX\VPN')) -or
        @(Get-NetAdapter -IncludeHidden | Where-Object { $_.Name -ieq 'vex' -or $_.InterfaceDescription -match '(?i)wintun|amnezia' }).Count) {
        throw 'Acceptance uninstall left a package, service, state or vendor adapter.'
    }
    $pins = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\VEX\VPN' -ErrorAction SilentlyContinue
    if ($null -ne $pins -and (@('ClientCertificateSha256', 'ServiceExecutableSha256') |
        Where-Object { $_ -in $pins.PSObject.Properties.Name }).Count) { throw 'Acceptance uninstall left machine attestation pins.' }
    $remaining = @(Get-AcceptanceSharedDependencies)
    if (@($SharedDependencies | Where-Object { $_ -notin $remaining }).Count) {
        throw 'Acceptance uninstall removed a shared Microsoft dependency.'
    }
}

function Invoke-AcceptanceInstalledUi {
    param($Bundle)
    $package = @(Get-AppxPackage -Name $Bundle.Metadata.package_name)
    if ($package.Count -ne 1 -or [version]$package[0].Version -ne [version]$Bundle.Metadata.version) {
        throw 'Acceptance UI requires the verified installed candidate.'
    }
    $payload = [pscustomobject]@{
        family = $package[0].PackageFamilyName
        executable = Join-Path $package[0].InstallLocation 'Vex.Windows.App.exe'
        sha256 = $Bundle.Metadata.app_executable_sha256
    } | ConvertTo-Json -Compress
    $encodedPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $probe = @'
$ErrorActionPreference = 'Stop'
$inputValue = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__')) | ConvertFrom-Json
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$owned = $null
function Find-Element([string]$id) {
    $condition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
    return $script:window.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
}
try {
    $existing = @(Get-Process -Name 'Vex.Windows.App' -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 1) { throw 'Application ownership is ambiguous.' }
    if ($existing.Count -eq 0) {
        $null = Start-Process -FilePath (Join-Path ([Environment]::GetFolderPath('Windows')) 'explorer.exe') -ArgumentList ('shell:AppsFolder\'+$inputValue.family+'!VexWindowsApp')
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    do {
        $processes = @(Get-Process -Name 'Vex.Windows.App' -ErrorAction SilentlyContinue)
        if ($processes.Count -gt 1) { throw 'Application ownership is ambiguous.' }
        if ($processes.Count -eq 1) {
            $candidate = $processes[0]
            if ($candidate.MainModule.FileName -ine $inputValue.executable -or
                (Get-FileHash -LiteralPath $candidate.MainModule.FileName -Algorithm SHA256).Hash -ine $inputValue.sha256) { throw 'Unexpected application image.' }
            $owned = $candidate
            if ($owned.MainWindowHandle -ne [IntPtr]::Zero) { break }
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($null -eq $owned -or $owned.MainWindowHandle -eq [IntPtr]::Zero) { throw 'Installed application created no window.' }
    $script:window = [Windows.Automation.AutomationElement]::FromHandle($owned.MainWindowHandle)
    # Fresh Release Home resolves to AccountPage until a real session exists.
    # Wait for the real signed-out controls; do not invoke any auth action.
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        $signIn = Find-Element 'WebsiteSignInButton'
        $title = Find-Element 'AccountSignInTitle'
        $settings = Find-Element 'SettingsNavigationButton'
        if ($null -ne $signIn -and $signIn.Current.IsEnabled -and -not $signIn.Current.IsOffscreen -and
            $null -ne $title -and $null -ne $settings) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($null -eq $signIn -or -not $signIn.Current.IsEnabled -or $signIn.Current.IsOffscreen -or
        $null -eq $title -or $null -eq $settings) { throw 'Installed signed-out status is missing.' }
    ([Windows.Automation.InvokePattern]$settings.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)).Invoke()
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $toggle = Find-Element 'AutoLaunchToggle'
        if ($null -ne $toggle -and $toggle.Current.IsEnabled) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($null -eq $toggle -or -not $toggle.Current.IsEnabled) { throw 'Installed Settings is unavailable.' }
    # Read only: do not sign in, enable startup, request a VPN profile or connect.
}
finally {
    if ($null -ne $owned) {
        try { if (-not $owned.HasExited) { $owned.Kill(); [void]$owned.WaitForExit(5000) } }
        finally { $owned.Dispose() }
    }
}
'@
    $probe = $probe.Replace('__PAYLOAD__', $encodedPayload)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
    Invoke-AcceptanceProcess -Executable (Get-AcceptanceSystemPowerShellPath) -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -TimeoutSeconds 75
}

function Add-AcceptancePhase {
    param([string]$Name, [scriptblock]$Operation, $Evidence)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $Operation | Out-Null
        $Evidence.phases.Add([ordered]@{ phase = $Name; passed = $true; duration_ms = $watch.ElapsedMilliseconds })
    }
    catch {
        $Evidence.phases.Add([ordered]@{ phase = $Name; passed = $false; duration_ms = $watch.ElapsedMilliseconds; failure_type = $_.Exception.GetType().Name })
        throw
    }
}

Assert-AcceptanceRunner ([bool]$DisposableRunner)
$ResultPath = [IO.Path]::GetFullPath($ResultPath)
$candidate = $null; $preceding = $null; $mutationStarted = $false; $failure = $null; $cleanupFailure = $null
$privateDirectory = $null; $fixtureId = [Guid]::NewGuid().ToString('N')
$ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$shared = @()
$evidence = [ordered]@{
    schema = 'vex.windows-signed-install-acceptance.v1'
    fixture_source_commit = $(if ($env:GITHUB_SHA -match '^[a-fA-F0-9]{40}$') { $env:GITHUB_SHA } else { $null })
    disposable_hosted_windows_x64 = $true
    preceding_provenance = $(if ($PrecedingIsSynthetic) { 'synthetic_version_from_candidate_source' } else { 'provided_signed_bundle' })
    candidate = $null; preceding = $null
    phases = [Collections.Generic.List[object]]::new()
    cleanup_confirmed = $false; installed_release_signed_out_ui = $false
    downloaded_bundle_preverification_guard = $false; native_double_click_installer_acceptance = $false
    native_setup = $null; native_setup_bundle_verification = $false
    native_setup_window_verified = $false; native_consumer_installation_verified = $false
    vclibs_absent_before_install = $false; clean_host_dependency_acceptance = $false
    real_authenticated_vpn_acceptance = $false; physical_arm64_acceptance = $false
    reboot_acceptance = $false; actual_previous_production_release_acceptance = $false
    passed = $false; failure_type = $null; cleanup_failure_type = $null
}
try {
    $candidate = Read-AcceptanceBundle $CandidateBundleDirectory
    $preceding = Read-AcceptanceBundle $PrecedingBundleDirectory
    Assert-AcceptanceBundlePair $candidate $preceding
    Assert-AcceptanceFreshHost $candidate.Metadata.package_name
    $evidence.vclibs_absent_before_install = (@(Get-AcceptanceSharedDependencies).Count -eq 0)
    $privateDirectory = New-AcceptancePrivateDirectory $fixtureId
    $candidate = Copy-AcceptanceDownloadedBundle $candidate (Join-Path $privateDirectory 'candidate')
    $preceding = Copy-AcceptanceDownloadedBundle $preceding (Join-Path $privateDirectory 'preceding')
    Assert-AcceptanceBundlePair $candidate $preceding
    $evidence.downloaded_bundle_preverification_guard = $true
    foreach ($entry in @(@('candidate', $candidate), @('preceding', $preceding))) {
        $m = $entry[1].Metadata
        $evidence[$entry[0]] = [ordered]@{ version = $m.version; package_name = $m.package_name; publisher = $m.publisher
            package_sha256 = $m.package_sha256; bootstrap_sha256 = $m.bootstrap_sha256
            certificate_sha256 = $m.client_certificate_sha256; app_sha256 = $m.app_executable_sha256; service_sha256 = $m.service_executable_sha256 }
    }
    Add-AcceptancePhase 'native_setup_verify_downloaded_bundle' {
        $evidence.native_setup = Invoke-AcceptanceNativeVerification -Bundle $candidate -PrivateDirectory $privateDirectory
    } $evidence
    $evidence.native_setup_bundle_verification = $true
    $mutationStarted = $true
    Invoke-AcceptanceNativeInstall -Bundle $candidate -OwnerSid $ownerSid -Evidence $evidence
    Add-AcceptancePhase 'install_preceding' { Invoke-AcceptanceBootstrap $preceding Install } $evidence
    Add-AcceptancePhase 'verify_preceding' { Invoke-AcceptanceBootstrap $preceding Verify } $evidence
    Add-AcceptancePhase 'install_candidate' { Invoke-AcceptanceBootstrap $candidate Install } $evidence
    Add-AcceptancePhase 'verify_candidate' { Invoke-AcceptanceBootstrap $candidate Verify } $evidence
    Add-AcceptancePhase 'repair_candidate' { Invoke-AcceptanceBootstrap $candidate Repair } $evidence
    Add-AcceptancePhase 'verify_repaired_candidate' { Invoke-AcceptanceBootstrap $candidate Verify } $evidence
    Add-AcceptancePhase 'rollback_to_preceding' { Invoke-AcceptanceBootstrap $candidate Rollback $preceding } $evidence
    Add-AcceptancePhase 'verify_rollback_preceding' { Invoke-AcceptanceBootstrap $preceding Verify } $evidence
    Add-AcceptancePhase 'reinstall_candidate' { Invoke-AcceptanceBootstrap $candidate Install } $evidence
    Add-AcceptancePhase 'verify_reinstalled_candidate' { Invoke-AcceptanceBootstrap $candidate Verify } $evidence
    Add-AcceptancePhase 'installed_release_signed_out_ui' { Invoke-AcceptanceInstalledUi $candidate } $evidence
    $evidence.installed_release_signed_out_ui = $true
    $shared = @(Get-AcceptanceSharedDependencies)
    if ($shared.Count -eq 0) { throw 'Candidate installation did not register its required Microsoft framework.' }
    Add-AcceptancePhase 'uninstall_candidate' { Invoke-AcceptanceBootstrap $candidate Uninstall } $evidence
    Add-AcceptancePhase 'verify_uninstalled_and_shared_dependencies' { Assert-AcceptanceRemoved $candidate.Metadata.package_name $shared } $evidence
    $evidence.clean_host_dependency_acceptance = $evidence.vclibs_absent_before_install
    $evidence.passed = $true
}
catch { $failure = $_; $evidence.failure_type = $_.Exception.GetType().Name }
finally {
    try {
        if ($mutationStarted) {
            Invoke-AcceptanceOwnedCleanup -MutationStarted $true -Bundles @($candidate, $preceding) -OwnerSid $ownerSid
            if ($shared.Count -eq 0) { $shared = @(Get-AcceptanceSharedDependencies) }
            Assert-AcceptanceRemoved $candidate.Metadata.package_name $shared
        }
        $evidence.cleanup_confirmed = $true
    }
    catch { $cleanupFailure = $_; $evidence.cleanup_failure_type = $_.Exception.GetType().Name; $evidence.passed = $false }
    try { Remove-AcceptancePrivateDirectory -Path $privateDirectory -FixtureId $fixtureId }
    catch { $cleanupFailure = $_; $evidence.cleanup_failure_type = $_.Exception.GetType().Name; $evidence.passed = $false }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ResultPath)) | Out-Null
    [IO.File]::WriteAllText($ResultPath, ($evidence | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}
if ($null -ne $failure -or $null -ne $cleanupFailure) {
    throw 'Signed install acceptance failed; inspect sanitized phase evidence.'
}
Write-Output 'Signed install acceptance passed; real authentication, physical ARM64 and reboot acceptance remain separate.'
