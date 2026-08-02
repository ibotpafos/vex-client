[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Install', 'Repair', 'Verify', 'Uninstall', 'Rollback')]
    [string]$Action = 'Install',

    [string]$PackagePath,

    [string]$MetadataPath = $(Join-Path $PSScriptRoot 'package-metadata.json'),

    [string]$OwnerSid,

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

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($null -eq $identity.User) {
        throw 'The owning Windows user SID could not be resolved.'
    }

    return $identity.User.Value
}

function Get-InstalledPackage {
    param([Parameter(Mandatory = $true)][string]$Name)

    return Get-AppxPackage -Name $Name -AllUsers |
        Sort-Object Version -Descending |
        Select-Object -First 1
}

function Invoke-ServiceProvisioning {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$InstallDirectory,
        [Parameter(Mandatory = $true)][string]$ScriptsRoot
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

    $metadata = Read-PackageMetadata -Path $MetadataFile
    Assert-Hash `
        -Path $Path `
        -Expected ([string]$metadata.package_sha256) `
        -Description 'MSIX package'

    $parameters = @{
        Path = $Path
        ForceApplicationShutdown = $true
        ErrorAction = 'Stop'
    }
    if ($ForceUpdate) {
        $parameters.ForceUpdateFromAnyVersion = $true
    }
    Add-AppxPackage @parameters

    $package = Get-InstalledPackage -Name ([string]$metadata.package_name)
    if ($null -eq $package) {
        throw 'The VEX MSIX package was not registered after installation.'
    }

    try {
        Invoke-ServiceProvisioning `
            -Metadata $metadata `
            -InstallDirectory $package.InstallLocation `
            -ScriptsRoot $ScriptsRoot
        Assert-InstalledState `
            -Metadata $metadata `
            -InstallDirectory $package.InstallLocation
    }
    catch {
        Remove-AppxPackage `
            -Package $package.PackageFullName `
            -AllUsers `
            -ErrorAction SilentlyContinue
        throw
    }
}

function Assert-InstalledState {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$InstallDirectory
    )

    foreach ($pin in @(
        @('Vex.Windows.App.exe', 'app_executable_sha256', 'client executable'),
        @('Vex.Windows.Service.exe', 'service_executable_sha256', 'service executable'),
        @('amneziawg.exe', 'amneziawg_sha256', 'AmneziaWG runtime'),
        @('wintun.dll', 'wintun_sha256', 'Wintun runtime'),
        @('profile-signing-keys.json', 'profile_signing_keyring_sha256', 'profile keyring')
    )) {
        Assert-Hash `
            -Path (Join-Path $InstallDirectory $pin[0]) `
            -Expected ([string]$Metadata.($pin[1])) `
            -Description $pin[2]
    }

    $dataDirectory = Join-Path $env:ProgramData 'VEX\VPN'
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
    }

    $service = Get-Service -Name 'VEX VPN Service' -ErrorAction Stop
    try {
        if ($service.Status -ne [ServiceProcess.ServiceControllerStatus]::Running) {
            throw 'VEX VPN Service is installed but is not running.'
        }
    }
    finally {
        $service.Dispose()
    }
}

function Uninstall-Package {
    param([Parameter(Mandatory = $true)]$Metadata)

    $package = Get-InstalledPackage -Name ([string]$Metadata.package_name)
    if ($null -eq $package) {
        return
    }

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
    & $uninstaller -InstallDirectory $package.InstallLocation
    Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
}

function Start-PackagedClient {
    param([Parameter(Mandatory = $true)]$Metadata)

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

Assert-Administrator
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

if ($Action -eq 'Rollback') {
    if ([string]::IsNullOrWhiteSpace($RollbackPackagePath)) {
        throw 'RollbackPackagePath is required for rollback.'
    }
    if ([string]::IsNullOrWhiteSpace($RollbackMetadataPath)) {
        $RollbackMetadataPath = Join-Path `
            (Split-Path -Parent $RollbackPackagePath) `
            'package-metadata.json'
    }

    $currentMetadata = Read-PackageMetadata -Path $MetadataPath
    Uninstall-Package -Metadata $currentMetadata
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
            Invoke-ServiceProvisioning `
                -Metadata $metadata `
                -InstallDirectory $package.InstallLocation `
                -ScriptsRoot $PSScriptRoot
            Assert-InstalledState `
                -Metadata $metadata `
                -InstallDirectory $package.InstallLocation
        }
    }
    'Verify' {
        $package = Get-InstalledPackage -Name ([string]$metadata.package_name)
        if ($null -eq $package) {
            throw 'The VEX MSIX package is not installed.'
        }
        Assert-InstalledState `
            -Metadata $metadata `
            -InstallDirectory $package.InstallLocation
    }
    'Uninstall' {
        Uninstall-Package -Metadata $metadata
    }
}

Write-Host "VEX native Windows bootstrap action '$Action' completed and verified."
