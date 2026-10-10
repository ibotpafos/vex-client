[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InstallDirectory,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^S-1-(?:5-21|12-1)-(\d+-){3}\d+$')]
    [string]$OwnerSid,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$ClientCertificateSha256,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$AppExecutableSha256,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$ServiceExecutableSha256,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$AmneziaExecutableSha256,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$WintunSha256,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$ProfileSigningKeyringSha256
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security

$serviceName = 'VEX VPN Service'
$serviceControl = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'sc.exe'
$dataDirectory = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'VEX\VPN'
$serviceExecutable = Join-Path $InstallDirectory 'Vex.Windows.Service.exe'
$clientExecutable = Join-Path $InstallDirectory 'Vex.Windows.App.exe'
$amneziaExecutable = Join-Path $InstallDirectory 'amneziawg.exe'
$wintunLibrary = Join-Path $InstallDirectory 'wintun.dll'
$profileSigningKeyring = Join-Path `
    $InstallDirectory `
    'profile-signing-keys.json'
$requiredFiles = @(
    $serviceExecutable,
    $clientExecutable,
    $amneziaExecutable,
    $wintunLibrary,
    $profileSigningKeyring
)

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'VEX VPN service installation requires elevation.'
    }
}

function Assert-InstallPayload {
    $installRoot = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
    $programFilesRoot = [IO.Path]::GetFullPath(
        $env:ProgramFiles).TrimEnd('\') + '\'
    if (-not $installRoot.StartsWith(
        $programFilesRoot,
        [StringComparison]::OrdinalIgnoreCase)) {
        throw 'VEX must be installed below the protected Program Files directory.'
    }
    Assert-NoReparsePath -Path $installRoot

    foreach ($path in $requiredFiles) {
        Assert-NoReparsePath -Path $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required signed installation file is missing: $path"
        }
    }

    Assert-PinnedSignature -Path $clientExecutable -Description 'client'
    Assert-PinnedSignature -Path $serviceExecutable -Description 'service'
    Assert-FileHash `
        -Path $clientExecutable `
        -ExpectedHash $AppExecutableSha256 `
        -Description 'client executable'
    Assert-FileHash `
        -Path $serviceExecutable `
        -ExpectedHash $ServiceExecutableSha256 `
        -Description 'service executable'
    Assert-FileHash `
        -Path $amneziaExecutable `
        -ExpectedHash $AmneziaExecutableSha256 `
        -Description 'AmneziaWG executable'
    Assert-FileHash `
        -Path $wintunLibrary `
        -ExpectedHash $WintunSha256 `
        -Description 'Wintun library'
    Assert-FileHash `
        -Path $profileSigningKeyring `
        -ExpectedHash $ProfileSigningKeyringSha256 `
        -Description 'profile signing keyring'
}

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

function Get-PrivateStateItems {
    Assert-NoReparsePath -Path $dataDirectory
    if (-not (Test-Path -LiteralPath $dataDirectory)) { return }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($dataDirectory)
    $count = 0
    while ($pending.Count -gt 0) {
        $path = $pending.Pop()
        Assert-NoReparsePath -Path $path
        $item = Get-Item -LiteralPath $path -Force
        $count++
        if ($count -gt 10000) { throw 'The VEX private state tree is unexpectedly large.' }
        $item
        if ($item.PSIsContainer) {
            foreach ($child in @(Get-ChildItem -LiteralPath $path -Force)) { $pending.Push($child.FullName) }
        }
    }
}

function Stop-ServiceBeforeProvisioning {
    $existing = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($null -eq $existing) { return }
    try {
        if ($existing.Status -ne [ServiceProcess.ServiceControllerStatus]::Stopped) {
            Stop-Service -Name $serviceName -ErrorAction Stop
            $existing.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(30))
        }
    }
    finally { $existing.Dispose() }
}

function Test-PrivateRuntimePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $privateRoot = [IO.Path]::GetFullPath((Join-Path $dataDirectory 'Private')).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $fullPath = [IO.Path]::GetFullPath($Path)
    return $fullPath.Equals($privateRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($privateRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-PinnedSignature {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "The VEX Windows $Description Authenticode signature is invalid."
    }
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $certificateHash = [BitConverter]::ToString(
            $sha256.ComputeHash($signature.SignerCertificate.RawData)
        ).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
    if ($certificateHash -ne $ClientCertificateSha256.ToUpperInvariant()) {
        throw "The VEX Windows $Description signing certificate is not pinned."
    }
}

function Assert-FileHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedHash,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actualHash -ne $ExpectedHash.ToUpperInvariant()) {
        throw "The VEX $Description does not match the release manifest."
    }
}

function Wait-ServiceRemoved {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ([DateTime]::UtcNow -lt $deadline) {
        $candidate = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $candidate) {
            return
        }

        $candidate.Dispose()
        Start-Sleep -Milliseconds 250
    }

    throw "Windows service '$Name' is still marked for deletion."
}

function Set-PrivateDirectoryAcl {
    # Inspect the complete tree before changing any ACL or following a child.
    $existingItems = @(Get-PrivateStateItems)
    Assert-NoReparsePath -Path (Split-Path -Parent $dataDirectory)
    New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null
    $items = @((Get-Item -LiteralPath (Split-Path -Parent $dataDirectory) -Force)) + @(Get-PrivateStateItems)
    foreach ($item in $items) {
        $acl = if ($item.PSIsContainer) { [Security.AccessControl.DirectorySecurity]::new() }
               else { [Security.AccessControl.FileSecurity]::new() }
        $acl.SetAccessRuleProtection($true, $false)
        $administratorsSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
        $acl.SetOwner($administratorsSid)
        $inherit = if ($item.PSIsContainer) { [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' }
                   else { [Security.AccessControl.InheritanceFlags]::None }
        $identities = @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'))
        if (-not (Test-PrivateRuntimePath -Path $item.FullName)) { $identities += ,@($OwnerSid, 'ReadAndExecute') }
        foreach ($pair in $identities) {
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new($pair[0]), $pair[1], $inherit,
                [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
        }
        Assert-NoReparsePath -Path $item.FullName
        Set-Acl -LiteralPath $item.FullName -AclObject $acl
    }
}

function Assert-PrivateDirectoryAcl {
    foreach ($item in @((Get-Item -LiteralPath (Split-Path -Parent $dataDirectory) -Force)) + @(Get-PrivateStateItems)) {
        $acl = Get-Acl -LiteralPath $item.FullName
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18', 'S-1-5-32-544') -or
            -not $acl.AreAccessRulesProtected) { throw 'VEX state requires a trusted owner and protected access rules.' }
        $expected = @{
            'S-1-5-18' = [long][Security.AccessControl.FileSystemRights]::FullControl
            'S-1-5-32-544' = [long][Security.AccessControl.FileSystemRights]::FullControl
        }
        if (-not (Test-PrivateRuntimePath -Path $item.FullName)) {
            $expected[$OwnerSid] = [long]([Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [Security.AccessControl.FileSystemRights]::Synchronize)
        }
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        if ($rules.Count -ne $expected.Count) { throw 'VEX state has unexpected access rules.' }
        foreach ($rule in $rules) {
            $sid = $rule.IdentityReference.Value
            if (-not $expected.ContainsKey($sid) -or $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
                [long]$rule.FileSystemRights -ne $expected[$sid]) { throw 'VEX state has unexpected access rights.' }
            $expected.Remove($sid)
        }
        if ($expected.Count -ne 0) { throw 'VEX state is missing required access rules.' }
    }
}

function Write-ProtectedAuthorization {
    $token = [byte[]]::new(32)
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    $random.GetBytes($token)
    $random.Dispose()
    $entropy = [Text.Encoding]::UTF8.GetBytes('VEX VPN IPC v1')
    try {
        $protectedToken = [Security.Cryptography.ProtectedData]::Protect(
            $token,
            $entropy,
            [Security.Cryptography.DataProtectionScope]::LocalMachine)
        [IO.File]::WriteAllBytes(
            (Join-Path $dataDirectory 'ipc-token.bin'),
            $protectedToken)
    }
    finally {
        for ($index = 0; $index -lt $token.Length; $index += 1) {
            $token[$index] = 0
        }
    }
}

function Write-Pin {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    [IO.File]::WriteAllText(
        (Join-Path $dataDirectory $Name),
        $Value.ToUpperInvariant())
}

function Write-ClientAttestationPins {
    $registryPath = 'HKLM:\SOFTWARE\VEX\VPN'
    New-Item -Path $registryPath -Force | Out-Null
    Set-ItemProperty `
        -Path $registryPath `
        -Name 'ClientCertificateSha256' `
        -Type String `
        -Value $ClientCertificateSha256.ToUpperInvariant()
    Set-ItemProperty `
        -Path $registryPath `
        -Name 'ServiceExecutableSha256' `
        -Type String `
        -Value $ServiceExecutableSha256.ToUpperInvariant()
}

function Install-Service {
    $binaryPath = '"' + $serviceExecutable + '"'
    $existing = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        $existing.Dispose()
        & $serviceControl config $serviceName binPath= $binaryPath start= auto obj= LocalSystem |
            Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'The existing VEX VPN service configuration could not be updated.'
        }
    }
    else {
        & $serviceControl create $serviceName binPath= $binaryPath start= auto obj= LocalSystem |
            Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'The VEX VPN service could not be installed.'
        }
    }

    & $serviceControl description $serviceName 'Native VEX VPN tunnel controller.' |
        Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'The VEX service description could not be configured.' }
    & $serviceControl failure $serviceName reset= 86400 actions= restart/5000/restart/15000/''/0 |
        Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'The VEX service recovery actions could not be configured.' }
    & $serviceControl failureflag $serviceName 1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'The VEX service recovery flag could not be configured.' }
    Set-ItemProperty `
        -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName" `
        -Name ImagePath `
        -Value ('"{0}"' -f $serviceExecutable) `
        -Type ExpandString
    Set-ItemProperty `
        -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName" `
        -Name DelayedAutoStart `
        -Type DWord `
        -Value 1
    Start-Service -Name $serviceName
    $service = Get-Service -Name $serviceName -ErrorAction Stop
    try {
        $service.WaitForStatus(
            [ServiceProcess.ServiceControllerStatus]::Running,
            [TimeSpan]::FromSeconds(30))
    }
    finally {
        $service.Dispose()
    }
}

