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
$serviceControl = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'sc.exe'
$dataDirectory = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'VEX\VPN'

function Assert-NoReparsePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $candidate = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrEmpty($candidate)) {
        if (Test-Path -LiteralPath $candidate) {
            $item = Get-Item -LiteralPath $candidate -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                ($null -ne $item.PSObject.Properties['LinkType'] -and $item.LinkType -eq 'HardLink')) {
                throw 'The VEX installation and state paths cannot contain links or reparse points.'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($candidate)
        if ($parent -eq $candidate) { break }
        $candidate = $parent
    }
}

function Assert-RemovalState {
    Assert-NoReparsePath -Path $dataDirectory
    if (-not (Test-Path -LiteralPath $dataDirectory -PathType Container)) {
        throw 'The protected VEX removal state is missing. Repair it before removing the service.'
    }
    $ownerPath = Join-Path $dataDirectory 'owner-sid'
    Assert-NoReparsePath -Path $ownerPath
    $ownerSid = [IO.File]::ReadAllText($ownerPath).Trim()
    if ($ownerSid -notmatch '^S-1-(?:5-21|12-1)-(\d+-){3}\d+$') { throw 'The VEX removal owner is invalid.' }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($dataDirectory)
    $parentDirectory = Split-Path -Parent $dataDirectory
    $pending.Push($parentDirectory)
    $count = 0
    while ($pending.Count -gt 0) {
        $path = $pending.Pop()
        Assert-NoReparsePath -Path $path
        $item = Get-Item -LiteralPath $path -Force
        if (++$count -gt 10000) { throw 'The VEX private state tree is unexpectedly large.' }
        $acl = Get-Acl -LiteralPath $path
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18', 'S-1-5-32-544') -or
            ($path -in @($dataDirectory, $parentDirectory) -and -not $acl.AreAccessRulesProtected)) {
            throw 'VEX removal state does not have a trusted owner and protected root.'
        }
        $expected = @{
            'S-1-5-18' = [long][Security.AccessControl.FileSystemRights]::FullControl
            'S-1-5-32-544' = [long][Security.AccessControl.FileSystemRights]::FullControl
        }
        if (-not (Test-PrivateRuntimePath -Path $path)) {
            $expected[$ownerSid] = [long]([Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [Security.AccessControl.FileSystemRights]::Synchronize)
        }
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        if ($rules.Count -ne $expected.Count) { throw 'VEX removal state has unexpected access rules.' }
        foreach ($rule in $rules) {
            $sid = $rule.IdentityReference.Value
            if (-not $expected.ContainsKey($sid) -or $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
                [long]$rule.FileSystemRights -ne $expected[$sid]) { throw 'VEX removal state has unexpected access rights.' }
            $expected.Remove($sid)
        }
        if ($expected.Count -ne 0) { throw 'VEX removal state is missing required access rules.' }
        if ($item.PSIsContainer -and $path -ne $parentDirectory) {
            foreach ($child in @(Get-ChildItem -LiteralPath $path -Force)) { $pending.Push($child.FullName) }
        }
    }
}

function Test-PrivateRuntimePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $privateRoot = [IO.Path]::GetFullPath((Join-Path $dataDirectory 'Private')).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $fullPath = [IO.Path]::GetFullPath($Path)
    return $fullPath.Equals($privateRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($privateRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Wait-ServiceRemoved {
    param([Parameter(Mandatory = $true)][string]$Name, [int]$TimeoutSeconds = 20)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $service) { return }
        $service.Dispose()
        if ([DateTime]::UtcNow -ge $deadline) { throw 'The VEX-owned Windows service remains after removal.' }
        Start-Sleep -Milliseconds 250
    } while ($true)
}

