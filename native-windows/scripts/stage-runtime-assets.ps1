[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DestinationRoot,
    [switch]$DisposableRunner
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path (Join-Path $PSScriptRoot '..') 'packaging/ReleaseValidation.ps1')

function Get-QualifiedMsiRuntime {
    param([ValidateSet('x64', 'arm64')][string]$Architecture, [string]$Directory, [switch]$DisposableRunner)
    if (-not $DisposableRunner -or $env:OS -cne 'Windows_NT' -or $env:GITHUB_ACTIONS -cne 'true' -or
        $env:RUNNER_ENVIRONMENT -cne 'github-hosted') { throw 'MSI extraction requires an explicit disposable Windows runner.' }
    $qualified = @{
        x64 = @{ File = 'amneziawg-amd64-3.1.0.msi'; Sha256 = 'a1b48ea8699cd347832a3691d832004574ef8ad65bcf887611ac8acb99b7de8b' }
        arm64 = @{ File = 'amneziawg-arm64-3.1.0.msi'; Sha256 = '3aec023884944890fac151f9cd4be3e92d39f9987c49da248837529c006ea2aa' }
    }[$Architecture]
    [void][IO.Directory]::CreateDirectory($Directory)
    $msi = Join-Path $Directory $qualified.File
    Invoke-WebRequest -Uri ("https://github.com/amnezia-vpn/amneziawg-windows-client/releases/download/3.1.0/" + $qualified.File) `
        -OutFile $msi -MaximumRedirection 5 -TimeoutSec 90
    if ((Get-Item -LiteralPath $msi).Length -gt (16 * 1024 * 1024) -or
        (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash -ine $qualified.Sha256) {
        Remove-Item -LiteralPath $msi -Force
        throw 'The official MSI differs from the qualified immutable runtime.'
    }
    $extraction = Join-Path $Directory 'extracted'
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32/msiexec.exe'))
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    foreach ($argument in @('/a', $msi, '/qn', "TARGETDIR=$extraction")) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        if (-not $process.WaitForExit(90000)) { $process.Kill($true); throw 'Qualified MSI extraction timed out.' }
        if ($process.ExitCode -ne 0) { throw 'Qualified MSI administrative extraction failed.' }
    }
    finally { $process.Dispose() }
    $paths = @{}
    foreach ($name in @('amneziawg.exe', 'wintun.dll')) {
        $files = @(Get-ChildItem -LiteralPath $extraction -Filter $name -File -Recurse)
        if ($files.Count -ne 1) { throw 'The qualified MSI runtime files are ambiguous or missing.' }
        Assert-WindowsPeArchitecture -Path $files[0].FullName -Architecture $Architecture
        $paths[$name] = $files[0].FullName
    }
    return $paths
}

if ($env:VEX_WINDOWS_SERVICE_MSI_SOURCE -and $env:VEX_WINDOWS_SERVICE_MSI_SOURCE -cne 'amneziawg-3.1.0') {
    throw 'Unsupported qualified Windows MSI runtime source.'
}

foreach ($architecture in @('x64', 'arm64')) {
    $suffix = $architecture.ToUpperInvariant()
    $qualifiedRuntime = $null
    foreach ($asset in @(
        @{ Name = 'AMNEZIAWG'; File = 'amneziawg.exe' },
        @{ Name = 'ROUTER'; File = 'vex-awg.exe' },
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
            if ($env:VEX_WINDOWS_SERVICE_MSI_SOURCE -and
                -not [Environment]::GetEnvironmentVariable($pathName) -and
                -not [Environment]::GetEnvironmentVariable("$($baseName)_PATH")) {
                if ($null -eq $qualifiedRuntime) {
                    $qualifiedRuntime = Get-QualifiedMsiRuntime -Architecture $architecture `
                        -Directory (Join-Path $DestinationRoot "msi-$architecture") -DisposableRunner:$DisposableRunner
                }
                [Environment]::SetEnvironmentVariable($pathName, $qualifiedRuntime[$asset.File])
            }
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
