$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-WindowsTesterSigningIdentity {
    param(
        [string]$Directory = (Join-Path $PSScriptRoot 'tester-trust'),
        [Parameter(Mandatory = $true)][string]$ExpectedRootSha256,
        [Parameter(Mandatory = $true)][string]$ExpectedLeafSha256,
        [Parameter(Mandatory = $true)][string]$Publisher
    )
    if ($ExpectedRootSha256 -notmatch '^[a-fA-F0-9]{64}$' -or $ExpectedLeafSha256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw 'Tester signing requires exact root and leaf SHA-256 pins.'
    }
    $certificates = @()
    try {
        foreach ($name in @('VEX-Tester-Root.cer', 'VEX-Tester-Signing.cer')) {
            $path = Join-Path $Directory $name
            $file = Get-Item -LiteralPath $path
            if ($file.PSIsContainer -or $file.Length -lt 256 -or $file.Length -gt 16384 -or
                ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Tester trust accepts only bounded regular public DER certificates.'
            }
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes)
            $certificates += $certificate
            if ($certificate.HasPrivateKey -or [Convert]::ToBase64String($certificate.RawData) -cne [Convert]::ToBase64String($bytes)) {
                throw 'Tester trust cannot contain a private key or noncanonical certificate data.'
            }
            if ($certificate.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow -or
                $certificate.NotAfter.ToUniversalTime() -lt [DateTime]::UtcNow.AddDays(7)) {
                throw 'Tester signing certificates must be currently valid with at least seven days remaining.'
            }
            $eku = @($certificate.Extensions | Where-Object { $_.Oid.Value -ceq '2.5.29.37' })
            if ($eku.Count -ne 1 -or -not $eku[0].Critical -or $eku[0].EnhancedKeyUsages.Count -ne 1 -or
                $eku[0].EnhancedKeyUsages[0].Value -cne '1.3.6.1.5.5.7.3.3') {
                throw 'Tester certificates must be restricted to code signing, including the root authority.'
            }
            $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certificate)
            try {
                if ($null -eq $rsa -or $rsa.KeySize -lt 3072 -or $certificate.SignatureAlgorithm.Value -cne '1.2.840.113549.1.1.11') {
                    throw 'Tester signing requires RSA-3072 or stronger with SHA-256 signatures.'
                }
            }
            finally { if ($null -ne $rsa) { $rsa.Dispose() } }
        }
        $root, $leaf = $certificates
        $rootPin = $root.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256)
        $leafPin = $leaf.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256)
        if ($rootPin -ine $ExpectedRootSha256 -or $leafPin -ine $ExpectedLeafSha256 -or
            $leaf.Subject -cne $Publisher -or $leaf.Issuer -cne $root.Subject -or $root.Subject -cne $root.Issuer) {
            throw 'Tester signing identity or pinned certificate chain differs from the reviewed release inputs.'
        }
        $rootConstraints = @($root.Extensions | Where-Object { $_.Oid.Value -ceq '2.5.29.19' })
        $leafConstraints = @($leaf.Extensions | Where-Object { $_.Oid.Value -ceq '2.5.29.19' })
        if ($rootConstraints.Count -ne 1 -or -not $rootConstraints[0].Critical -or
            -not $rootConstraints[0].CertificateAuthority -or -not $rootConstraints[0].HasPathLengthConstraint -or
            $rootConstraints[0].PathLengthConstraint -ne 0 -or $leafConstraints.Count -ne 1 -or
            -not $leafConstraints[0].Critical -or $leafConstraints[0].CertificateAuthority) {
            throw 'Tester trust requires a restricted root CA and an end-entity signing certificate.'
        }
        $rootUsage = @($root.Extensions | Where-Object { $_.Oid.Value -ceq '2.5.29.15' })
        $leafUsage = @($leaf.Extensions | Where-Object { $_.Oid.Value -ceq '2.5.29.15' })
        if ($rootUsage.Count -ne 1 -or $leafUsage.Count -ne 1 -or
            $rootUsage[0].KeyUsages -ne ([Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign -bor
                [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::CrlSign) -or
            $leafUsage[0].KeyUsages -ne [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature) {
            throw 'Tester certificate key usages exceed the reviewed signing purpose.'
        }
        $chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
        try {
            # Verify the pinned public identity before any store mutation. Native
            # Authenticode/WinVerifyTrust checks remain unchanged after import.
            $chain.ChainPolicy.TrustMode = [Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
            $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
            [void]$chain.ChainPolicy.CustomTrustStore.Add($root)
            [void]$chain.ChainPolicy.ApplicationPolicy.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
            if (-not $chain.Build($leaf)) { throw 'The pinned tester code-signing chain is invalid.' }
        }
        finally { $chain.Dispose() }
        return [pscustomobject]@{
            RootPath = Join-Path $Directory 'VEX-Tester-Root.cer'; LeafPath = Join-Path $Directory 'VEX-Tester-Signing.cer'
            RootSha256 = $rootPin; LeafSha256 = $leafPin; RootThumbprint = $root.Thumbprint; LeafThumbprint = $leaf.Thumbprint
            Publisher = $leaf.Subject
        }
    }
    finally { foreach ($certificate in $certificates) { $certificate.Dispose() } }
}

function Get-WindowsTesterReleaseAssets {
    param([Parameter(Mandatory = $true)]$Metadata, [Parameter(Mandatory = $true)][string]$Directory)
    $modeProperty = $Metadata.PSObject.Properties['signing_mode']
    $mode = if ($null -eq $modeProperty) { 'public-trusted' } else { $modeProperty.Value }
    Assert-WindowsTesterSigningScope -Channel $Metadata.channel -Mode $mode -LeafSha256 $Metadata.client_certificate_sha256
    if ($mode -ceq 'public-trusted') { return }
    $identity = Get-WindowsTesterSigningIdentity -ExpectedRootSha256 $Metadata.tester_root_sha256 `
        -ExpectedLeafSha256 $Metadata.tester_leaf_sha256 -Publisher $Metadata.publisher
    if ($identity.LeafSha256 -ine $Metadata.client_certificate_sha256) { throw 'Tester metadata signer differs from its public signing certificate.' }
    $descriptors = @($Metadata.tester_trust_files)
    $names = @('VEX-Tester-Root.cer', 'VEX-Tester-Signing.cer', 'TESTER-INSTALL.txt')
    if ($descriptors.Count -ne $names.Count) { throw 'The tester release must include exactly its two public certificates and install guide.' }
    foreach ($name in $names) {
        $matching = @($descriptors | Where-Object { $_.file -ceq $name })
        if ($matching.Count -ne 1) { throw 'Tester release trust descriptors are missing or duplicated.' }
        $file = Get-Item -LiteralPath (Join-Path $Directory $name)
        if ($file.PSIsContainer -or $file.Length -gt 16384 -or $file.Length -le 0 -or
            ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $matching[0].size_bytes -ne $file.Length -or
            $matching[0].sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid tester public trust asset.' }
        $actual = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        $reviewed = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot "tester-trust/$name") -Algorithm SHA256).Hash
        if ($actual -ine $matching[0].sha256 -or $actual -ine $reviewed) { throw 'Tester trust asset differs from the reviewed public file.' }
        $file.FullName
    }
}

function Assert-WindowsTesterSigningScope {
    param([string]$Channel, [string]$Mode, [string]$LeafSha256)
    if ($Mode -cnotin @('public-trusted', 'tester-ca')) { throw 'Unsupported Windows signing mode.' }
    if ($Mode -ceq 'tester-ca' -and $Channel -cne 'beta') { throw 'Tester signing is restricted to the beta channel.' }
    $identity = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'tester-trust/identity.json') -Raw | ConvertFrom-Json
    if ($LeafSha256 -and $LeafSha256 -ieq $identity.leaf_sha256 -and ($Mode -cne 'tester-ca' -or $Channel -cne 'beta')) {
        throw 'The tester certificate cannot sign a public stable release.'
    }
    if ($Mode -ceq 'tester-ca' -and $LeafSha256 -and $LeafSha256 -ine $identity.leaf_sha256) {
        throw 'The beta signing PFX does not match the pinned tester certificate.'
    }
}
