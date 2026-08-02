[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InstallDirectory,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^S-1-5-21-(\d+-){3}\d+$')]
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
$dataDirectory = Join-Path $env:ProgramData 'VEX\VPN'
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
    $installInfo = Get-Item -LiteralPath $installRoot
    if (($installInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The VEX installation directory cannot be a reparse point.'
    }

    foreach ($path in $requiredFiles) {
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
    New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)

    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $systemSid = [Security.Principal.SecurityIdentifier]::new(
        [Security.Principal.WellKnownSidType]::LocalSystemSid,
        $null)
    $administratorsSid = [Security.Principal.SecurityIdentifier]::new(
        [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,
        $null)
    $ownerIdentity = [Security.Principal.SecurityIdentifier]::new(
        $OwnerSid)
    $rules = @(
        [Security.AccessControl.FileSystemAccessRule]::new(
            $systemSid, 'FullControl', $inherit, $propagation, $allow),
        [Security.AccessControl.FileSystemAccessRule]::new(
            $administratorsSid, 'FullControl', $inherit, $propagation, $allow),
        [Security.AccessControl.FileSystemAccessRule]::new(
            $ownerIdentity, 'ReadAndExecute', $inherit, $propagation, $allow)
    )
    foreach ($rule in $rules) {
        $acl.AddAccessRule($rule)
    }

    Set-Acl -LiteralPath $dataDirectory -AclObject $acl
}

function Assert-PrivateDirectoryAcl {
    $acl = Get-Acl -LiteralPath $dataDirectory
    if (-not $acl.AreAccessRulesProtected) {
        throw 'The VEX ProgramData directory still inherits access rules.'
    }

    $expectedSids = @(
        'S-1-5-18',
        'S-1-5-32-544',
        $OwnerSid
    )
    $actualSids = @(
        $acl.Access |
            Where-Object {
                $_.AccessControlType -eq
                    [Security.AccessControl.AccessControlType]::Allow
            } |
            ForEach-Object {
                $_.IdentityReference.Translate(
                    [Security.Principal.SecurityIdentifier]).Value
            }
    )
    foreach ($expectedSid in $expectedSids) {
        if ($expectedSid -notin $actualSids) {
            throw "The VEX ProgramData ACL is missing SID '$expectedSid'."
        }
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
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        $existing.Dispose()
        & sc.exe config $serviceName binPath= $binaryPath start= auto obj= LocalSystem |
            Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'The existing VEX VPN service configuration could not be updated.'
        }
    }
    else {
        & sc.exe create $serviceName binPath= $binaryPath start= auto obj= LocalSystem |
            Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'The VEX VPN service could not be installed.'
        }
    }

    & sc.exe description $serviceName 'Native VEX VPN tunnel controller.' |
        Out-Null
    & sc.exe failure $serviceName reset= 86400 actions= restart/5000/restart/15000/''/0 |
        Out-Null
    & sc.exe failureflag $serviceName 1 | Out-Null
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
Install-Service