function Get-OwnedMachinePins {
    param([switch]$Remove)
    $expected = @{
        ClientCertificateSha256 = [IO.File]::ReadAllText((Join-Path $dataDirectory 'client-cert-sha256')).Trim()
        ServiceExecutableSha256 = [IO.File]::ReadAllText((Join-Path $dataDirectory 'service-executable-sha256')).Trim()
    }
    $machine = Open-MachinePinRegistry
    try {
        $key = $machine.OpenSubKey((Get-MachinePinRegistryPath), [bool]$Remove)
        if ($null -eq $key) { return }
        try {
            foreach ($name in $expected.Keys) {
                $value = $key.GetValue($name)
                if ($null -ne $value -and ($value -isnot [string] -or $expected[$name] -notmatch '^[0-9A-Fa-f]{64}$' -or
                    $value -ne $expected[$name])) { throw 'Foreign VEX machine attestation pins will not be removed.' }
            }
            if ($Remove) {
                foreach ($name in $expected.Keys) { $key.DeleteValue($name, $false) }
            }
        }
        finally { $key.Dispose() }
    }
    finally { $machine.Dispose() }
}

function Open-MachinePinRegistry {
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
}

function Get-MachinePinRegistryPath { return 'SOFTWARE\VEX\VPN' }

function Invoke-VendorRemoval {
    param([Parameter(Mandatory = $true)][string]$Executable)
    $process = Start-Process -FilePath $Executable -ArgumentList '/uninstalltunnelservice vex' `
        -PassThru -WindowStyle Hidden -ErrorAction Stop
    try {
        if (-not $process.WaitForExit(30000)) {
            try { $process.Kill(); $null = $process.WaitForExit(5000) } catch { }
            throw 'The owned AmneziaWG removal process exceeded its deadline.'
        }
        if ($process.ExitCode -ne 0) { throw 'The owned AmneziaWG removal process failed.' }
    }
    finally { $process.Dispose() }
}

function Assert-RemovalRuntime {
    $vendor = Join-Path $InstallDirectory 'amneziawg.exe'
    if (Test-Path -LiteralPath $vendor -PathType Leaf) {
        foreach ($pair in @(@($vendor, 'amneziawg-sha256'), @((Join-Path $InstallDirectory 'wintun.dll'), 'wintun-sha256'))) {
            Assert-NoReparsePath -Path $pair[0]
            $expected = [IO.File]::ReadAllText((Join-Path $dataDirectory $pair[1])).Trim()
            if ($expected -notmatch '^[0-9A-Fa-f]{64}$' -or (Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash -ne $expected) {
                throw 'The VEX removal runtime does not match its protected release pins.'
            }
        }
    }
    else {
        $vendorService = Get-Service -Name 'AmneziaWGTunnel$vex' -ErrorAction SilentlyContinue
        if ($null -ne $vendorService) {
            $vendorService.Dispose()
            throw 'The AmneziaWG runtime is missing while its tunnel service remains.'
        }
    }
}

function Remove-StagingDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (Test-Path -LiteralPath $Path) {
        try {
            Assert-NoReparsePath -Path $Path
            foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force)) { Assert-NoReparsePath -Path $child.FullName }
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
Assert-NoReparsePath -Path $installRoot
Assert-RemovalState
Get-OwnedMachinePins
Assert-RemovalRuntime

$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($null -ne $service) {
    try {
        if ($service.Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped) {
            Stop-Service -Name $serviceName -ErrorAction Stop
            $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(30))
        }
    }
    finally { $service.Dispose() }
    $service = $null
    & $serviceControl delete $serviceName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'The VEX VPN service could not be removed.'
    }

    Wait-ServiceRemoved -Name $serviceName
}

$vendorExecutable = Join-Path $InstallDirectory 'amneziawg.exe'
if (Test-Path -LiteralPath $vendorExecutable -PathType Leaf) {
    Assert-NoReparsePath -Path $vendorExecutable
    $hashPath = Join-Path $dataDirectory 'amneziawg-sha256'
    $wintunLibrary = Join-Path $InstallDirectory 'wintun.dll'
    $wintunHashPath = Join-Path $dataDirectory 'wintun-sha256'
    Assert-NoReparsePath -Path $wintunLibrary
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
            Invoke-VendorRemoval -Executable $stagedVendorExecutable
            Wait-ServiceRemoved -Name 'AmneziaWGTunnel$vex'
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
    # Keep the trusted cleanup pins until every owned service is confirmed gone.
    Wait-ServiceRemoved -Name $serviceName
    Wait-ServiceRemoved -Name 'AmneziaWGTunnel$vex'
    Assert-RemovalState
    Get-OwnedMachinePins -Remove
    Remove-Item -LiteralPath $dataDirectory -Recurse -Force
}
