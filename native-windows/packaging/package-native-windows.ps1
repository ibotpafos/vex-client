[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture,

    [string]$Configuration = 'Release',

    [string]$Channel = $(if ($env:VEX_WINDOWS_RELEASE_CHANNEL) { $env:VEX_WINDOWS_RELEASE_CHANNEL } else { 'stable' }),

    [string]$Version = $env:VEX_WINDOWS_RELEASE_VERSION,

    [string]$OutputRoot = $(Join-Path $PSScriptRoot 'out')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-RequiredEnv {
    param([Parameter(Mandatory = $true)][string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Required environment variable '$Name' is missing."
    }

    return $value.Trim()
}

function Resolve-WindowsSdkTool {
    param([Parameter(Mandatory = $true)][string]$ToolName)

    $kitRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    if (-not (Test-Path -LiteralPath $kitRoot -PathType Container)) {
        throw 'Windows SDK is not installed. Expected Windows Kits\10\bin.'
    }

    $candidate = Get-ChildItem -LiteralPath $kitRoot -Directory |
        Sort-Object Name -Descending |
        ForEach-Object {
            $path = Join-Path $_.FullName "x64\$ToolName"
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                return $path
            }
        } |
        Select-Object -First 1

    if (-not $candidate) {
        throw "Unable to locate '$ToolName' inside the Windows SDK."
    }

    return $candidate
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Ensure-TrailingSlash {
    param([Parameter(Mandatory = $true)][string]$Value)

    return $Value.TrimEnd('/') + '/'
}

function Normalize-Version {
    param([Parameter(Mandatory = $true)][string]$Value)

    $parts = $Value.Trim().Split('.', [StringSplitOptions]::RemoveEmptyEntries)
    if ($parts.Count -lt 2 -or $parts.Count -gt 4) {
        throw "Windows package version '$Value' must have 2-4 numeric parts."
    }

    foreach ($part in $parts) {
        $parsed = 0
        if (-not [int]::TryParse($part, [ref]$parsed)) {
            throw "Windows package version '$Value' must be numeric."
        }
    }

    if ($parts.Count -eq 2) {
        return "$($parts[0]).$($parts[1]).0.0"
    }
    if ($parts.Count -eq 3) {
        return "$($parts[0]).$($parts[1]).$($parts[2]).0"
    }

    return ($parts -join '.')
}

function ConvertTo-HexSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Import-PfxFromBase64 {
    param(
        [Parameter(Mandatory = $true)][string]$Base64,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $pfxBytes = [Convert]::FromBase64String($Base64)
    try {
        [IO.File]::WriteAllBytes(
            $DestinationPath,
            $pfxBytes)
    }
    finally {
        [Array]::Clear($pfxBytes, 0, $pfxBytes.Length)
    }
}

function Get-PfxCertificateSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Password
    )

    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $Path,
        $Password,
        [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString(
            $sha256.ComputeHash($certificate.RawData)
        ).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
        $certificate.Dispose()
    }
}

function Invoke-SignTool {
    param(
        [Parameter(Mandatory = $true)][string]$SignTool,
        [Parameter(Mandatory = $true)][string]$PfxPath,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$Path
    )

    & $SignTool sign /fd SHA256 /f $PfxPath /p $Password $Path
    if ($LASTEXITCODE -ne 0) {
        throw "signtool failed for '$Path'."
    }
}

function New-UpdateKeyringJson {
    param(
        [Parameter(Mandatory = $true)][string]$KeyId,
        [Parameter(Mandatory = $true)][string]$SpkiBase64
    )

    $payload = [ordered]@{
        schema = 'vex.windows-update-keyring.v1'
        keys = @(
            [ordered]@{
                key_id = $KeyId
                algorithm = 'ECDSA_P256_SHA256_DER'
                subject_public_key_info_base64 = $SpkiBase64
            }
        )
    }

    return ($payload | ConvertTo-Json -Depth 6)
}

$packageName = Get-RequiredEnv 'VEX_WINDOWS_PACKAGE_NAME'
$displayName = Get-RequiredEnv 'VEX_WINDOWS_PACKAGE_DISPLAY_NAME'
$publisher = Get-RequiredEnv 'VEX_WINDOWS_PACKAGE_PUBLISHER'
$publisherDisplayName = Get-RequiredEnv 'VEX_WINDOWS_PACKAGE_PUBLISHER_DISPLAY_NAME'
$pfxBase64 = Get-RequiredEnv 'VEX_WINDOWS_SIGN_PFX_BASE64'
$pfxPassword = Get-RequiredEnv 'VEX_WINDOWS_SIGN_PFX_PASSWORD'
$updateKeyId = Get-RequiredEnv 'VEX_WINDOWS_UPDATE_KEY_ID'
$updatePublicKeyBase64 = Get-RequiredEnv 'VEX_WINDOWS_UPDATE_PUBLIC_KEY_BASE64'
$amneziaExecutablePath = Get-RequiredEnv 'VEX_WINDOWS_SERVICE_AMNEZIAWG_PATH'
$wintunLibraryPath = Get-RequiredEnv 'VEX_WINDOWS_SERVICE_WINTUN_PATH'
$profileSigningKeyringPath = if ($env:VEX_WINDOWS_SERVICE_PROFILE_KEYRING_PATH) {
    $env:VEX_WINDOWS_SERVICE_PROFILE_KEYRING_PATH.Trim()
}
else {
    Join-Path $PSScriptRoot 'profile-signing-keys.json'
}
$packageBaseUri = Ensure-TrailingSlash (Get-RequiredEnv 'VEX_WINDOWS_PACKAGE_BASE_URI')
$appInstallerBaseUri = Ensure-TrailingSlash (Get-RequiredEnv 'VEX_WINDOWS_APPINSTALLER_BASE_URI')

if ([string]::IsNullOrWhiteSpace($Version)) {
    throw "VEX_WINDOWS_RELEASE_VERSION is required."
}

$normalizedVersion = Normalize-Version $Version
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$publishRoot = Join-Path $OutputRoot "$Channel\$Architecture\$normalizedVersion"
$publishDir = Join-Path $publishRoot 'publish'
$servicePublishDir = Join-Path $publishRoot 'publish-service'
$packageDir = Join-Path $publishRoot 'package'
$assetsDir = Join-Path $packageDir 'Assets'
$msixPath = Join-Path $publishRoot "VEX.Native.$Channel.$Architecture.$normalizedVersion.msix"
$appInstallerPath = Join-Path $publishRoot "VEX.Native.$Channel.$Architecture.appinstaller"
$metadataPath = Join-Path $publishRoot 'package-metadata.json'
$manifestTemplatePath = Join-Path $PSScriptRoot 'AppxManifest.xml.template'
$appInstallerTemplatePath = Join-Path $PSScriptRoot 'AppInstaller.template.xml'
$signtool = Resolve-WindowsSdkTool 'signtool.exe'
$makeappx = Resolve-WindowsSdkTool 'makeappx.exe'
$temporaryPfxPath = Join-Path $publishRoot 'codesign.pfx'
$bootstrapScriptPath = Join-Path $publishRoot 'bootstrap-native-windows.ps1'
$installServiceScriptPath = Join-Path $publishRoot 'install-vpn-service.ps1'
$uninstallServiceScriptPath = Join-Path $publishRoot 'uninstall-vpn-service.ps1'

New-Item -ItemType Directory -Path $publishDir -Force | Out-Null
New-Item -ItemType Directory -Path $servicePublishDir -Force | Out-Null
New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null

dotnet publish `
    (Join-Path $root 'native-windows\src\Vex.Windows.App\Vex.Windows.App.csproj') `
    -c $Configuration `
    -r "win-$Architecture" `
    -p:EnableWindowsTargeting=true `
    -p:Version=$normalizedVersion `
    -p:AssemblyVersion=$normalizedVersion `
    -p:FileVersion=$normalizedVersion `
    -p:InformationalVersion=$Version `
    -o $publishDir

dotnet publish `
    (Join-Path $root 'native-windows\src\Vex.Windows.Service\Vex.Windows.Service.csproj') `
    -c $Configuration `
    -r "win-$Architecture" `
    -p:EnableWindowsTargeting=true `
    -p:Version=$normalizedVersion `
    -p:AssemblyVersion=$normalizedVersion `
    -p:FileVersion=$normalizedVersion `
    -p:InformationalVersion=$Version `
    -o $servicePublishDir

Copy-Item -Path (Join-Path $publishDir '*') -Destination $packageDir -Recurse -Force
Copy-Item -Path (Join-Path $servicePublishDir '*') -Destination $packageDir -Recurse -Force

foreach ($requiredAsset in @(
    $amneziaExecutablePath,
    $wintunLibraryPath,
    $profileSigningKeyringPath
)) {
    if (-not (Test-Path -LiteralPath $requiredAsset -PathType Leaf)) {
        throw "Required packaged service asset is missing: $requiredAsset"
    }
}

Copy-Item -LiteralPath $amneziaExecutablePath -Destination (Join-Path $packageDir 'amneziawg.exe') -Force
Copy-Item -LiteralPath $wintunLibraryPath -Destination (Join-Path $packageDir 'wintun.dll') -Force
Copy-Item -LiteralPath $profileSigningKeyringPath -Destination (Join-Path $packageDir 'profile-signing-keys.json') -Force

$iconMap = @{
    'StoreLogo.png' = 'vex-app-icon-source.png'
    'Square150x150Logo.png' = 'vex-app-icon-source.png'
    'Square44x44Logo.png' = 'vex-app-icon-source.png'
}
foreach ($targetName in $iconMap.Keys) {
    $sourcePath = Join-Path $root "native-windows\src\Vex.Windows.App\Assets\$($iconMap[$targetName])"
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Required packaging asset is missing: $sourcePath"
    }

    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $assetsDir $targetName) -Force
}

