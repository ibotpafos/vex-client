#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][switch]$DisposableRunner,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$OutputRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $DisposableRunner -or -not $IsWindows -or $env:GITHUB_ACTIONS -cne 'true' -or
    $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or
    $env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or
    $env:GITHUB_REPOSITORY -cne 'ibotpafos/vex-client' -or
    [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw 'Self-signed packaging requires an explicit manual run on a disposable Windows runner.'
}
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $root 'native-windows/packaging/ReleaseValidation.ps1')
$normalizedVersion = ConvertTo-WindowsPackageVersion $Version
$credentialDirectory = Join-Path $env:RUNNER_TEMP ('vex-self-signed-private-' + [Guid]::NewGuid().ToString('N'))
$publicCertificate = Join-Path $root 'native-windows/packaging/self-signed/VEX-Windows-SelfSigned.cer'
$certificatePin = '74A7015F870A4E50654796E8DE46C9D213065C9BF616018F0C94D3F5A3D9E0A0'
$trustScript = Join-Path $PSScriptRoot 'manage-self-signed-trust.ps1'
$environmentNames = @('VEX_WINDOWS_SIGN_PFX_BASE64', 'VEX_WINDOWS_SIGN_PFX_PASSWORD',
    'VEX_WINDOWS_UPDATE_PRIVATE_KEY_BASE64', 'VEX_WINDOWS_UPDATE_PUBLIC_KEY_BASE64')
