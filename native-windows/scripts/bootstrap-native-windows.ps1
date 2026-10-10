[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Install', 'Repair', 'Verify', 'Uninstall', 'Rollback', 'Prepare', 'Restore')]
    [string]$Action = 'Install',

    [string]$PackagePath,

    [string]$MetadataPath = $(Join-Path $PSScriptRoot 'package-metadata.json'),

    [string]$OwnerSid,

    [ValidateSet('User', 'Service')]
    [string]$Phase = 'User',

    [string]$InstallDirectory,

    [string]$RollbackPackagePath,

    [string]$RollbackMetadataPath,

    [switch]$RelaunchAfterInstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'VEX native Windows bootstrap requires elevation.'
    }
}

function Read-PackageMetadata {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Package metadata is missing: $Path"
    }

    $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($value.schema -ne 'vex.windows-package-output.v2') {
        throw "Unsupported package metadata schema in '$Path'."
    }

    foreach ($property in @(
        'install_entrypoint',
        'service_ownership',
        'package_name',
        'package_file',
        'package_sha256',
        'client_certificate_sha256',
        'app_executable_sha256',
        'service_executable_sha256',
        'amneziawg_sha256',
        'wintun_sha256',
        'profile_signing_keyring_sha256',
        'bootstrap_file',
        'bootstrap_sha256',
        'install_service_script_file',
        'install_service_script_sha256',
        'uninstall_service_script_file',
        'uninstall_service_script_sha256'
    )) {
        $text = [string]$value.$property
        if ([string]::IsNullOrWhiteSpace($text)) {
            throw "Package metadata field '$property' is missing."
        }
    }

    foreach ($booleanProperty in @(
        'raw_msix_provisions_service',
        'raw_appinstaller_provisions_service'
    )) {
        if ($booleanProperty -notin $value.PSObject.Properties.Name) {
            throw "Package metadata field '$booleanProperty' is missing."
        }
    }
    if ($value.install_entrypoint -ne 'elevated_bootstrap' -or
        $value.service_ownership -ne 'manual_sc_bootstrap' -or
        $value.raw_msix_provisions_service -ne $false -or
        $value.raw_appinstaller_provisions_service -ne $false) {
        throw 'Package metadata does not declare the manual elevated bootstrap service model.'
    }
    foreach ($fileProperty in @(
        'bootstrap_file',
        'install_service_script_file',
        'uninstall_service_script_file',
        'package_file'
    )) {
        $fileName = [string]$value.$fileProperty
        if ([IO.Path]::GetFileName($fileName) -ne $fileName) {
            throw "Package metadata field '$fileProperty' must be a file name."
        }
    }

    return $value
}

function Assert-Hash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description is missing: $Path"
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actual -ne $Expected.ToUpperInvariant()) {
        throw "$Description failed its release hash check."
    }
}

function Assert-ScriptSignature {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedCertificateSha256
    )

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "PowerShell Authenticode signature is invalid for '$Path'."
    }
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $actual = [BitConverter]::ToString(
            $sha256.ComputeHash($signature.SignerCertificate.RawData)
        ).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
    if ($actual -ne $ExpectedCertificateSha256.ToUpperInvariant()) {
        throw "PowerShell signer certificate is not pinned for '$Path'."
    }
}

function Resolve-OwnerSid {
    if (-not [string]::IsNullOrWhiteSpace($OwnerSid)) {
        return $OwnerSid
    }

    if ($Phase -eq 'Service') {
        throw 'The elevated service phase requires the original user OwnerSid.'
    }
    return Get-CurrentUserSid
}

function Get-CurrentUserSid {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($null -eq $identity.User) {
        throw 'The owning Windows user SID could not be resolved.'
    }
    return $identity.User.Value
}

function Assert-OriginalUserContext {
    if ($Phase -ne 'User' -or (Resolve-OwnerSid) -ne (Get-CurrentUserSid)) {
        throw 'MSIX registration and relaunch must run as the original owning Windows user.'
    }
}