$keyringPath = Join-Path $packageDir 'update-signing-keyring.json'
Write-Utf8NoBom `
    -Path $keyringPath `
    -Content (New-UpdateKeyringJson -KeyId $updateKeyId -SpkiBase64 $updatePublicKeyBase64)

$clientExecutable = Join-Path $packageDir 'Vex.Windows.App.exe'
$serviceExecutable = Join-Path $packageDir 'Vex.Windows.Service.exe'
Import-PfxFromBase64 -Base64 $pfxBase64 -DestinationPath $temporaryPfxPath
try {
    $clientCertificateSha256 = Get-PfxCertificateSha256 `
        -Path $temporaryPfxPath `
        -Password $pfxPassword
    Invoke-SignTool `
        -SignTool $signtool `
        -PfxPath $temporaryPfxPath `
        -Password $pfxPassword `
        -Path $clientExecutable
    Invoke-SignTool `
        -SignTool $signtool `
        -PfxPath $temporaryPfxPath `
        -Password $pfxPassword `
        -Path $serviceExecutable
}
finally {
    if (Test-Path -LiteralPath $temporaryPfxPath -PathType Leaf) {
        Remove-Item -LiteralPath $temporaryPfxPath -Force
    }
}

$appExecutableSha256 = ConvertTo-HexSha256 $clientExecutable
$serviceExecutableSha256 = ConvertTo-HexSha256 $serviceExecutable
$amneziaExecutableSha256 = ConvertTo-HexSha256 `
    (Join-Path $packageDir 'amneziawg.exe')
$wintunSha256 = ConvertTo-HexSha256 (Join-Path $packageDir 'wintun.dll')
$profileSigningKeyringSha256 = ConvertTo-HexSha256 `
    (Join-Path $packageDir 'profile-signing-keys.json')

