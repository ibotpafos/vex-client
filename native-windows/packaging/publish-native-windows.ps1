[CmdletBinding()]
param(
    [string]$PackagesRoot = $(Join-Path $PSScriptRoot 'out'),
    [string]$PublishRoot = $(Join-Path $PSScriptRoot 'published')
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
    if ($parsedOrigin.Query -or $parsedOrigin.Fragment) {
        throw 'VEX_WINDOWS_UPDATE_ORIGIN cannot contain query or fragment components.'
    }

    return $parsedOrigin.ToString().TrimEnd('/') + '/'
}

function ConvertTo-Base64Signature {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Payload,
        [Parameter(Mandatory = $true)][string]$PrivateKeyBase64
    )

    $signerProject = Join-Path `
        $PSScriptRoot `
        'UpdateManifestSigner\UpdateManifestSigner.csproj'
    if (-not (Test-Path -LiteralPath $signerProject -PathType Leaf)) {
        throw "Update manifest signer project is missing: $signerProject"
    }
    $previousKey = [Environment]::GetEnvironmentVariable(
        'VEX_WINDOWS_UPDATE_PRIVATE_KEY_BASE64')
    try {
        [Environment]::SetEnvironmentVariable(
            'VEX_WINDOWS_UPDATE_PRIVATE_KEY_BASE64',
            $PrivateKeyBase64)
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

$origin = Normalize-Origin (Get-RequiredEnv 'VEX_WINDOWS_UPDATE_ORIGIN')
$keyId = Get-RequiredEnv 'VEX_WINDOWS_UPDATE_KEY_ID'
$privateKeyBase64 = Get-RequiredEnv 'VEX_WINDOWS_UPDATE_PRIVATE_KEY_BASE64'
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
if ([string]::IsNullOrWhiteSpace($requiredVersionFloor)) {
    $requiredVersionFloor = if (
        [string]::IsNullOrWhiteSpace($minimumSupportedVersion)
    ) {
        $null
    }
    else {
        $minimumSupportedVersion.Trim()
    }
}
if (-not [string]::IsNullOrWhiteSpace($requiredVersionFloor)) {
    $parsedRequiredVersionFloor = $null
    if (-not [Version]::TryParse(
            $requiredVersionFloor,
            [ref]$parsedRequiredVersionFloor)) {
        throw 'VEX_WINDOWS_REQUIRED_VERSION_FLOOR must be a numeric Windows version.'
    }
    $requiredVersionFloor = $parsedRequiredVersionFloor.ToString()
}
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
    if (($releaseArchitectures | Where-Object {
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
}

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
    $effectiveRequiredVersionFloor = if (
        [string]::IsNullOrWhiteSpace($requiredVersionFloor)
    ) {
        $version
    }
    else {
        $requiredVersionFloor
    }
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
    $bootstrapSource = Join-Path $metadataFile.Directory.FullName $bootstrapFile
    $installScriptSource = Join-Path `
        $metadataFile.Directory.FullName `
        $installScriptFile
    $uninstallScriptSource = Join-Path `
        $metadataFile.Directory.FullName `
        $uninstallScriptFile
    $packageSource = Join-Path $metadataFile.Directory.FullName $packageFile
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
        $uninstallScriptSource
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

    $packageUri = "$origin$channel/$version/$architecture/$packageFile"
    $bootstrapUri = "$origin$channel/$version/$architecture/$bootstrapFile"
    $metadataUri = "$origin$channel/$version/$architecture/package-metadata.json"
    $installScriptUri =
        "$origin$channel/$version/$architecture/$installScriptFile"
    $uninstallScriptUri =
        "$origin$channel/$version/$architecture/$uninstallScriptFile"
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
    }
    $bootstrapEntryContent = $bootstrapEntry | ConvertTo-Json -Depth 8
    $bootstrapEntryPath = Join-Path `
        $versionedDirectory `
        $bootstrapEntryFile
    Write-Utf8NoBom `
        -Path $bootstrapEntryPath `
        -Content $bootstrapEntryContent
    $bootstrapEntrySignature = ConvertTo-Base64Signature `
        -Payload ([Text.Encoding]::UTF8.GetBytes($bootstrapEntryContent)) `
        -PrivateKeyBase64 $privateKeyBase64
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
                bootstrap_entry_uri = $bootstrapEntryUri
                bootstrap_entry_sha256 = $bootstrapEntrySha256
                bootstrap_entry_size_bytes = $bootstrapEntrySizeBytes
                bootstrap_entry_signature_uri =
                    $bootstrapEntrySignatureUri
                minimum_supported_version = if ($minimumSupportedVersion) { $minimumSupportedVersion } else { $null }
                changelog = $releaseNotes
                required = $requiredUpdate
                rollout_percent = $rolloutPercent
            }
        )
    }

    $manifestPath = Join-Path $channelDirectory 'update.json'
    $manifestContent = $manifestObject | ConvertTo-Json -Depth 8
    Write-Utf8NoBom -Path $manifestPath -Content $manifestContent

    $signature = ConvertTo-Base64Signature `
        -Payload ([System.Text.Encoding]::UTF8.GetBytes($manifestContent)) `
        -PrivateKeyBase64 $privateKeyBase64
    Write-Utf8NoBom `
        -Path (Join-Path $channelDirectory 'update.json.sig') `
        -Content $signature

    Write-Host "Published local update manifest: $manifestPath"
}