function Get-InstalledPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$ServiceScope
    )

    $parameters = @{ Name = $Name; ErrorAction = 'Stop' }
    if ($ServiceScope) {
        $parameters.User = Resolve-OwnerSid
    }
    return Get-AppxPackage @parameters |
        Sort-Object Version -Descending |
        Select-Object -First 1
}

function Quote-NativeArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value.Contains('"') -or $Value.Contains([char]0) -or
        $Value.EndsWith('\')) {
        throw 'Bootstrap argument contains an unsafe native command-line character.'
    }
    return '"' + $Value + '"'
}

function Get-SystemPowerShellPath {
    return Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
}

function Invoke-ServicePhase {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceAction,
        [Parameter(Mandatory = $true)][string]$MetadataFile,
        [string]$ScriptsRoot = $PSScriptRoot,
        [string]$PackageInstallDirectory
    )
    Assert-OriginalUserContext
    $serviceMetadata = Read-PackageMetadata -Path $MetadataFile
    $bootstrap = Join-Path $ScriptsRoot ([string]$serviceMetadata.bootstrap_file)
    Assert-Hash -Path $bootstrap -Expected ([string]$serviceMetadata.bootstrap_sha256) -Description 'service bootstrap'
    Assert-ScriptSignature -Path $bootstrap -ExpectedCertificateSha256 ([string]$serviceMetadata.client_certificate_sha256)
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'AllSigned',
        '-File', $bootstrap, '-Phase', 'Service', '-Action', $ServiceAction,
        '-MetadataPath', $MetadataFile, '-OwnerSid', (Resolve-OwnerSid))
    if (-not [string]::IsNullOrWhiteSpace($PackageInstallDirectory)) {
        $arguments += @('-InstallDirectory', $PackageInstallDirectory)
    }
    $nativeArguments = ($arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' '
    $process = Start-Process -FilePath (Get-SystemPowerShellPath) `
        -ArgumentList $nativeArguments -Verb RunAs -PassThru
    try {
        if (-not $process.WaitForExit(180000)) {
            throw 'The elevated service operation did not finish within three minutes. Do not start another installation until it finishes.'
        }
        if ($process.ExitCode -ne 0) {
            throw "The elevated service operation '$ServiceAction' failed. Use the verified installer to repair VEX."
        }
    }
    finally { $process.Dispose() }
}

function Assert-ServiceOwnership {
    $dataDirectory = Get-VexDataDirectory
    Assert-NoReparsePath -Path $dataDirectory
    $ownerPath = Join-Path $dataDirectory 'owner-sid'
    if (Test-Path -LiteralPath $ownerPath -PathType Leaf) {
        $installedOwner = [IO.File]::ReadAllText($ownerPath).Trim()
        if ([string]::IsNullOrWhiteSpace($installedOwner) -or $installedOwner -ne (Resolve-OwnerSid)) {
            throw 'The installed VEX service belongs to another Windows user. Its authorization will not be reassigned.'
        }
    }
    else {
        $service = Get-Service -Name 'VEX VPN Service' -ErrorAction SilentlyContinue
        if ($null -ne $service) {
            $service.Dispose()
            throw 'The existing VEX service has no verified owner. Authorization will not be reassigned.'
        }
    }
}

function Get-VexDataDirectory {
    return Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'VEX\VPN'
}

function Assert-NoReparsePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $candidate = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrEmpty($candidate)) {
        if (Test-Path -LiteralPath $candidate) {
            $item = Get-Item -LiteralPath $candidate -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                ($null -ne $item.PSObject.Properties['LinkType'] -and $item.LinkType -eq 'HardLink')) {
                throw 'The VEX installation and state paths cannot contain links or reparse points.'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($candidate)
        if ($parent -eq $candidate) { break }
        $candidate = $parent
    }
}

function Assert-PrivateStateAcl {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$AllowInherited)
    Assert-NoReparsePath -Path $Path
    $acl = Get-Acl -LiteralPath $Path
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -notin @('S-1-5-18', 'S-1-5-32-544') -or (-not $AllowInherited -and -not $acl.AreAccessRulesProtected)) {
        throw 'VEX service state must have a trusted owner and protected access rules.'
    }
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    $expected = @{
        'S-1-5-18' = [long][Security.AccessControl.FileSystemRights]::FullControl
        'S-1-5-32-544' = [long][Security.AccessControl.FileSystemRights]::FullControl
    }
    $privateRoot = [IO.Path]::GetFullPath((Join-Path (Get-VexDataDirectory) 'Private')).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $private = $fullPath.Equals($privateRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($privateRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
    if (-not $private) {
        $expected[(Resolve-OwnerSid)] = [long]([Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [Security.AccessControl.FileSystemRights]::Synchronize)
    }
    if ($rules.Count -ne $expected.Count) { throw 'VEX service state has unexpected access rules.' }
    foreach ($rule in $rules) {
        $sid = $rule.IdentityReference.Value
        if (-not $expected.ContainsKey($sid) -or
            $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            [long]$rule.FileSystemRights -ne $expected[$sid]) {
            throw 'VEX service state has unexpected access rights.'
        }
        $expected.Remove($sid)
    }
    if ($expected.Count -ne 0) { throw 'VEX service state is missing required access rules.' }
}

function Assert-PrivateRuntimeState {
    $root = Join-Path (Get-VexDataDirectory) 'Private'
    Assert-NoReparsePath -Path $root
    if (-not (Test-Path -LiteralPath $root)) { return }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($root)
    $count = 0
    while ($pending.Count -gt 0) {
        $path = $pending.Pop()
        Assert-PrivateStateAcl -Path $path -AllowInherited:($path -ne $root)
        if (++$count -gt 10000) { throw 'The VEX private runtime state tree is unexpectedly large.' }
        $item = Get-Item -LiteralPath $path -Force
        if ($item.PSIsContainer) {
            foreach ($child in @(Get-ChildItem -LiteralPath $path -Force)) { $pending.Push($child.FullName) }
        }
    }
}

function Assert-ReleaseArtifacts {
    param([string]$Path, [string]$MetadataFile, [string]$ScriptsRoot)
    $release = Read-PackageMetadata -Path $MetadataFile
    Assert-Hash -Path $Path -Expected ([string]$release.package_sha256) -Description 'MSIX package'
    foreach ($pair in @(@('bootstrap_file', 'bootstrap_sha256'),
                         @('install_service_script_file', 'install_service_script_sha256'),
                         @('uninstall_service_script_file', 'uninstall_service_script_sha256'))) {
        $scriptPath = Join-Path $ScriptsRoot ([string]$release.($pair[0]))
        Assert-Hash -Path $scriptPath -Expected ([string]$release.($pair[1])) -Description 'release service script'
        Assert-ScriptSignature -Path $scriptPath -ExpectedCertificateSha256 ([string]$release.client_certificate_sha256)
    }
    return $release
}

function Stop-ServiceForPackageUpdate {
    $service = Get-Service -Name 'VEX VPN Service' -ErrorAction SilentlyContinue
    if ($null -eq $service) { return }
    try {
        if ($service.Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped) {
            Stop-Service -Name 'VEX VPN Service' -ErrorAction Stop
            $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(30))
        }
    }
    finally { $service.Dispose() }
}

function Invoke-ServiceAction {
    param([Parameter(Mandatory = $true)]$Metadata)
    Assert-Administrator
    if ([string]::IsNullOrWhiteSpace($OwnerSid)) { throw 'Original OwnerSid is required for service operations.' }
    if ($OwnerSid -notmatch '^S-1-(?:5-21|12-1)-(\d+-){3}\d+$') {
        throw 'Original OwnerSid must identify a local, domain or Azure AD Windows user.'
    }
    Assert-ServiceOwnership
    if ($Action -eq 'Prepare') {
        Stop-ServiceForPackageUpdate
        return
    }
    $package = Get-InstalledPackage -Name ([string]$Metadata.package_name) -ServiceScope
    if ($null -eq $package) { throw 'VEX is not registered for the original user.' }
    if ([string]::IsNullOrWhiteSpace($InstallDirectory) -or
        [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\') -ne [IO.Path]::GetFullPath($package.InstallLocation).TrimEnd('\')) {
        throw 'The service payload is not the package registered for the original user.'
    }
    switch ($Action) {
        { $_ -in @('Install', 'Repair') } {
            Invoke-ServiceProvisioning -Metadata $Metadata -InstallDirectory $package.InstallLocation
            Assert-InstalledState -Metadata $Metadata -InstallDirectory $package.InstallLocation
        }
        'Verify' { Assert-InstalledState -Metadata $Metadata -InstallDirectory $package.InstallLocation }
        'Restore' {
            # Registration failed before provisioning. Restore only the unchanged
            # original user's package, using its existing protected release pins.
            Assert-PrivateStateAcl -Path (Join-Path (Get-VexDataDirectory) 'bootstrap-state.json')
            $stored = Get-Content -LiteralPath (Join-Path (Get-VexDataDirectory) 'bootstrap-state.json') -Raw | ConvertFrom-Json
            Assert-InstalledState -Metadata $stored -InstallDirectory $package.InstallLocation -AllowStopped
            Start-Service -Name 'VEX VPN Service' -ErrorAction Stop
            $service = Get-Service -Name 'VEX VPN Service' -ErrorAction Stop
            try { $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(30)) }
            finally { $service.Dispose() }
            Assert-InstalledState -Metadata $stored -InstallDirectory $package.InstallLocation
        }
        'Uninstall' { Invoke-ServiceRemoval -Metadata $Metadata -InstallDirectory $package.InstallLocation }
        default { throw "Unsupported elevated service action '$Action'." }
    }
}

function Invoke-ServiceProvisioning {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$InstallDirectory,
        [string]$ScriptsRoot = $PSScriptRoot
    )

    $installer = Join-Path `
        $ScriptsRoot `
        ([string]$Metadata.install_service_script_file)
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
        throw "Service provisioning script is missing: $installer"
    }
    Assert-Hash `
        -Path $installer `
        -Expected ([string]$Metadata.install_service_script_sha256) `
        -Description 'service provisioning script'
    Assert-ScriptSignature `
        -Path $installer `
        -ExpectedCertificateSha256 ([string]$Metadata.client_certificate_sha256)

    & $installer `
        -InstallDirectory $InstallDirectory `
        -OwnerSid (Resolve-OwnerSid) `
        -ClientCertificateSha256 ([string]$Metadata.client_certificate_sha256) `
        -AppExecutableSha256 ([string]$Metadata.app_executable_sha256) `
        -ServiceExecutableSha256 ([string]$Metadata.service_executable_sha256) `
        -AmneziaExecutableSha256 ([string]$Metadata.amneziawg_sha256) `
        -WintunSha256 ([string]$Metadata.wintun_sha256) `
        -ProfileSigningKeyringSha256 ([string]$Metadata.profile_signing_keyring_sha256)
}