$manifestTemplate = Get-Content -LiteralPath $manifestTemplatePath -Raw
$manifestContent = $manifestTemplate.
    Replace('__PACKAGE_NAME__', $packageName).
    Replace('__PACKAGE_VERSION__', $normalizedVersion).
    Replace('__PUBLISHER__', $publisher).
    Replace('__ARCHITECTURE__', $Architecture).
    Replace('__DISPLAY_NAME__', $displayName).
    Replace('__PUBLISHER_DISPLAY_NAME__', $publisherDisplayName)

$appxManifestPath = Join-Path $packageDir 'AppxManifest.xml'
Write-Utf8NoBom -Path $appxManifestPath -Content $manifestContent

if (Test-Path -LiteralPath $msixPath -PathType Leaf) {
    Remove-Item -LiteralPath $msixPath -Force
}

& $makeappx pack /d $packageDir /p $msixPath /h SHA256 /o
if ($LASTEXITCODE -ne 0) {
    throw 'makeappx failed.'
}

Import-PfxFromBase64 -Base64 $pfxBase64 -DestinationPath $temporaryPfxPath
try {
    Invoke-SignTool `
        -SignTool $signtool `
        -PfxPath $temporaryPfxPath `
        -Password $pfxPassword `
        -Path $msixPath
}
finally {
    if (Test-Path -LiteralPath $temporaryPfxPath -PathType Leaf) {
        Remove-Item -LiteralPath $temporaryPfxPath -Force
    }
}

