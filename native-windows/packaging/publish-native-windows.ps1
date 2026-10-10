[CmdletBinding()]
param(
    [string]$PackagesRoot = $(Join-Path $PSScriptRoot 'out'),
    [string]$PublishRoot = $(Join-Path $PSScriptRoot 'published')
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

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Normalize-Origin {
    param([Parameter(Mandatory = $true)][string]$Value)

    $parsedOrigin = $null
    if (-not [Uri]::TryCreate(
            $Value,
            [UriKind]::Absolute,
            [ref]$parsedOrigin)) {
        throw "VEX_WINDOWS_UPDATE_ORIGIN must be an absolute URI."
    }
    if ($parsedOrigin.Scheme -ne 'https') {
        throw 'VEX_WINDOWS_UPDATE_ORIGIN must use https.'
    }
    if ($parsedOrigin.Query -or $parsedOrigin.Fragment -or $parsedOrigin.UserInfo) {
        throw 'VEX_WINDOWS_UPDATE_ORIGIN cannot contain credentials, query or fragment components.'
    }

    return $parsedOrigin.ToString().TrimEnd('/') + '/'
}

function ConvertTo-Base64Signature {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Payload,
        [Parameter(Mandatory = $true)][string]$PrivateKeyBase64,
        [Parameter(Mandatory = $true)][string]$PublicKeyBase64
    )

    $signerProject = Join-Path `
        $PSScriptRoot `
        'UpdateManifestSigner\UpdateManifestSigner.csproj'
    if (-not (Test-Path -LiteralPath $signerProject -PathType Leaf)) {
        throw "Update manifest signer project is missing: $signerProject"
    }
    $previousKey = [Environment]::GetEnvironmentVariable(
        'VEX_WINDOWS_UPDATE_PRIVATE_KEY_BASE64')
    $previousPublicKey = [Environment]::GetEnvironmentVariable(
        'VEX_WINDOWS_UPDATE_PUBLIC_KEY_BASE64')
    try {
        [Environment]::SetEnvironmentVariable(
            'VEX_WINDOWS_UPDATE_PRIVATE_KEY_BASE64',
            $PrivateKeyBase64)
        [Environment]::SetEnvironmentVariable(
            'VEX_WINDOWS_UPDATE_PUBLIC_KEY_BASE64',
            $PublicKeyBase64)
        $payloadBase64 = [Convert]::ToBase64String($Payload)
        $signerOutput = @(
            dotnet run `
                --project $signerProject `
                --configuration Release `
                --verbosity quiet `
                -- `
                $payloadBase64
        )
        if ($LASTEXITCODE -ne 0) {
            throw "Update manifest signer failed with exit code $LASTEXITCODE."
        }
        $signatureBase64 = [string](
            $signerOutput |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Last 1)
        try {
            [void][Convert]::FromBase64String($signatureBase64)
        }
        catch [FormatException] {
            throw 'Update manifest signer returned an invalid signature.'
        }
        return $signatureBase64
    }
    finally {
        [Environment]::SetEnvironmentVariable(
            'VEX_WINDOWS_UPDATE_PRIVATE_KEY_BASE64',
            $previousKey)
        [Environment]::SetEnvironmentVariable(
            'VEX_WINDOWS_UPDATE_PUBLIC_KEY_BASE64',
            $previousPublicKey)
    }
}

function Get-WindowsReleasePolicy {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [string]$MinimumSupportedVersion,
        [string]$RequiredVersionFloor,
        [bool]$RequiredUpdate = $false,
        [ValidateRange(0, 100)][int]$RolloutPercent = 100
    )

    $normalizedVersion = ConvertTo-WindowsPackageVersion $Version
    $minimum = if ([string]::IsNullOrWhiteSpace($MinimumSupportedVersion)) { $null }
               else { ConvertTo-WindowsPackageVersion $MinimumSupportedVersion }
    $floor = if (-not [string]::IsNullOrWhiteSpace($RequiredVersionFloor)) {
        ConvertTo-WindowsPackageVersion $RequiredVersionFloor
    }
    elseif ($null -ne $minimum) { $minimum }
    else { '0.0.0.0' }
    if ([version]$floor -gt [version]$normalizedVersion -or
        ($null -ne $minimum -and [version]$minimum -gt [version]$normalizedVersion)) {
        throw 'A Windows release must provide an install target satisfying its required floor and minimum supported version.'
    }
    return [pscustomobject]@{
        RequiredVersionFloor = $floor
        MinimumSupportedVersion = $minimum
        RequiredUpdate = $RequiredUpdate
        # A mandatory release must remain obtainable outside an optional cohort.
        RolloutPercent = $(if ($RequiredUpdate) { 100 } else { $RolloutPercent })
    }
}

function Assert-FileHashAndSize {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][long]$ExpectedSize,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description is missing: $Path"
    }
    $file = Get-Item -LiteralPath $Path
    if ($file.Length -ne $ExpectedSize) {
        throw "$Description size does not match package metadata."
    }
    $actualSha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actualSha256 -ne $ExpectedSha256.ToUpperInvariant()) {
        throw "$Description hash does not match package metadata."
    }
}

function Get-WindowsNativeSetupDescriptor {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$Directory
    )
    if ([string]$Metadata.architecture -cnotin @('x64', 'arm64') -or
        [string]$Metadata.client_certificate_sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'Native Setup requires a valid architecture and embedded release signer pin.'
    }
    $name = "VEX.Setup.$($Metadata.architecture).exe"
    $path = Join-Path $Directory $name
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -le 0 -or $item.Length -gt 512MB -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($null -ne $item.PSObject.Properties['LinkType'] -and $item.LinkType -eq 'HardLink')) {
        throw 'Native Setup must be a bounded regular executable.'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $path
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
        $null -eq $signature.SignerCertificate) {
        throw 'Native Setup requires a valid trusted Authenticode signature.'
    }
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { $certificatePin = [BitConverter]::ToString($sha256.ComputeHash($signature.SignerCertificate.RawData)).Replace('-', '') }
    finally { $sha256.Dispose() }
    if ($certificatePin -ine [string]$Metadata.client_certificate_sha256) {
        throw 'Native Setup signer does not match the exact release metadata.'
    }
    return [pscustomobject]@{
        FileName = $name; SourcePath = $path
        Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        SizeBytes = [long]$item.Length
    }
}

function New-WindowsInstallBundle {
    param(
        [Parameter(Mandatory = $true)][string[]]$Files,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    # Windows PowerShell 5.1 does not preload the framework ZIP assembly.
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    if ($Files.Count -ne 7) { throw 'A Windows install bundle must contain exactly seven verified release files.' }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $stream = [IO.File]::Open($Destination, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($path in $Files) {
                $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                if ($item.PSIsContainer -or $item.Length -le 0 -or
                    ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    -not $names.Add($item.Name)) { throw 'Install bundles only accept distinct ordinary release files.' }
                # Explicit members prevent private keys, signing caches or
                # unrelated files in the package directory from being shipped.
                $bundleInput = [IO.File]::Open($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                try {
                    $entry = $archive.CreateEntry($item.Name, [IO.Compression.CompressionLevel]::Optimal)
                    $bundleOutput = $entry.Open()
                    try { $bundleInput.CopyTo($bundleOutput) } finally { $bundleOutput.Dispose() }
                }
                finally { $bundleInput.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
    $file = Get-Item -LiteralPath $Destination
    if ($file.Length -le 0 -or $file.Length -gt 512MB) { throw 'The Windows install bundle exceeds its release size limit.' }
    return [pscustomobject]@{
        FileName = $file.Name; Sha256 = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
        SizeBytes = [long]$file.Length
    }
}

$origin = Normalize-Origin (Get-RequiredEnv 'VEX_WINDOWS_UPDATE_ORIGIN')
$keyId = Get-RequiredEnv 'VEX_WINDOWS_UPDATE_KEY_ID'
$privateKeyBase64 = Get-RequiredEnv 'VEX_WINDOWS_UPDATE_PRIVATE_KEY_BASE64'
$publicKeyBase64 = Get-RequiredEnv 'VEX_WINDOWS_UPDATE_PUBLIC_KEY_BASE64'
$manifestRevisionValue = Get-RequiredEnv 'VEX_WINDOWS_MANIFEST_REVISION'
$releaseNotes = Get-RequiredEnv 'VEX_WINDOWS_RELEASE_NOTES'
$manifestRevision = 0L
if (-not [long]::TryParse(
        $manifestRevisionValue,
        [ref]$manifestRevision) -or
    $manifestRevision -le 0) {
    throw 'VEX_WINDOWS_MANIFEST_REVISION must be a positive integer.'
}
$minimumSupportedVersion = [Environment]::GetEnvironmentVariable(
    'VEX_WINDOWS_MINIMUM_SUPPORTED_VERSION')
$requiredVersionFloor = [Environment]::GetEnvironmentVariable(
    'VEX_WINDOWS_REQUIRED_VERSION_FLOOR')
$requiredUpdate = [string]::Equals(
    [Environment]::GetEnvironmentVariable('VEX_WINDOWS_UPDATE_REQUIRED'),
    'true',
    [StringComparison]::OrdinalIgnoreCase)
$rolloutPercent = 100
$rolloutValue = [Environment]::GetEnvironmentVariable(
    'VEX_WINDOWS_ROLLOUT_PERCENT')
if (-not [string]::IsNullOrWhiteSpace($rolloutValue)) {
    if (-not [int]::TryParse($rolloutValue, [ref]$rolloutPercent) -or
        $rolloutPercent -lt 0 -or
        $rolloutPercent -gt 100) {
        throw 'VEX_WINDOWS_ROLLOUT_PERCENT must be an integer between 0 and 100.'
    }
}

$templatePath = Join-Path $PSScriptRoot 'AppInstaller.template.xml'
$template = Get-Content -LiteralPath $templatePath -Raw
$metadataFiles = @(
    Get-ChildItem `
        -LiteralPath $PackagesRoot `
        -Filter package-metadata.json `
        -Recurse `
        -File
)
if ($metadataFiles.Count -eq 0) {
    throw "No package-metadata.json files were found under '$PackagesRoot'."
}

$metadataEntries = @(
    foreach ($metadataFile in $metadataFiles) {
        [pscustomobject]@{
            SourceFile = $metadataFile
            Metadata = (
                Get-Content -LiteralPath $metadataFile.FullName -Raw |
                    ConvertFrom-Json
            )
        }
    }
)
$requiredArchitectures = @('x64', 'arm64')
$releaseArchitectures = @(
    $metadataEntries |
        ForEach-Object { [string]$_.Metadata.architecture }
)
foreach ($requiredArchitecture in $requiredArchitectures) {
    if (@($releaseArchitectures | Where-Object {
            $_ -eq $requiredArchitecture
        }).Count -ne 1) {
        throw "Incomplete Windows release set: expected exactly one '$requiredArchitecture' package."
    }
}
if ($releaseArchitectures.Count -ne $requiredArchitectures.Count) {
    throw 'Incomplete Windows release set: only x64 and arm64 packages are allowed.'
}

$referenceMetadata = $metadataEntries[0].Metadata
foreach ($entry in $metadataEntries) {
    $candidate = $entry.Metadata
    foreach ($field in @('channel', 'version', 'package_name', 'publisher')) {
        if ([string]$candidate.$field -ne [string]$referenceMetadata.$field) {
            throw "Package identity differs between architectures: '$field'."
        }
    }
    if ([string]$candidate.update_signing_key_id -cne $keyId -or
        [string]$candidate.update_signing_public_key_base64 -cne $publicKeyBase64) {
        throw 'Windows update signing inputs do not match the public keyring shipped in every package.'
    }
    $policy = Get-WindowsReleasePolicy -Version ([string]$candidate.version) `
        -MinimumSupportedVersion $minimumSupportedVersion -RequiredVersionFloor $requiredVersionFloor `
        -RequiredUpdate $requiredUpdate -RolloutPercent $rolloutPercent
    $entry | Add-Member -NotePropertyName ReleasePolicy -NotePropertyValue $policy
    $vclibsFile = [string]$candidate.vclibs_dependency_file
    if ($vclibsFile -cne "Microsoft.VCLibs.$($candidate.architecture).14.00.Desktop.appx" -or
        [string]$candidate.vclibs_dependency_sha256 -notmatch '^[0-9A-Fa-f]{64}$' -or
        [long]$candidate.vclibs_dependency_size_bytes -le 0 -or
        [long]$candidate.vclibs_dependency_size_bytes -gt (32L * 1024 * 1024)) {
        throw 'Windows release VCLibs dependency metadata is invalid.'
    }
    $vclibsVersion = ConvertTo-WindowsPackageVersion ([string]$candidate.vclibs_dependency_version)
    if ([version]$vclibsVersion -lt [version]'14.0.24217.0') {
        throw 'Windows release VCLibs dependency is below the declared MSIX framework minimum.'
    }
    Assert-FileHashAndSize -Path (Join-Path $entry.SourceFile.Directory.FullName $vclibsFile) `
        -ExpectedSha256 ([string]$candidate.vclibs_dependency_sha256) `
        -ExpectedSize ([long]$candidate.vclibs_dependency_size_bytes) -Description 'Microsoft VCLibs dependency'
    # Setup embeds the finished metadata. Its descriptor belongs to the signed
    # release entry, never back inside that metadata (which would create a cycle).
    $setup = Get-WindowsNativeSetupDescriptor -Metadata $candidate -Directory $entry.SourceFile.Directory.FullName
    $entry | Add-Member -NotePropertyName SetupDescriptor -NotePropertyValue $setup
}

# Reject malformed or mismatched signing keys before creating release outputs.
$null = ConvertTo-Base64Signature -Payload ([Text.Encoding]::UTF8.GetBytes('VEX Windows release signing preflight')) `
    -PrivateKeyBase64 $privateKeyBase64 -PublicKeyBase64 $publicKeyBase64

foreach ($entry in $metadataEntries) {
    $metadataFile = $entry.SourceFile
    $metadata = $entry.Metadata
    $channel = [string]$metadata.channel
    $architecture = [string]$metadata.architecture
    $version = [string]$metadata.version
    $packageName = [string]$metadata.package_name
    $publisher = [string]$metadata.publisher
    $packageFile = [string]$metadata.package_file
    $packageSha256 = [string]$metadata.package_sha256
    $packageSizeBytes = [long]$metadata.package_size_bytes
    $policy = $entry.ReleasePolicy
    $effectiveRequiredVersionFloor = $policy.RequiredVersionFloor
    if ([string]$metadata.schema -ne 'vex.windows-package-output.v2') {
        throw "Unsupported package metadata schema: $($metadata.schema)"
    }
    $bootstrapFile = [string]$metadata.bootstrap_file
    $bootstrapSha256 = [string]$metadata.bootstrap_sha256
    $bootstrapSizeBytes = [long]$metadata.bootstrap_size_bytes
    $installScriptFile = [string]$metadata.install_service_script_file
    $installScriptSha256 = [string]$metadata.install_service_script_sha256
    $installScriptSizeBytes =
        [long]$metadata.install_service_script_size_bytes
    $uninstallScriptFile = [string]$metadata.uninstall_service_script_file
    $uninstallScriptSha256 =
        [string]$metadata.uninstall_service_script_sha256
    $uninstallScriptSizeBytes =
        [long]$metadata.uninstall_service_script_size_bytes
    $vclibsFile = [string]$metadata.vclibs_dependency_file
    $vclibsSha256 = [string]$metadata.vclibs_dependency_sha256
    $vclibsSizeBytes = [long]$metadata.vclibs_dependency_size_bytes
    $vclibsVersion = ConvertTo-WindowsPackageVersion ([string]$metadata.vclibs_dependency_version)
    $setup = $entry.SetupDescriptor
    $bootstrapSource = Join-Path $metadataFile.Directory.FullName $bootstrapFile
    $installScriptSource = Join-Path `
        $metadataFile.Directory.FullName `
        $installScriptFile
    $uninstallScriptSource = Join-Path `
        $metadataFile.Directory.FullName `
        $uninstallScriptFile
    $packageSource = Join-Path $metadataFile.Directory.FullName $packageFile
    $vclibsSource = Join-Path $metadataFile.Directory.FullName $vclibsFile
    Assert-FileHashAndSize `
        -Path $packageSource `
        -ExpectedSha256 $packageSha256 `
        -ExpectedSize $packageSizeBytes `
        -Description 'Packaged MSIX'
    Assert-FileHashAndSize `
        -Path $bootstrapSource `
        -ExpectedSha256 $bootstrapSha256 `
        -ExpectedSize $bootstrapSizeBytes `
        -Description 'Signed bootstrap'
    Assert-FileHashAndSize `
        -Path $installScriptSource `
        -ExpectedSha256 $installScriptSha256 `
        -ExpectedSize $installScriptSizeBytes `
        -Description 'Signed service installer'
    Assert-FileHashAndSize `
        -Path $uninstallScriptSource `
        -ExpectedSha256 $uninstallScriptSha256 `
        -ExpectedSize $uninstallScriptSizeBytes `
        -Description 'Signed service uninstaller'

    $versionedDirectory = Join-Path $PublishRoot "$channel\$version\$architecture"
    $channelDirectory = Join-Path $PublishRoot "$channel\$architecture"
    New-Item -ItemType Directory -Path $versionedDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $channelDirectory -Force | Out-Null

    $packageDestination = Join-Path $versionedDirectory $packageFile
    Copy-Item -LiteralPath $packageSource -Destination $packageDestination -Force
    foreach ($requiredFile in @(
        $bootstrapSource,
        $installScriptSource,
        $uninstallScriptSource,
        $vclibsSource,
        $setup.SourcePath
    )) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "Required bootstrap artifact is missing: $requiredFile"
        }
        Copy-Item `
            -LiteralPath $requiredFile `
            -Destination (Join-Path $versionedDirectory ([IO.Path]::GetFileName($requiredFile))) `
            -Force
    }
    Copy-Item `
        -LiteralPath $metadataFile.FullName `
        -Destination (Join-Path $versionedDirectory 'package-metadata.json') `
        -Force

    $bundleFile = "VEX.Native.$channel.$architecture.$version.zip"
    $bundle = New-WindowsInstallBundle -Destination (Join-Path $versionedDirectory $bundleFile) -Files @(
        $packageDestination,
        (Join-Path $versionedDirectory 'package-metadata.json'),
        (Join-Path $versionedDirectory $bootstrapFile),
        (Join-Path $versionedDirectory $installScriptFile),
        (Join-Path $versionedDirectory $uninstallScriptFile),
        (Join-Path $versionedDirectory $vclibsFile),
        (Join-Path $versionedDirectory $setup.FileName)
    )

    $packageUri = "$origin$channel/$version/$architecture/$packageFile"
    $bootstrapUri = "$origin$channel/$version/$architecture/$bootstrapFile"
    $metadataUri = "$origin$channel/$version/$architecture/package-metadata.json"
    $setupUri = "$origin$channel/$version/$architecture/$($setup.FileName)"
    $bundleUri = "$origin$channel/$version/$architecture/$bundleFile"
    $installScriptUri =
        "$origin$channel/$version/$architecture/$installScriptFile"
    $uninstallScriptUri =
        "$origin$channel/$version/$architecture/$uninstallScriptFile"
    $vclibsUri = "$origin$channel/$version/$architecture/$vclibsFile"
    $metadataPublishedPath = Join-Path `
        $versionedDirectory `
        'package-metadata.json'
    $metadataSha256 = (Get-FileHash `
        -LiteralPath $metadataPublishedPath `
        -Algorithm SHA256).Hash
    $metadataSizeBytes = (Get-Item -LiteralPath $metadataPublishedPath).Length
    $bootstrapEntryFile = 'bootstrap-entry.json'
    $bootstrapEntrySignatureFile = 'bootstrap-entry.json.sig'
    $bootstrapEntryUri =
        "$origin$channel/$version/$architecture/$bootstrapEntryFile"
    $bootstrapEntrySignatureUri =
        "$origin$channel/$version/$architecture/$bootstrapEntrySignatureFile"
    $bootstrapEntry = [ordered]@{
        schema = 'vex.windows-bootstrap-entry.v1'
        channel = $channel
        version = $version
        architecture = $architecture
        install_entrypoint = 'elevated_bootstrap'
        service_ownership = 'manual_sc_bootstrap'
        requires_elevation = $true
        package = [ordered]@{
            uri = $packageUri
            sha256 = $packageSha256
            size_bytes = $packageSizeBytes
        }
        bootstrap = [ordered]@{
            uri = $bootstrapUri
            sha256 = $bootstrapSha256
            size_bytes = $bootstrapSizeBytes
        }
        install_service_script = [ordered]@{
            uri = $installScriptUri
            sha256 = $installScriptSha256
            size_bytes = $installScriptSizeBytes
        }
        uninstall_service_script = [ordered]@{
            uri = $uninstallScriptUri
            sha256 = $uninstallScriptSha256
            size_bytes = $uninstallScriptSizeBytes
        }
        package_metadata = [ordered]@{
            uri = $metadataUri
            sha256 = $metadataSha256
            size_bytes = $metadataSizeBytes
        }
        files = [ordered]@{
            bundle = [ordered]@{
                uri = $bundleUri
                sha256 = $bundle.Sha256
                size_bytes = $bundle.SizeBytes
            }
            setup = [ordered]@{
                uri = $setupUri
                sha256 = $setup.Sha256
                size_bytes = $setup.SizeBytes
            }
            vclibs_dependency = [ordered]@{
                uri = $vclibsUri
                sha256 = $vclibsSha256
                size_bytes = $vclibsSizeBytes
            }
        }
    }
    $bootstrapEntryContent = $bootstrapEntry | ConvertTo-Json -Depth 8
    $bootstrapEntryPath = Join-Path `
        $versionedDirectory `
        $bootstrapEntryFile
    $bootstrapEntrySignature = ConvertTo-Base64Signature `
        -Payload ([Text.Encoding]::UTF8.GetBytes($bootstrapEntryContent)) `
        -PrivateKeyBase64 $privateKeyBase64 -PublicKeyBase64 $publicKeyBase64
    Write-Utf8NoBom `
        -Path $bootstrapEntryPath `
        -Content $bootstrapEntryContent
    Write-Utf8NoBom `
        -Path (Join-Path $versionedDirectory $bootstrapEntrySignatureFile) `
        -Content $bootstrapEntrySignature
    $bootstrapEntrySha256 = (Get-FileHash `
        -LiteralPath $bootstrapEntryPath `
        -Algorithm SHA256).Hash
    $bootstrapEntrySizeBytes =
        (Get-Item -LiteralPath $bootstrapEntryPath).Length
    $appInstallerFileName = "VEX.Native.$channel.$architecture.appinstaller"
    $appInstallerUri = "$origin$channel/$architecture/$appInstallerFileName"
    $appInstallerPath = Join-Path $channelDirectory $appInstallerFileName
    $appInstallerContent = $template.
        Replace('__APPINSTALLER_VERSION__', $version).
        Replace('__APPINSTALLER_URI__', $appInstallerUri).
        Replace('__PACKAGE_NAME__', $packageName).
        Replace('__PUBLISHER__', $publisher).
        Replace('__PACKAGE_VERSION__', $version).
        Replace('__ARCHITECTURE__', $architecture).
        Replace('__VCLIBS_VERSION__', $vclibsVersion).
        Replace('__VCLIBS_URI__', $vclibsUri).
        Replace('__PACKAGE_URI__', $packageUri)
    Write-Utf8NoBom -Path $appInstallerPath -Content $appInstallerContent

    $manifestObject = [ordered]@{
        schema = 'vex.windows-update-manifest.v1'
        channel = $channel
        published_at = [DateTimeOffset]::UtcNow.ToString('O')
        manifest_revision = $manifestRevision
        required_version_floor = $effectiveRequiredVersionFloor
        signing = [ordered]@{
            key_id = $keyId
            algorithm = 'ECDSA_P256_SHA256_DER'
        }
        releases = @(
            [ordered]@{
                version = $version
                architecture = $architecture
                package_type = 'msix'
                package_uri = $packageUri
                package_sha256 = $packageSha256
                package_name = $packageName
                publisher = $publisher
                appinstaller_uri = $appInstallerUri
                package_size_bytes = $packageSizeBytes
                install_entrypoint = 'elevated_bootstrap'
                service_ownership = 'manual_sc_bootstrap'
                raw_msix_provisions_service = $false
                raw_appinstaller_provisions_service = $false
                bootstrap_uri = $bootstrapUri
                bootstrap_sha256 = $bootstrapSha256
                bootstrap_size_bytes = $bootstrapSizeBytes
                install_service_script_uri = $installScriptUri
                install_service_script_sha256 = $installScriptSha256
                install_service_script_size_bytes = $installScriptSizeBytes
                uninstall_service_script_uri = $uninstallScriptUri
                uninstall_service_script_sha256 = $uninstallScriptSha256
                uninstall_service_script_size_bytes =
                    $uninstallScriptSizeBytes
                package_metadata_uri = $metadataUri
                package_metadata_sha256 = $metadataSha256
                package_metadata_size_bytes = $metadataSizeBytes
                vclibs_dependency_uri = $vclibsUri
                vclibs_dependency_sha256 = $vclibsSha256
                vclibs_dependency_size_bytes = $vclibsSizeBytes
                native_setup_uri = $setupUri
                native_setup_sha256 = $setup.Sha256
                native_setup_size_bytes = $setup.SizeBytes
                native_bundle_uri = $bundleUri
                native_bundle_sha256 = $bundle.Sha256
                native_bundle_size_bytes = $bundle.SizeBytes
                bootstrap_entry_uri = $bootstrapEntryUri
                bootstrap_entry_sha256 = $bootstrapEntrySha256
                bootstrap_entry_size_bytes = $bootstrapEntrySizeBytes
                bootstrap_entry_signature_uri =
                    $bootstrapEntrySignatureUri
                minimum_supported_version = $policy.MinimumSupportedVersion
                changelog = $releaseNotes
                required = $policy.RequiredUpdate
                rollout_percent = $policy.RolloutPercent
            }
        )
    }

    $manifestPath = Join-Path $channelDirectory 'update.json'
    $manifestContent = $manifestObject | ConvertTo-Json -Depth 8
    $signature = ConvertTo-Base64Signature `
        -Payload ([System.Text.Encoding]::UTF8.GetBytes($manifestContent)) `
        -PrivateKeyBase64 $privateKeyBase64 -PublicKeyBase64 $publicKeyBase64
    Write-Utf8NoBom -Path $manifestPath -Content $manifestContent
    Write-Utf8NoBom `
        -Path (Join-Path $channelDirectory 'update.json.sig') `
        -Content $signature

    Write-Host "Published local update manifest: $manifestPath"
}