function Install-Package {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$MetadataFile,
        [string]$ScriptsRoot = $PSScriptRoot,
        [switch]$ForceUpdate
    )

    Assert-OriginalUserContext
    if ($ForceUpdate -and $Action -ne 'Rollback') {
        throw 'Version downgrade is available only through the explicit Rollback action.'
    }
    $metadata = Assert-ReleaseArtifacts -Path $Path -MetadataFile $MetadataFile -ScriptsRoot $ScriptsRoot

    $previous = Get-InstalledPackage -Name ([string]$metadata.package_name)
    if ($null -ne $previous) {
        Invoke-ServicePhase -ServiceAction 'Prepare' -MetadataFile $MetadataFile -ScriptsRoot $ScriptsRoot
    }
    $parameters = @{
        Path = $Path
        ForceApplicationShutdown = $true
        ErrorAction = 'Stop'
    }
    if ($ForceUpdate) {
        $parameters.ForceUpdateFromAnyVersion = $true
    }
    try { Add-AppxPackage @parameters }
    catch {
        $registrationError = $_
        if ($null -ne $previous) {
            $remaining = Get-InstalledPackage -Name ([string]$metadata.package_name)
            if ($null -ne $remaining -and $remaining.PackageFullName -eq $previous.PackageFullName -and
                $remaining.InstallLocation -eq $previous.InstallLocation) {
                Invoke-ServicePhase -ServiceAction 'Restore' -MetadataFile $MetadataFile -ScriptsRoot $ScriptsRoot `
                    -PackageInstallDirectory $previous.InstallLocation
            }
        }
        throw $registrationError
    }

    $package = Get-InstalledPackage -Name ([string]$metadata.package_name)
    if ($null -eq $package) {
        throw 'The VEX MSIX package was not registered after installation.'
    }

    # Registration stays in the original user's token. An over-the-shoulder
    # administrator only provisions the pinned privileged service afterwards.
    # Keep the registered UI available if provisioning fails so it can offer
    # verified repair; never remove packages belonging to other users.
    Invoke-ServicePhase -ServiceAction 'Install' -MetadataFile $MetadataFile -ScriptsRoot $ScriptsRoot `
        -PackageInstallDirectory $package.InstallLocation
}

function Assert-InstalledState {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$InstallDirectory,
        [switch]$AllowStopped
    )

    foreach ($pin in @(
        @('Vex.Windows.App.exe', 'app_executable_sha256', 'client executable'),
        @('Vex.Windows.Service.exe', 'service_executable_sha256', 'service executable'),
        @('amneziawg.exe', 'amneziawg_sha256', 'AmneziaWG runtime'),
        @('wintun.dll', 'wintun_sha256', 'Wintun runtime'),
        @('profile-signing-keys.json', 'profile_signing_keyring_sha256', 'profile keyring')
    )) {
        Assert-NoReparsePath -Path (Join-Path $InstallDirectory $pin[0])
        Assert-Hash `
            -Path (Join-Path $InstallDirectory $pin[0]) `
            -Expected ([string]$Metadata.($pin[1])) `
            -Description $pin[2]
    }

    $dataDirectory = Get-VexDataDirectory
    Assert-PrivateStateAcl -Path (Split-Path -Parent $dataDirectory)
    Assert-PrivateStateAcl -Path $dataDirectory
    Assert-PrivateRuntimeState
    foreach ($file in @(
        'ipc-token.bin',
        'owner-sid',
        'client-cert-sha256',
        'app-executable-sha256',
        'service-executable-sha256',
        'amneziawg-sha256',
        'wintun-sha256',
        'profile-signing-keys-sha256',
        'bootstrap-state.json'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $dataDirectory $file) -PathType Leaf)) {
            throw "Provisioned service state is missing '$file'."
        }
        Assert-PrivateStateAcl -Path (Join-Path $dataDirectory $file)
    }

    foreach ($pin in @(@('owner-sid', (Resolve-OwnerSid)),
        @('client-cert-sha256', $Metadata.client_certificate_sha256),
        @('app-executable-sha256', $Metadata.app_executable_sha256),
        @('service-executable-sha256', $Metadata.service_executable_sha256),
        @('amneziawg-sha256', $Metadata.amneziawg_sha256),
        @('wintun-sha256', $Metadata.wintun_sha256),
        @('profile-signing-keys-sha256', $Metadata.profile_signing_keyring_sha256))) {
        if ([IO.File]::ReadAllText((Join-Path $dataDirectory $pin[0])).Trim() -ne [string]$pin[1]) {
            throw "Provisioned service pin '$($pin[0])' does not match the installed release."
        }
    }
    $stored = Get-Content -LiteralPath (Join-Path $dataDirectory 'bootstrap-state.json') -Raw | ConvertFrom-Json
    if ($stored.schema -ne 'vex.windows-service-bootstrap.v1' -or $stored.owner_sid -ne (Resolve-OwnerSid)) {
        throw 'The provisioned service bootstrap ownership is invalid.'
    }
    foreach ($field in @('client_certificate_sha256', 'app_executable_sha256', 'service_executable_sha256',
        'amneziawg_sha256', 'wintun_sha256', 'profile_signing_keyring_sha256')) {
        if ([string]$stored.$field -ne [string]$Metadata.$field) { throw "Provisioned bootstrap pin '$field' does not match the release." }
    }
    Assert-AuthorizationToken -Path (Join-Path $dataDirectory 'ipc-token.bin')
    Assert-ScriptSignature -Path (Join-Path $InstallDirectory 'Vex.Windows.App.exe') -ExpectedCertificateSha256 ([string]$Metadata.client_certificate_sha256)
    Assert-ScriptSignature -Path (Join-Path $InstallDirectory 'Vex.Windows.Service.exe') -ExpectedCertificateSha256 ([string]$Metadata.client_certificate_sha256)
    Assert-ServiceConfiguration -InstallDirectory $InstallDirectory
    $machinePins = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\VEX\VPN' -ErrorAction Stop
    if ($machinePins.ClientCertificateSha256 -ne $Metadata.client_certificate_sha256 -or
        $machinePins.ServiceExecutableSha256 -ne $Metadata.service_executable_sha256) {
        throw 'The machine service attestation pins do not match the release.'
    }

    $service = Get-Service -Name 'VEX VPN Service' -ErrorAction Stop
    try {
        if (-not $AllowStopped -and $service.Status -ne [ServiceProcess.ServiceControllerStatus]::Running) {
            throw 'VEX VPN Service is installed but is not running.'
        }
    }
    finally {
        $service.Dispose()
    }
}

function Assert-AuthorizationToken {
    param([Parameter(Mandatory = $true)][string]$Path)
    $protectedToken = [IO.File]::ReadAllBytes($Path)
    $token = [Security.Cryptography.ProtectedData]::Unprotect($protectedToken,
        [Text.Encoding]::UTF8.GetBytes('VEX VPN IPC v1'), [Security.Cryptography.DataProtectionScope]::LocalMachine)
    try { if ($token.Length -ne 32) { throw 'The service authorization token is invalid.' } }
    finally { [Array]::Clear($token, 0, $token.Length) }
}

function Assert-ServiceConfiguration {
    param([Parameter(Mandatory = $true)][string]$InstallDirectory)
    Assert-NoReparsePath -Path $InstallDirectory
    $configuration = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\VEX VPN Service' -ErrorAction Stop
    $binary = '"' + (Join-Path $InstallDirectory 'Vex.Windows.Service.exe') + '"'
    if ([string]$configuration.ImagePath -ne $binary -or $configuration.ObjectName -ne 'LocalSystem' -or
        $configuration.Start -ne 2 -or $configuration.DelayedAutoStart -ne 1 -or $configuration.Type -ne 16 -or
        $configuration.FailureActionsOnNonCrashFailures -ne 1) {
        throw 'The VEX service executable, account or startup configuration is invalid.'
    }
}

function Invoke-ServiceRemoval {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$InstallDirectory
    )
    $uninstaller = Join-Path `
        $PSScriptRoot `
        ([string]$Metadata.uninstall_service_script_file)
    Assert-Hash `
        -Path $uninstaller `
        -Expected ([string]$Metadata.uninstall_service_script_sha256) `
        -Description 'service removal script'
    Assert-ScriptSignature `
        -Path $uninstaller `
        -ExpectedCertificateSha256 ([string]$Metadata.client_certificate_sha256)
    & $uninstaller -InstallDirectory $InstallDirectory
}

function Uninstall-Package {
    param([Parameter(Mandatory = $true)]$Metadata)
    Assert-OriginalUserContext
    $package = Get-InstalledPackage -Name ([string]$Metadata.package_name)
    if ($null -eq $package) { return }
    Invoke-ServicePhase -ServiceAction 'Uninstall' -MetadataFile $MetadataPath `
        -PackageInstallDirectory $package.InstallLocation
    Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
}

function Start-PackagedClient {
    param([Parameter(Mandatory = $true)]$Metadata)
    Assert-OriginalUserContext
    $package = Get-InstalledPackage -Name ([string]$Metadata.package_name)
    if ($null -eq $package) {
        throw 'The VEX MSIX package is not installed for relaunch.'
    }

    $applicationTarget = 'shell:AppsFolder\{0}!VexWindowsApp' -f `
        $package.PackageFamilyName
    Start-Process `
        -FilePath (Join-Path $env:WINDIR 'explorer.exe') `
        -ArgumentList $applicationTarget
}

function Invoke-PackageRollback {
    if ([string]::IsNullOrWhiteSpace($RollbackPackagePath)) {
        throw 'RollbackPackagePath is required for rollback.'
    }
    if ([string]::IsNullOrWhiteSpace($RollbackMetadataPath)) {
        $RollbackMetadataPath = Join-Path `
            (Split-Path -Parent $RollbackPackagePath) `
            'package-metadata.json'
    }

    $currentMetadata = Read-PackageMetadata -Path $MetadataPath
    $rollbackRoot = Split-Path -Parent $RollbackMetadataPath
    $rollbackMetadata = Assert-ReleaseArtifacts -Path $RollbackPackagePath -MetadataFile $RollbackMetadataPath -ScriptsRoot $rollbackRoot
    if ($rollbackMetadata.package_name -ne $currentMetadata.package_name) {
        throw 'Rollback must replace the same VEX package identity.'
    }
    # ForceUpdateFromAnyVersion replaces the signed package in place. Removing
    # the current package first would lose working registration and user state.
    Install-Package `
        -Path $RollbackPackagePath `
        -MetadataFile $RollbackMetadataPath `
        -ScriptsRoot (Split-Path -Parent $RollbackMetadataPath) `
        -ForceUpdate
    if ($RelaunchAfterInstall) {
        $rollbackMetadata = Read-PackageMetadata -Path $RollbackMetadataPath
        Start-PackagedClient -Metadata $rollbackMetadata
    }
    Write-Host 'VEX native Windows rollback completed and verified.'
    return
}

if (-not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
    $bootstrapMetadata = Read-PackageMetadata -Path $MetadataPath
    Assert-Hash `
        -Path $MyInvocation.MyCommand.Path `
        -Expected ([string]$bootstrapMetadata.bootstrap_sha256) `
        -Description 'bootstrap script'
    Assert-ScriptSignature `
        -Path $MyInvocation.MyCommand.Path `
        -ExpectedCertificateSha256 `
            ([string]$bootstrapMetadata.client_certificate_sha256)
}

if ($Phase -eq 'Service') {
    $metadata = Read-PackageMetadata -Path $MetadataPath
    Invoke-ServiceAction -Metadata $metadata
    Write-Host "VEX elevated service action '$Action' completed and verified."
    return
}

Assert-OriginalUserContext
$OwnerSid = Resolve-OwnerSid

if ($Action -eq 'Rollback') {
    Invoke-PackageRollback
    return
}

$metadata = Read-PackageMetadata -Path $MetadataPath
if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $PackagePath = Join-Path `
        (Split-Path -Parent $MetadataPath) `
        ([string]$metadata.package_file)
}
switch ($Action) {
    'Install' {
        Install-Package -Path $PackagePath -MetadataFile $MetadataPath
        if ($RelaunchAfterInstall) {
            Start-PackagedClient -Metadata $metadata
        }
    }
    'Repair' {
        $package = Get-InstalledPackage -Name ([string]$metadata.package_name)
        if ($null -eq $package) {
            Install-Package -Path $PackagePath -MetadataFile $MetadataPath
        }
        else {
            Invoke-ServicePhase -ServiceAction 'Repair' -MetadataFile $MetadataPath `
                -PackageInstallDirectory $package.InstallLocation
        }
    }
    'Verify' {
        $package = Get-InstalledPackage -Name ([string]$metadata.package_name)
        if ($null -eq $package) {
            throw 'The VEX MSIX package is not installed.'
        }
        Invoke-ServicePhase -ServiceAction 'Verify' -MetadataFile $MetadataPath `
            -PackageInstallDirectory $package.InstallLocation
    }
    'Uninstall' {
        Uninstall-Package -Metadata $metadata
    }
    default { throw "Unsupported user bootstrap action '$Action'." }
}

Write-Host "VEX native Windows bootstrap action '$Action' completed and verified."
