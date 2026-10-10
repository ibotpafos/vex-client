[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DestinationRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path (Join-Path $PSScriptRoot '..') 'packaging/ReleaseValidation.ps1')

foreach ($architecture in @('x64', 'arm64')) {
    $suffix = $architecture.ToUpperInvariant()
    foreach ($asset in @(
        @{ Name = 'AMNEZIAWG'; File = 'amneziawg.exe' },
        @{ Name = 'WINTUN'; File = 'wintun.dll' }
    )) {
        $baseName = "VEX_WINDOWS_SERVICE_$($asset.Name)"
        $pathName = "$($baseName)_PATH_$suffix"
        $uri = [Environment]::GetEnvironmentVariable("$($baseName)_URI_$suffix")
        if (-not [string]::IsNullOrWhiteSpace($uri)) {
            $expectedHash = [Environment]::GetEnvironmentVariable("$($baseName)_SHA256_$suffix")
            if ($expectedHash -notmatch '^[0-9A-Fa-f]{64}$') {
                throw "A pinned SHA-256 is required for '$baseName' on '$architecture'."
            }
            $parsedUri = $null
            if (-not [Uri]::TryCreate($uri, [UriKind]::Absolute, [ref]$parsedUri) -or
                $parsedUri.Scheme -ne 'https' -or $parsedUri.UserInfo) {
                throw "Runtime URI for '$baseName' on '$architecture' must use HTTPS."
            }
            $directory = Join-Path $DestinationRoot $architecture
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            $assetPath = Join-Path $directory $asset.File
            Invoke-WebRequest -Uri $parsedUri -OutFile $assetPath -MaximumRedirection 5
            if ((Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash -ne $expectedHash.ToUpperInvariant()) {
                Remove-Item -LiteralPath $assetPath -Force
                throw "Downloaded runtime hash mismatch for '$baseName' on '$architecture'."
            }
        }
        else {
            $assetPath = Get-WindowsRuntimeAssetPath -EnvironmentName "$($baseName)_PATH" -Architecture $architecture
        }
        Assert-WindowsPeArchitecture -Path $assetPath -Architecture $architecture
        [Environment]::SetEnvironmentVariable($pathName, $assetPath)
        if ($env:GITHUB_ENV) {
            "$pathName=$assetPath" | Out-File -LiteralPath $env:GITHUB_ENV -Append -Encoding utf8
        }
    }
}
Write-Host 'Verified native x64 and arm64 runtime assets.'