$packageUri = [Uri]::new($packageBaseUri + [IO.Path]::GetFileName($msixPath)).AbsoluteUri
$appInstallerUri = [Uri]::new($appInstallerBaseUri + [IO.Path]::GetFileName($appInstallerPath)).AbsoluteUri
$appInstallerTemplate = Get-Content -LiteralPath $appInstallerTemplatePath -Raw
$appInstallerContent = $appInstallerTemplate.
    Replace('__APPINSTALLER_VERSION__', $normalizedVersion).
    Replace('__APPINSTALLER_URI__', $appInstallerUri).
    Replace('__PACKAGE_NAME__', $packageName).
    Replace('__PUBLISHER__', $publisher).
    Replace('__PACKAGE_VERSION__', $normalizedVersion).
    Replace('__ARCHITECTURE__', $Architecture).
    Replace('__PACKAGE_URI__', $packageUri)
Write-Utf8NoBom -Path $appInstallerPath -Content $appInstallerContent

$scriptsRoot = Join-Path $root 'native-windows\scripts'
Copy-Item `
    -LiteralPath (Join-Path $scriptsRoot 'bootstrap-native-windows.ps1') `
    -Destination $bootstrapScriptPath `
    -Force
Copy-Item `
    -LiteralPath (Join-Path $scriptsRoot 'install-vpn-service.ps1') `
    -Destination $installServiceScriptPath `
    -Force
Copy-Item `
    -LiteralPath (Join-Path $scriptsRoot 'uninstall-vpn-service.ps1') `
    -Destination $uninstallServiceScriptPath `
    -Force

Import-PfxFromBase64 -Base64 $pfxBase64 -DestinationPath $temporaryPfxPath
try {
    $scriptCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $temporaryPfxPath,
        $pfxPassword,
        [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    try {
        foreach ($scriptPath in @(
            $bootstrapScriptPath,
            $installServiceScriptPath,
            $uninstallServiceScriptPath
        )) {
            $signature = Set-AuthenticodeSignature `
                -LiteralPath $scriptPath `
                -Certificate $scriptCertificate `
                -HashAlgorithm SHA256
            if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
                throw "PowerShell Authenticode signing failed for '$scriptPath': $($signature.StatusMessage)"
            }
        }
    }
    finally {
        $scriptCertificate.Dispose()
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryPfxPath -PathType Leaf) {
        Remove-Item -LiteralPath $temporaryPfxPath -Force
    }
}

$metadata = [ordered]@{
    schema = 'vex.windows-package-output.v2'
    channel = $Channel
    architecture = $Architecture
    version = $normalizedVersion
    package_name = $packageName
    publisher = $publisher
    display_name = $displayName
    install_entrypoint = 'elevated_bootstrap'
    service_ownership = 'manual_sc_bootstrap'
    raw_msix_provisions_service = $false
    raw_appinstaller_provisions_service = $false
    package_file = [IO.Path]::GetFileName($msixPath)
    package_uri = $packageUri
    package_sha256 = ConvertTo-HexSha256 $msixPath
    package_size_bytes = (Get-Item -LiteralPath $msixPath).Length
    client_certificate_sha256 = $clientCertificateSha256
    app_executable_sha256 = $appExecutableSha256
    service_executable_sha256 = $serviceExecutableSha256
    amneziawg_sha256 = $amneziaExecutableSha256
    wintun_sha256 = $wintunSha256
    profile_signing_keyring_sha256 = $profileSigningKeyringSha256
    bootstrap_file = [IO.Path]::GetFileName($bootstrapScriptPath)
    bootstrap_sha256 = ConvertTo-HexSha256 $bootstrapScriptPath
    bootstrap_size_bytes = (Get-Item -LiteralPath $bootstrapScriptPath).Length
    install_service_script_file = [IO.Path]::GetFileName(
        $installServiceScriptPath)
    install_service_script_sha256 = ConvertTo-HexSha256 $installServiceScriptPath
    install_service_script_size_bytes =
        (Get-Item -LiteralPath $installServiceScriptPath).Length
    uninstall_service_script_file = [IO.Path]::GetFileName(
        $uninstallServiceScriptPath)
    uninstall_service_script_sha256 = ConvertTo-HexSha256 $uninstallServiceScriptPath
    uninstall_service_script_size_bytes =
        (Get-Item -LiteralPath $uninstallServiceScriptPath).Length
    appinstaller_file = [IO.Path]::GetFileName($appInstallerPath)
    appinstaller_uri = $appInstallerUri
}

Write-Utf8NoBom `
    -Path $metadataPath `
    -Content ($metadata | ConvertTo-Json -Depth 5)

Write-Host "Packaged signed MSIX: $msixPath"
Write-Host "Metadata: $metadataPath"