$trustInstalled = $false
$receipt = [ordered]@{
    schema = 'vex.windows-self-signed-acceptance.v1'
    certificate_sha256 = $certificatePin
    disposable_windows_runner = $true
    untrusted_before_import = $false
    valid_after_import = $false
    tampered_signature_rejected = $false
    wrong_certificate_pin_rejected = $false
    trust_removed_after_check = $false
    passed = $false
}
try {
    [IO.Directory]::CreateDirectory($credentialDirectory) | Out-Null
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl',
            'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $credentialDirectory -AclObject $acl
    foreach ($pair in @(
        @('VEX_WINDOWS_SIGN_PFX_BASE64', 'VEX_WINDOWS_SELF_SIGNED_PFX_BASE64'),
        @('VEX_WINDOWS_SIGN_PFX_PASSWORD', 'VEX_WINDOWS_SELF_SIGNED_PFX_PASSWORD'),
        @('VEX_WINDOWS_UPDATE_PRIVATE_KEY_BASE64', 'VEX_WINDOWS_SELF_SIGNED_UPDATE_PRIVATE_KEY_BASE64'),
        @('VEX_WINDOWS_UPDATE_PUBLIC_KEY_BASE64', 'VEX_WINDOWS_SELF_SIGNED_UPDATE_PUBLIC_KEY_BASE64'))) {
        $value = [Environment]::GetEnvironmentVariable($pair[1])
        if ([string]::IsNullOrWhiteSpace($value)) { throw 'A protected self-signed candidate signing input is missing.' }
        [Environment]::SetEnvironmentVariable($pair[0], $value)
    }
    $pfxPath = Join-Path $credentialDirectory 'signing.pfx'
    [IO.File]::WriteAllBytes($pfxPath, [Convert]::FromBase64String($env:VEX_WINDOWS_SIGN_PFX_BASE64))
    $signer = [Security.Cryptography.X509Certificates.X509Certificate2]::new($pfxPath,
        $env:VEX_WINDOWS_SIGN_PFX_PASSWORD, [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    try {
        if (-not $signer.HasPrivateKey -or $signer.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256) -cne $certificatePin) {
            throw 'Candidate signing key differs from the public certificate pin.'
        }
        $probe = Join-Path $credentialDirectory 'signature-probe.ps1'
        [IO.File]::WriteAllText($probe, "Write-Output 'VEX signature probe'`n", [Text.UTF8Encoding]::new($false))
        $signature = Set-AuthenticodeSignature -LiteralPath $probe -Certificate $signer -HashAlgorithm SHA256
        if ($signature.Status -ne [Management.Automation.SignatureStatus]::NotTrusted) {
            throw 'The fresh runner must reject VEX self-signed code before explicit trust installation.'
        }
        $receipt.untrusted_before_import = $true
    }
    finally { $signer.Dispose() }
    & $trustScript -CertificatePath $publicCertificate -ExpectedCertificateSha256 $certificatePin -Action Install
    $trustInstalled = $true
    & $trustScript -CertificatePath $publicCertificate -ExpectedCertificateSha256 $certificatePin -Action Verify
    if ((Get-AuthenticodeSignature -LiteralPath $probe).Status -ne [Management.Automation.SignatureStatus]::Valid) {
        throw 'Authenticode did not accept the pinned code-signing certificate after trust installation.'
    }
    $receipt.valid_after_import = $true
    [IO.File]::AppendAllText($probe, "Write-Output 'altered'`n", [Text.UTF8Encoding]::new($false))
    if ((Get-AuthenticodeSignature -LiteralPath $probe).Status -ne [Management.Automation.SignatureStatus]::HashMismatch) {
        throw 'Authenticode did not reject tampered self-signed code.'
    }
    $receipt.tampered_signature_rejected = $true
    try {
        & $trustScript -CertificatePath $publicCertificate -ExpectedCertificateSha256 ('0' * 64) -Action Install
    }
    catch { $receipt.wrong_certificate_pin_rejected = $true }
    if (-not $receipt.wrong_certificate_pin_rejected) { throw 'Wrong certificate pin was accepted.' }

    # This identity and local-only publication tree cannot replace stable VEX installs.
    $env:VEX_WINDOWS_PACKAGE_NAME = 'VEX.Native.SelfSigned'
    $env:VEX_WINDOWS_PACKAGE_DISPLAY_NAME = 'VEX VPN'
    $env:VEX_WINDOWS_PACKAGE_PUBLISHER = 'CN=VEX VPN Self-Signed Native'
    $env:VEX_WINDOWS_PACKAGE_PUBLISHER_DISPLAY_NAME = 'VEX VPN'
    $env:VEX_WINDOWS_UPDATE_KEY_ID = 'windows-selfsigned-20261014'
    $env:VEX_WINDOWS_RELEASE_CHANNEL = 'stable'
    $env:VEX_WINDOWS_RELEASE_VERSION = $normalizedVersion
    $env:VEX_WINDOWS_UPDATE_ORIGIN = 'https://vexvpn.app'
    $env:VEX_WINDOWS_PACKAGE_BASE_URI = 'https://vexvpn.app/self-signed-candidate/'
    $env:VEX_WINDOWS_APPINSTALLER_BASE_URI = $env:VEX_WINDOWS_PACKAGE_BASE_URI
    $env:VEX_WINDOWS_MANIFEST_REVISION = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString()
    $env:VEX_WINDOWS_RELEASE_NOTES = 'Прямой доступ к российским сайтам с сохранением защиты от утечек.'
    $env:VEX_WINDOWS_ROLLOUT_PERCENT = '0'
    $env:VEX_WINDOWS_UPDATE_REQUIRED = 'false'

    # Extract the exact qualified vendor MSIs administratively; no vendor service
    # is installed. Preserve vendor Authenticode and Microsoft driver signatures.
    $vendorHashes = @{
        x64 = 'a1b48ea8699cd347832a3691d832004574ef8ad65bcf887611ac8acb99b7de8b'
        arm64 = '3aec023884944890fac151f9cd4be3e92d39f9987c49da248837529c006ea2aa'
    }
    foreach ($architecture in @('x64', 'arm64')) {
        $vendorArchitecture = if ($architecture -eq 'x64') { 'amd64' } else { 'arm64' }
        $msi = Join-Path $credentialDirectory "$architecture.msi"
        Invoke-WebRequest -Uri "https://github.com/amnezia-vpn/amneziawg-windows-client/releases/download/3.1.0/amneziawg-$vendorArchitecture-3.1.0.msi" -OutFile $msi -TimeoutSec 90
        if ((Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash -ine $vendorHashes[$architecture]) { throw 'Qualified vendor MSI hash mismatch.' }
        $extracted = Join-Path $credentialDirectory "vendor-$architecture"
        $process = Start-Process -FilePath "$env:SystemRoot/System32/msiexec.exe" -ArgumentList @('/a', "`"$msi`"", '/qn', "TARGETDIR=`"$extracted`"") -PassThru
        try {
            if (-not $process.WaitForExit(120000)) { $process.Kill(); throw 'Vendor extraction exceeded its deadline.' }
            if ($process.ExitCode -ne 0) { throw 'Qualified vendor extraction failed.' }
        }
        finally { $process.Dispose() }
        foreach ($asset in @(@('AMNEZIAWG', 'amneziawg.exe'), @('WINTUN', 'wintun.dll'))) {
            $matches = @(Get-ChildItem -LiteralPath $extracted -Filter $asset[1] -File -Recurse)
            if ($matches.Count -ne 1) { throw 'Qualified vendor runtime extraction is ambiguous.' }
            Assert-WindowsPeArchitecture -Path $matches[0].FullName -Architecture $architecture
            [Environment]::SetEnvironmentVariable("VEX_WINDOWS_SERVICE_$($asset[0])_PATH_$($architecture.ToUpperInvariant())", $matches[0].FullName)
        }
    }
    & (Join-Path $PSScriptRoot 'stage-runtime-assets.ps1') -DestinationRoot (Join-Path $credentialDirectory 'runtime')
    $packagesRoot = Join-Path $OutputRoot 'packages'
    $publishedRoot = Join-Path $OutputRoot 'published'
    foreach ($architecture in @('x64', 'arm64')) {
        & (Join-Path $root 'native-windows/packaging/package-native-windows.ps1') -Architecture $architecture -Version $normalizedVersion -OutputRoot $packagesRoot
    }
    & (Join-Path $root 'native-windows/packaging/publish-native-windows.ps1') -PackagesRoot $packagesRoot -PublishRoot $publishedRoot
    $precedingVersion = [Version]::new(0, 0, 0, 1).ToString()
    if ([Version]$normalizedVersion -le [Version]$precedingVersion) { throw 'Candidate version must exceed the synthetic preceding version.' }
    $precedingRoot = Join-Path $credentialDirectory 'preceding'
    & (Join-Path $root 'native-windows/packaging/package-native-windows.ps1') -Architecture x64 -Version $precedingVersion -OutputRoot $precedingRoot
    # Do not pass signing secrets into installed clients or consumer processes.
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $null) }
    foreach ($name in @('VEX_WINDOWS_SELF_SIGNED_PFX_BASE64', 'VEX_WINDOWS_SELF_SIGNED_PFX_PASSWORD',
        'VEX_WINDOWS_SELF_SIGNED_UPDATE_PRIVATE_KEY_BASE64')) { [Environment]::SetEnvironmentVariable($name, $null) }
    & (Join-Path $PSScriptRoot 'invoke-signed-install-acceptance.ps1') -DisposableRunner -PrecedingIsSynthetic `
        -CandidateBundleDirectory (Join-Path $packagesRoot "stable/x64/$normalizedVersion") `
        -PrecedingBundleDirectory (Join-Path $precedingRoot "stable/x64/$precedingVersion") `
        -ResultPath (Join-Path $OutputRoot 'signed-install-acceptance-x64.json')
    Copy-Item -LiteralPath $publicCertificate, $trustScript -Destination $OutputRoot
    Copy-Item -LiteralPath (Join-Path $root 'native-windows/packaging/self-signed/README.md') -Destination $OutputRoot
    foreach ($directory in @(Get-ChildItem -LiteralPath $publishedRoot -Directory -Recurse | Where-Object Name -EQ 'stable')) {
        Copy-Item -LiteralPath $publicCertificate, $trustScript -Destination $directory.FullName
        Copy-Item -LiteralPath (Join-Path $root 'native-windows/packaging/self-signed/README.md') -Destination $directory.FullName
    }
    $receipt.passed = $true
}
finally {
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $null) }
    if ($trustInstalled) {
        & $trustScript -CertificatePath $publicCertificate -ExpectedCertificateSha256 $certificatePin -Action Remove
        try { & $trustScript -CertificatePath $publicCertificate -ExpectedCertificateSha256 $certificatePin -Action Verify }
        catch { $receipt.trust_removed_after_check = $true }
        if (-not $receipt.trust_removed_after_check) { $receipt.passed = $false; throw 'Candidate certificate trust cleanup failed.' }
    }
    if (Test-Path -LiteralPath $credentialDirectory) { Remove-Item -LiteralPath $credentialDirectory -Recurse -Force }
    [IO.Directory]::CreateDirectory($OutputRoot) | Out-Null
    [IO.File]::WriteAllText((Join-Path $OutputRoot 'self-signed-acceptance.json'),
        ($receipt | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
}
