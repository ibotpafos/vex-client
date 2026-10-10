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

    # The desktop framework is an APPX dependency, not vc_redist.exe. The
    # packager verifies Microsoft's signature and exact framework identity
    # before these bytes can enter a release.
    $dependencyPathName = "VEX_WINDOWS_VCLIBS_PATH_$suffix"
    $dependencyPath = [Environment]::GetEnvironmentVariable($dependencyPathName)
    if ([string]::IsNullOrWhiteSpace($dependencyPath)) {
        $dependencyPath = [Environment]::GetEnvironmentVariable('VEX_WINDOWS_VCLIBS_PATH')
    }
    if ([string]::IsNullOrWhiteSpace($dependencyPath)) {
        $dependencyUri = [Environment]::GetEnvironmentVariable("VEX_WINDOWS_VCLIBS_URI_$suffix")
        $expectedDependencyHash = [Environment]::GetEnvironmentVariable("VEX_WINDOWS_VCLIBS_SHA256_$suffix")
        if ([string]::IsNullOrWhiteSpace($dependencyUri)) {
            $dependencyUri = "https://aka.ms/Microsoft.VCLibs.$architecture.14.00.Desktop.appx"
        }
        elseif ($expectedDependencyHash -notmatch '^[0-9A-Fa-f]{64}$') {
            throw "A pinned SHA-256 is required for a custom VCLibs URI on '$architecture'."
        }
        $parsedDependencyUri = $null
        if (-not [Uri]::TryCreate($dependencyUri, [UriKind]::Absolute, [ref]$parsedDependencyUri) -or
            $parsedDependencyUri.Scheme -ne 'https' -or $parsedDependencyUri.UserInfo -or
            $parsedDependencyUri.Fragment) {
            throw "VCLibs URI on '$architecture' must use HTTPS without credentials or fragments."
        }
        $directory = Join-Path $DestinationRoot $architecture
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $dependencyPath = Join-Path $directory "Microsoft.VCLibs.$architecture.14.00.Desktop.appx"
        Invoke-WebRequest -Uri $parsedDependencyUri -OutFile $dependencyPath -MaximumRedirection 5 -TimeoutSec 90
        $dependencyLength = (Get-Item -LiteralPath $dependencyPath).Length
        if ($dependencyLength -le 0 -or $dependencyLength -gt (32 * 1024 * 1024) -or
            (-not [string]::IsNullOrWhiteSpace($expectedDependencyHash) -and
             (Get-FileHash -LiteralPath $dependencyPath -Algorithm SHA256).Hash -ne $expectedDependencyHash.ToUpperInvariant())) {
            Remove-Item -LiteralPath $dependencyPath -Force
            throw "Downloaded VCLibs size or pinned hash mismatch on '$architecture'."
        }
    }
    if (-not (Test-Path -LiteralPath $dependencyPath -PathType Leaf)) {
        throw "The VCLibs dependency path on '$architecture' does not exist."
    }
    [Environment]::SetEnvironmentVariable($dependencyPathName, $dependencyPath)
    if ($env:GITHUB_ENV) {
        "$dependencyPathName=$dependencyPath" | Out-File -LiteralPath $env:GITHUB_ENV -Append -Encoding utf8
    }
}
Write-Host 'Verified native x64 and arm64 runtime assets.'
Write-Host 'Staged desktop framework dependencies for mandatory package signature and identity verification.'
