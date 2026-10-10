[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture,

    [string]$Configuration = 'Release',

    [ValidatePattern('^[a-z][a-z0-9_-]{0,31}$')]
    [string]$Channel = $(if ($env:VEX_WINDOWS_RELEASE_CHANNEL) { $env:VEX_WINDOWS_RELEASE_CHANNEL } else { 'stable' }),

    [string]$Version = $env:VEX_WINDOWS_RELEASE_VERSION,

    [string]$OutputRoot = $(Join-Path $PSScriptRoot 'out')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'ReleaseValidation.ps1')

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

    & $SignTool sign /fd SHA256 /tr $timestampUri /td SHA256 /f $PfxPath /p $Password $Path
    if ($LASTEXITCODE -ne 0) {
        throw "signtool failed for '$Path'."
    }
    & $SignTool verify /pa /all $Path
    if ($LASTEXITCODE -ne 0) {
        throw "Authenticode verification failed for '$Path'."
    }
}

function Publish-SignedSetup {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$MetadataPath,
        [Parameter(Mandatory = $true)][ValidateSet('x64', 'arm64')][string]$Architecture,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Configuration,
        [Parameter(Mandatory = $true)][string]$PublishDirectory,
        [Parameter(Mandatory = $true)][string]$SetupPath,
        [Parameter(Mandatory = $true)][string]$SignTool,
        [Parameter(Mandatory = $true)][string]$PfxBase64,
        [Parameter(Mandatory = $true)][string]$PfxPassword,
        [Parameter(Mandatory = $true)][string]$TemporaryPfxPath,
        [Parameter(Mandatory = $true)][string]$ExpectedCertificateSha256
    )
    # Never embed unfinished metadata or admit a stale previous launcher after a
    # failed publish. The setup bytes are described outside this metadata file
    # in the signed bootstrap entry to avoid a circular hash.
    if (Test-Path -LiteralPath $SetupPath) { Remove-Item -LiteralPath $SetupPath -Force }
    $metadataFile = Get-Item -LiteralPath $MetadataPath -ErrorAction Stop
    if ($metadataFile.PSIsContainer -or $metadataFile.Length -le 0 -or
        ($metadataFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The completed release metadata must be a nonempty regular file for Setup.'
    }
    $metadataLock = $null
    try {
        # The same immutable metadata bytes are embedded and bound into the
        # signed Win32 ProductVersion for the publisher's release pairing check.
        $metadataLock = [IO.File]::Open($metadataFile.FullName, [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $metadataHash = (Get-FileHash -LiteralPath $metadataFile.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
        if (Test-Path -LiteralPath $PublishDirectory) { Remove-Item -LiteralPath $PublishDirectory -Recurse -Force }
        dotnet publish $ProjectPath -c $Configuration -r "win-$Architecture" --self-contained true `
            '-p:PublishSingleFile=true' '-p:IncludeNativeLibrariesForSelfExtract=true' `
            "-p:ReleaseMetadataPath=$($metadataFile.FullName)" `
            "-p:Version=$Version" "-p:AssemblyVersion=$Version" "-p:FileVersion=$Version" `
            "-p:InformationalVersion=$Version+metadata.$metadataHash" `
            '-p:IncludeSourceRevisionInInformationalVersion=false' `
            -o $PublishDirectory
        if ($LASTEXITCODE -ne 0) { throw "Native Windows Setup publish failed with exit code $LASTEXITCODE." }
        $publishedSetup = Join-Path $PublishDirectory 'Vex.Windows.Setup.exe'
        Assert-WindowsPeArchitecture -Path $publishedSetup -Architecture $Architecture
        Copy-Item -LiteralPath $publishedSetup -Destination $SetupPath -Force
        Import-PfxFromBase64 -Base64 $PfxBase64 -DestinationPath $TemporaryPfxPath
        if ((Get-PfxCertificateSha256 -Path $TemporaryPfxPath -Password $PfxPassword) -ne $ExpectedCertificateSha256) {
            throw 'The Setup certificate must match the completed release metadata signer pin.'
        }
        Invoke-SignTool -SignTool $SignTool -PfxPath $TemporaryPfxPath -Password $PfxPassword -Path $SetupPath
    }
    catch {
        if (Test-Path -LiteralPath $SetupPath -PathType Leaf) { Remove-Item -LiteralPath $SetupPath -Force }
        throw
    }
    finally {
        if ($null -ne $metadataLock) { $metadataLock.Dispose() }
        if (Test-Path -LiteralPath $TemporaryPfxPath -PathType Leaf) { Remove-Item -LiteralPath $TemporaryPfxPath -Force }
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

function Read-VclibsDependencyIdentity {
    param([Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('x64', 'arm64')][string]$Architecture)
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.Length -le 0 -or $file.Length -gt 32MB -or
        ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'VCLibs must be a bounded regular Microsoft APPX package.'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($file.FullName)
    try {
        $manifests = @($archive.Entries | Where-Object { $_.FullName -ceq 'AppxManifest.xml' })
        $signatures = @($archive.Entries | Where-Object { $_.FullName -ceq 'AppxSignature.p7x' })
        if ($manifests.Count -ne 1 -or $manifests[0].Length -le 0 -or $manifests[0].Length -gt 1MB -or
            $signatures.Count -ne 1 -or $signatures[0].Length -le 0) {
            throw 'VCLibs manifest or package signature is missing or ambiguous.'
        }
        $settings = [Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $stream = $manifests[0].Open()
        $reader = [Xml.XmlReader]::Create($stream, $settings)
        try {
            $manifest = [Xml.XmlDocument]::new()
            $manifest.XmlResolver = $null
            $manifest.Load($reader)
        }
        finally { $reader.Dispose(); $stream.Dispose() }
        $identity = $manifest.SelectSingleNode('/*[local-name()="Package"]/*[local-name()="Identity"]')
        $framework = $manifest.SelectSingleNode('/*[local-name()="Package"]/*[local-name()="Properties"]/*[local-name()="Framework"]')
        $version = $null
        if ($null -eq $identity -or $null -eq $framework -or $framework.InnerText -cne 'true' -or
            $identity.GetAttribute('Name') -cne 'Microsoft.VCLibs.140.00.UWPDesktop' -or
            $identity.GetAttribute('Publisher') -cne 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' -or
            $identity.GetAttribute('ProcessorArchitecture') -cne $Architecture -or
            $identity.GetAttribute('Version') -notmatch '^\d+\.\d+\.\d+\.\d+$' -or
            -not [version]::TryParse($identity.GetAttribute('Version'), [ref]$version) -or
            $version -lt [version]'14.0.24217.0') {
            throw 'VCLibs identity, Microsoft publisher, framework version or architecture is invalid.'
        }
        return $version.ToString()
    }
    finally { $archive.Dispose() }
}

$packageName = Get-RequiredEnv 'VEX_WINDOWS_PACKAGE_NAME'
$displayName = Get-RequiredEnv 'VEX_WINDOWS_PACKAGE_DISPLAY_NAME'
$publisher = Get-RequiredEnv 'VEX_WINDOWS_PACKAGE_PUBLISHER'
$publisherDisplayName = Get-RequiredEnv 'VEX_WINDOWS_PACKAGE_PUBLISHER_DISPLAY_NAME'
$pfxBase64 = Get-RequiredEnv 'VEX_WINDOWS_SIGN_PFX_BASE64'
$pfxPassword = Get-RequiredEnv 'VEX_WINDOWS_SIGN_PFX_PASSWORD'
$updateKeyId = Get-RequiredEnv 'VEX_WINDOWS_UPDATE_KEY_ID'
$updatePublicKeyBase64 = Get-RequiredEnv 'VEX_WINDOWS_UPDATE_PUBLIC_KEY_BASE64'
$amneziaExecutablePath = Get-WindowsRuntimeAssetPath `
    -EnvironmentName 'VEX_WINDOWS_SERVICE_AMNEZIAWG_PATH' -Architecture $Architecture
$wintunLibraryPath = Get-WindowsRuntimeAssetPath `
    -EnvironmentName 'VEX_WINDOWS_SERVICE_WINTUN_PATH' -Architecture $Architecture
$vclibsDependencyInput = Get-WindowsRuntimeAssetPath `
    -EnvironmentName 'VEX_WINDOWS_VCLIBS_PATH' -Architecture $Architecture
$timestampUri = if ($env:VEX_WINDOWS_SIGN_TIMESTAMP_URI) {
    $env:VEX_WINDOWS_SIGN_TIMESTAMP_URI.Trim()
}
else {
    'http://timestamp.digicert.com'
}
$parsedTimestampUri = $null
if (-not [Uri]::TryCreate($timestampUri, [UriKind]::Absolute, [ref]$parsedTimestampUri) -or
    $parsedTimestampUri.Scheme -notin @('http', 'https') -or $parsedTimestampUri.UserInfo) {
    throw 'VEX_WINDOWS_SIGN_TIMESTAMP_URI must be an absolute HTTP(S) timestamp service URI.'
}
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

$normalizedVersion = ConvertTo-WindowsPackageVersion $Version
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
$vclibsDependencyPath = Join-Path $publishRoot "Microsoft.VCLibs.$Architecture.14.00.Desktop.appx"

Assert-WindowsPeArchitecture -Path $amneziaExecutablePath -Architecture $Architecture
Assert-WindowsPeArchitecture -Path $wintunLibraryPath -Architecture $Architecture
$vclibsDependencyVersion = Read-VclibsDependencyIdentity -Path $vclibsDependencyInput -Architecture $Architecture

# A failed publish must never leave a stale binary eligible for signing.
if (Test-Path -LiteralPath $publishRoot -PathType Container) {
    Remove-Item -LiteralPath $publishRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $publishDir -Force | Out-Null
New-Item -ItemType Directory -Path $servicePublishDir -Force | Out-Null
New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null
Copy-Item -LiteralPath $vclibsDependencyInput -Destination $vclibsDependencyPath -Force
if ((Read-VclibsDependencyIdentity -Path $vclibsDependencyPath -Architecture $Architecture) -cne $vclibsDependencyVersion) {
    throw 'The shipped VCLibs dependency changed identity while staging.'
}
& $signtool verify /pa /all $vclibsDependencyPath
if ($LASTEXITCODE -ne 0) { throw 'The shipped Microsoft VCLibs dependency did not pass trusted package signature verification.' }

dotnet publish `
    (Join-Path $root 'native-windows\src\Vex.Windows.App\Vex.Windows.App.csproj') `
    -c $Configuration `
    -r "win-$Architecture" `
    -p:Platform=$Architecture `
    -p:EnableWindowsTargeting=true `
    -p:Version=$normalizedVersion `
    -p:AssemblyVersion=$normalizedVersion `
    -p:FileVersion=$normalizedVersion `
    -p:InformationalVersion=$Version `
    -o $publishDir
if ($LASTEXITCODE -ne 0) {
    throw "Native Windows app publish failed with exit code $LASTEXITCODE."
}

dotnet publish `
    (Join-Path $root 'native-windows\src\Vex.Windows.Service\Vex.Windows.Service.csproj') `
    -c $Configuration `
    -r "win-$Architecture" `
    -p:Platform=$Architecture `
    -p:EnableWindowsTargeting=true `
    -p:Version=$normalizedVersion `
    -p:AssemblyVersion=$normalizedVersion `
    -p:FileVersion=$normalizedVersion `
    -p:InformationalVersion=$Version `
    -o $servicePublishDir
if ($LASTEXITCODE -ne 0) {
    throw "Native Windows service publish failed with exit code $LASTEXITCODE."
}

Copy-Item -Path (Join-Path $publishDir '*') -Destination $packageDir -Recurse -Force
Copy-Item -Path (Join-Path $servicePublishDir '*') -Destination $packageDir -Recurse -Force
Assert-WindowsPeArchitecture -Path (Join-Path $packageDir 'Vex.Windows.App.exe') -Architecture $Architecture
Assert-WindowsPeArchitecture -Path (Join-Path $packageDir 'Vex.Windows.Service.exe') -Architecture $Architecture

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
    'StoreLogo.png' = 'StoreLogo.png'
    'Square150x150Logo.png' = 'Square150x150Logo.png'
    'Square44x44Logo.png' = 'Square44x44Logo.png'
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
    Replace('__VCLIBS_VERSION__', $vclibsDependencyVersion).
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
    Replace('__PACKAGE_URI__', $packageUri).
    Replace('__VCLIBS_VERSION__', $vclibsDependencyVersion).
    Replace('__VCLIBS_URI__', [Uri]::new($packageBaseUri + [IO.Path]::GetFileName($vclibsDependencyPath)).AbsoluteUri)
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
                -TimestampServer $timestampUri `
                -HashAlgorithm SHA256
            if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
                throw "PowerShell Authenticode signing failed for '$scriptPath': $($signature.StatusMessage)"
            }
            if ($null -eq $signature.TimeStamperCertificate) {
                throw "PowerShell Authenticode timestamp is missing for '$scriptPath'."
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
    update_signing_key_id = $updateKeyId
    update_signing_public_key_base64 = $updatePublicKeyBase64
    vclibs_dependency_file = [IO.Path]::GetFileName($vclibsDependencyPath)
    vclibs_dependency_sha256 = ConvertTo-HexSha256 $vclibsDependencyPath
    vclibs_dependency_size_bytes = (Get-Item -LiteralPath $vclibsDependencyPath).Length
    vclibs_dependency_version = $vclibsDependencyVersion
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

$setupPath = Join-Path $publishRoot "VEX.Setup.$Architecture.exe"
Publish-SignedSetup `
    -ProjectPath (Join-Path $root 'native-windows\src\Vex.Windows.Setup\Vex.Windows.Setup.csproj') `
    -MetadataPath $metadataPath `
    -Architecture $Architecture `
    -Version $normalizedVersion `
    -Configuration $Configuration `
    -PublishDirectory (Join-Path $publishRoot 'setup-publish') `
    -SetupPath $setupPath `
    -SignTool $signtool `
    -PfxBase64 $pfxBase64 `
    -PfxPassword $pfxPassword `
    -TemporaryPfxPath $temporaryPfxPath `
    -ExpectedCertificateSha256 $clientCertificateSha256

Write-Host "Packaged signed Setup: $setupPath"
Write-Host "Packaged signed MSIX: $msixPath"
Write-Host "Metadata: $metadataPath"
