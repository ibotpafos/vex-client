[CmdletBinding()]
param(
    [string]$Target = $(if ($env:WINDOWS_TARGET) { $env:WINDOWS_TARGET } else { "x86_64-pc-windows-msvc" }),
    [string]$ArtifactsDir = $(if ($env:WINDOWS_ARTIFACTS_DIR) { $env:WINDOWS_ARTIFACTS_DIR } else { "dist/windows" }),
    [string]$Version = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Require-Env {
    param([Parameter(Mandatory = $true)][string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "$Name is required"
    }
    return $value
}

function Get-DesktopVersion {
    $versions = Get-Content -LiteralPath "versions.json" -Raw | ConvertFrom-Json
    return [string]$versions.desktop.version
}

function Get-LatestFile {
    param([Parameter(Mandatory = $true)][string]$Pattern)

    $matches = Get-ChildItem -LiteralPath "src-tauri/target" -Recurse -File |
        Where-Object { $_.FullName.Replace("\", "/") -like $Pattern } |
        Sort-Object LastWriteTimeUtc -Descending

    if (-not $matches -or $matches.Count -eq 0) {
        return $null
    }

    return $matches[0]
}

function Write-Sha256Sidecar {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [System.IO.File]::OpenRead((Resolve-Path -LiteralPath $Path))
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha256.ComputeHash($stream)
        } finally {
            $sha256.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
    $hash = -join ($hashBytes | ForEach-Object { $_.ToString("x2") })
    $name = Split-Path -Leaf $Path
    Set-Content -LiteralPath "$Path.sha256" -Value "$hash  $name" -NoNewline
    return $hash
}

function Write-MetadataSigSidecar {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Sha256
    )

    $name = Split-Path -Leaf $Path
    Set-Content -LiteralPath "$Path.sig" -Value "$Kind=$name`nsha256=$Sha256`n" -NoNewline
}

function Copy-ReleaseAsset {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Kind,
        [switch]$PreserveTauriSignature
    )

    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    $sha256 = Write-Sha256Sidecar -Path $Destination

    if ($PreserveTauriSignature) {
        $sourceSig = "$Source.sig"
        if (-not (Test-Path -LiteralPath $sourceSig)) {
            throw "Tauri updater signature is missing: $sourceSig"
        }
        Copy-Item -LiteralPath $sourceSig -Destination "$Destination.sig" -Force
    } else {
        Write-MetadataSigSidecar -Path $Destination -Kind $Kind -Sha256 $sha256
    }
}

$tauriPublicKey = Require-Env -Name "TAURI_SIGNING_PUBLIC_KEY"
$tauriPrivateKey = Require-Env -Name "TAURI_SIGNING_PRIVATE_KEY"
$tauriPrivateKeyPassword = Require-Env -Name "TAURI_SIGNING_PRIVATE_KEY_PASSWORD"

if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = Get-DesktopVersion
}

$env:TAURI_SIGNING_PRIVATE_KEY = $tauriPrivateKey
$env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD = $tauriPrivateKeyPassword

$tauriConfigPath = "src-tauri/tauri.conf.json"
$tauriConfig = Get-Content -LiteralPath $tauriConfigPath -Raw | ConvertFrom-Json
$tauriConfig.version = $Version
$tauriConfig.plugins.updater.pubkey = $tauriPublicKey
$tauriConfig.bundle.createUpdaterArtifacts = "v1Compatible"
$tauriConfig.bundle.targets = @("nsis", "msi")
$tauriConfig.bundle.resources = @("amneziawg.exe", "wintun.dll")
$tauriConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $tauriConfigPath

Write-Host "== VEX Windows Tauri release =="
Write-Host "version: $Version"
Write-Host "target: $Target"

npm run tauri:cli -- build --target $Target
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$msi = Get-LatestFile -Pattern "*/release/bundle/msi/*.msi"
$setup = Get-LatestFile -Pattern "*/release/bundle/nsis/*.exe"
$updater = Get-LatestFile -Pattern "*/release/bundle/msi/*.msi.zip"
if (-not $updater) {
    $updater = Get-LatestFile -Pattern "*/release/bundle/nsis/*.nsis.zip"
}

if (-not $msi) { throw "MSI installer was not produced" }
if (-not $setup) { throw "NSIS setup installer was not produced" }
if (-not $updater) { throw "Tauri updater zip was not produced" }

New-Item -ItemType Directory -Force -Path $ArtifactsDir | Out-Null

$msiName = "Vex-Windows-$Version.msi"
$setupName = "Vex-Windows-$Version-setup.exe"
$updaterName = "Vex-Windows-$Version.msi.zip"
if ($updater.Name.EndsWith(".nsis.zip")) {
    $updaterName = "Vex-Windows-$Version.nsis.zip"
}

$msiDest = Join-Path $ArtifactsDir $msiName
$setupDest = Join-Path $ArtifactsDir $setupName
$updaterDest = Join-Path $ArtifactsDir $updaterName

Copy-ReleaseAsset -Source $msi.FullName -Destination $msiDest -Kind "installer"
Copy-ReleaseAsset -Source $setup.FullName -Destination $setupDest -Kind "setup"
Copy-ReleaseAsset -Source $updater.FullName -Destination $updaterDest -Kind "updater" -PreserveTauriSignature

$manifest = [ordered]@{
    version = $Version
    target = $Target
    updater = $updaterName
    updaterSignature = "$updaterName.sig"
    assets = @(
        $msiName,
        "$msiName.sha256",
        "$msiName.sig",
        $setupName,
        "$setupName.sha256",
        "$setupName.sig",
        $updaterName,
        "$updaterName.sha256",
        "$updaterName.sig"
    )
}

$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $ArtifactsDir "release-manifest.json")

foreach ($asset in $manifest.assets) {
    $path = Join-Path $ArtifactsDir $asset
    if (-not (Test-Path -LiteralPath $path)) {
        throw "release asset missing: $path"
    }
}

Write-Host "Windows release assets:"
Get-ChildItem -LiteralPath $ArtifactsDir -File | Sort-Object Name | ForEach-Object {
    Write-Host "  $($_.FullName)"
}