Assert-Administrator
Assert-InstallPayload
$null = @(Get-PrivateStateItems)
Stop-ServiceBeforeProvisioning
Set-PrivateDirectoryAcl
Assert-PrivateDirectoryAcl
Write-ProtectedAuthorization
Write-Pin -Name 'client-cert-sha256' -Value $ClientCertificateSha256
Write-ClientAttestationPins
[IO.File]::WriteAllText(
    (Join-Path $dataDirectory 'owner-sid'),
    $OwnerSid)
Write-Pin -Name 'app-executable-sha256' -Value $AppExecutableSha256
Write-Pin -Name 'service-executable-sha256' -Value $ServiceExecutableSha256
Write-Pin -Name 'amneziawg-sha256' -Value $AmneziaExecutableSha256
Write-Pin -Name 'wintun-sha256' -Value $WintunSha256
Write-Pin `
    -Name 'profile-signing-keys-sha256' `
    -Value $ProfileSigningKeyringSha256
$state = [ordered]@{
    schema = 'vex.windows-service-bootstrap.v1'
    provisioned_at = [DateTimeOffset]::UtcNow.ToString('O')
    owner_sid = $OwnerSid
    client_certificate_sha256 = $ClientCertificateSha256.ToUpperInvariant()
    app_executable_sha256 = $AppExecutableSha256.ToUpperInvariant()
    service_executable_sha256 = $ServiceExecutableSha256.ToUpperInvariant()
    amneziawg_sha256 = $AmneziaExecutableSha256.ToUpperInvariant()
    wintun_sha256 = $WintunSha256.ToUpperInvariant()
    profile_signing_keyring_sha256 =
        $ProfileSigningKeyringSha256.ToUpperInvariant()
}
[IO.File]::WriteAllText(
    (Join-Path $dataDirectory 'bootstrap-state.json'),
    ($state | ConvertTo-Json -Depth 4),
    [Text.UTF8Encoding]::new($false))
# Newly written files must receive the same explicit private ACL as existing
# state before the controller can observe the replacement authorization.
Set-PrivateDirectoryAcl
Assert-PrivateDirectoryAcl
Install-Service
