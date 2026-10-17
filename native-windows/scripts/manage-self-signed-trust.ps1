[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CertificatePath,
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedCertificateSha256,
    [Parameter(Mandatory = $true)][ValidateSet('Install', 'Verify', 'Remove')][string]$Action
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Certificate trust changes are supported only on Windows.'
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open PowerShell as administrator to manage machine-wide VEX certificate trust.'
}
$file = Get-Item -LiteralPath $CertificatePath -Force
if ($file.PSIsContainer -or $file.Length -le 0 -or $file.Length -gt 16384 -or
    ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'The public certificate must be an ordinary bounded DER .cer file.'
}
$inputFile = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
$certificate = $null
try {
    $bytes = [byte[]]::new([int]$inputFile.Length)
    $offset = 0
    while ($offset -lt $bytes.Length) {
        $count = $inputFile.Read($bytes, $offset, $bytes.Length - $offset)
        if ($count -eq 0) { throw 'The certificate was truncated.' }
        $offset += $count
    }
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { $pin = [BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace('-', '') }
    finally { $sha256.Dispose() }
    if ($pin -ine $ExpectedCertificateSha256) { throw 'The public certificate SHA-256 differs from the supplied VEX pin.' }
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes)
    if ($certificate.HasPrivateKey -or $certificate.RawData.Length -ne $bytes.Length -or
        $certificate.Subject -cne 'CN=VEX VPN Self-Signed Native' -or
        $certificate.Subject -cne $certificate.Issuer) {
        throw 'Only the public VEX self-signed code-signing certificate is accepted.'
    }
    $constraints = @($certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.19' })
    $usage = @($certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.15' })
    $eku = @($certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' })
    if ($constraints.Count -ne 1 -or $constraints[0].CertificateAuthority -or
        $usage.Count -ne 1 -or $usage[0].KeyUsages -ne [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -or
        $eku.Count -ne 1 -or $eku[0].EnhancedKeyUsages.Count -ne 1 -or
        $eku[0].EnhancedKeyUsages[0].Value -cne '1.3.6.1.5.5.7.3.3') {
        throw 'VEX trust requires a non-CA certificate restricted to code signing.'
    }
    if ($Action -eq 'Install' -and
        ([DateTime]::UtcNow -lt $certificate.NotBefore.ToUniversalTime() -or
         [DateTime]::UtcNow -gt $certificate.NotAfter.ToUniversalTime())) {
        throw 'The certificate is outside its validity period.'
    }
    # Root is needed by WinVerifyTrust/PowerShell; TrustedPeople by MSIX;
    # TrustedPublisher prevents an interactive publisher prompt for signed scripts.
    # The exact non-CA code-signing leaf is added, never a general-purpose CA.
    foreach ($name in @('Root', 'TrustedPeople', 'TrustedPublisher')) {
        $store = [Security.Cryptography.X509Certificates.X509Store]::new($name, 'LocalMachine')
        try {
            $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            $matches = @($store.Certificates | Where-Object Thumbprint -EQ $certificate.Thumbprint)
            if ($Action -eq 'Install') { $store.Add($certificate) }
            elseif ($Action -eq 'Remove') { foreach ($match in $matches) { $store.Remove($match) } }
            elseif ($matches.Count -ne 1) { throw "VEX certificate trust is missing from LocalMachine/$name." }
        }
        finally { $store.Close() }
    }
    Write-Output "VEX certificate trust $Action completed for SHA-256 $pin."
}
finally {
    if ($null -ne $certificate) { $certificate.Dispose() }
    $inputFile.Dispose()
}
