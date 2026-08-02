[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InstallDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'VEX VPN service removal requires elevation.'
}

$serviceName = 'VEX VPN Service'
$dataDirectory = Join-Path $env:ProgramData 'VEX\VPN'

function Remove-StagingDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (Test-Path -LiteralPath $Path) {
        try {
            Remove-Item `
                -LiteralPath $Path `
                -Recurse `
                -Force `
                -ErrorAction Stop
            return
        }
        catch {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw
            }

            Start-Sleep -Milliseconds 250
        }
    }
}

$installRoot = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
$programFilesRoot = [IO.Path]::GetFullPath(
    $env:ProgramFiles).TrimEnd('\') + '\'
if (-not $installRoot.StartsWith(
    $programFilesRoot,
    [StringComparison]::OrdinalIgnoreCase)) {
    throw 'VEX must be removed from below the protected Program Files directory.'
}
$installInfo = Get-Item -LiteralPath $installRoot
if (($installInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'The VEX installation directory cannot be a reparse point.'
}

$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($null -ne $service) {
    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    $service.Dispose()
    $service = $null
    & sc.exe delete $serviceName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'The VEX VPN service could not be removed.'
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        $remainingService = Get-Service `
            -Name $serviceName `
            -ErrorAction SilentlyContinue
        if ($null -eq $remainingService) {
            break
        }

        $remainingService.Dispose()
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($null -ne $remainingService) {
        throw 'The VEX VPN service is still marked for deletion.'
    }
}

$vendorExecutable = Join-Path $InstallDirectory 'amneziawg.exe'
if (Test-Path -LiteralPath $vendorExecutable -PathType Leaf) {
    $hashPath = Join-Path $dataDirectory 'amneziawg-sha256'
    $wintunLibrary = Join-Path $InstallDirectory 'wintun.dll'
    $wintunHashPath = Join-Path $dataDirectory 'wintun-sha256'
    if (-not (Test-Path -LiteralPath $hashPath -PathType Leaf)) {
        throw 'The pinned AmneziaWG release hash is missing.'
    }
    if (-not (Test-Path -LiteralPath $wintunLibrary -PathType Leaf) -or
        -not (Test-Path -LiteralPath $wintunHashPath -PathType Leaf)) {
        throw 'The pinned Wintun release is missing.'
    }

    $expectedHash = [IO.File]::ReadAllText($hashPath).Trim()
    $actualHash = (Get-FileHash `
        -LiteralPath $vendorExecutable `
        -Algorithm SHA256).Hash
    if ($actualHash -ne $expectedHash) {
        throw 'The AmneziaWG executable failed its integrity check.'
    }

    $expectedWintunHash = [IO.File]::ReadAllText($wintunHashPath).Trim()
    $actualWintunHash = (Get-FileHash `
        -LiteralPath $wintunLibrary `
        -Algorithm SHA256).Hash
    if ($actualWintunHash -ne $expectedWintunHash) {
        throw 'The Wintun library failed its integrity check.'
    }

    # Windows can deny direct execution from WindowsApps during package
    # removal. Stage only the pinned runtime under the protected ProgramData
    # ACL, verify the copies again, then remove the staging directory.
    $stagingDirectory = Join-Path $dataDirectory 'uninstall-runtime'
    if (Test-Path -LiteralPath $stagingDirectory -PathType Container) {
        Remove-StagingDirectory -Path $stagingDirectory
    }
    New-Item -ItemType Directory -Path $stagingDirectory -Force | Out-Null
    $stagedVendorExecutable = Join-Path $stagingDirectory 'amneziawg.exe'
    $stagedWintunLibrary = Join-Path $stagingDirectory 'wintun.dll'
    Copy-Item `
        -LiteralPath $vendorExecutable `
        -Destination $stagedVendorExecutable `
        -Force
    Copy-Item `
        -LiteralPath $wintunLibrary `
        -Destination $stagedWintunLibrary `
        -Force

    if ((Get-FileHash `
            -LiteralPath $stagedVendorExecutable `
            -Algorithm SHA256).Hash -ne $expectedHash -or
        (Get-FileHash `
            -LiteralPath $stagedWintunLibrary `
            -Algorithm SHA256).Hash -ne $expectedWintunHash) {
        throw 'The staged AmneziaWG runtime failed its integrity check.'
    }

    $vendorService = Get-Service `
        -Name 'AmneziaWGTunnel$vex' `
        -ErrorAction SilentlyContinue
    try {
        if ($null -ne $vendorService) {
            $vendorService.Dispose()
            & $stagedVendorExecutable /uninstalltunnelservice vex | Out-Null
            $vendorExitCode = $LASTEXITCODE
            if ($vendorExitCode -ne 0) {
                throw "The AmneziaWG tunnel service could not be removed ($vendorExitCode)."
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $stagingDirectory -PathType Container) {
            Remove-StagingDirectory -Path $stagingDirectory
        }
    }
}
else {
    $vendorService = Get-Service `
        -Name 'AmneziaWGTunnel$vex' `
        -ErrorAction SilentlyContinue
    if ($null -ne $vendorService) {
        $vendorService.Dispose()
        throw 'The AmneziaWG runtime is missing while its tunnel service remains.'
    }
}

if (Test-Path -LiteralPath $dataDirectory -PathType Container) {
    Remove-Item -LiteralPath $dataDirectory -Recurse -Force
}
