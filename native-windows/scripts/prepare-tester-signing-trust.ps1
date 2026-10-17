[CmdletBinding()]
param([switch]$DisposableRunner, [ValidateSet('Prepare', 'Cleanup')][string]$Action = 'Prepare')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../packaging/TesterSigning.ps1')
$mode = if ($env:VEX_WINDOWS_SIGNING_MODE) { $env:VEX_WINDOWS_SIGNING_MODE } else { 'public-trusted' }
Assert-WindowsTesterSigningScope -Channel $env:VEX_WINDOWS_RELEASE_CHANNEL -Mode $mode
if ($mode -cne 'tester-ca') { return }
if (-not $DisposableRunner -or $env:OS -cne 'Windows_NT' -or $env:GITHUB_ACTIONS -cne 'true' -or
    $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or
    $env:GITHUB_REF -cne 'refs/heads/main' -or $env:GITHUB_REPOSITORY -cne 'ibotpafos/vex-client') {
    throw 'Tester CI trust requires an explicit disposable Windows release runner on protected main.'
}
$identity = Get-WindowsTesterSigningIdentity -ExpectedRootSha256 $env:VEX_WINDOWS_TEST_ROOT_SHA256 `
    -ExpectedLeafSha256 $env:VEX_WINDOWS_TEST_CERT_SHA256 -Publisher $env:VEX_WINDOWS_PACKAGE_PUBLISHER
$journal = Join-Path $env:RUNNER_TEMP 'vex-tester-signing-trust.json'
$certificatePath = 'Cert:\LocalMachine\Root\' + $identity.RootThumbprint
if ($Action -ceq 'Cleanup') {
    if (-not (Test-Path -LiteralPath $journal)) { return }
    $state = [IO.File]::ReadAllText($journal) | ConvertFrom-Json
    if ($state.root_sha256 -ine $identity.RootSha256 -or $state.root_thumbprint -cne $identity.RootThumbprint -or
        $state.created -isnot [bool]) { throw 'Tester trust cleanup journal does not match the pinned identity.' }
    if ($state.created -and (Test-Path -LiteralPath $certificatePath)) {
        $present = Get-Item -LiteralPath $certificatePath
        if ($present.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256) -ine $identity.RootSha256) {
            throw 'Tester trust cleanup refused a different certificate.'
        }
        Remove-Item -LiteralPath $certificatePath -Force
    }
    Remove-Item -LiteralPath $journal -Force
    Write-Output 'Owned beta code-signing trust cleanup completed.'
    return
}
$created = -not (Test-Path -LiteralPath $certificatePath)
$state = @{ root_sha256 = $identity.RootSha256; root_thumbprint = $identity.RootThumbprint; created = $created }
$stream = [IO.File]::Open($journal, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($state | ConvertTo-Json -Compress))
    $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true)
}
finally { $stream.Dispose() }
if ($created) { $null = Import-Certificate -FilePath $identity.RootPath -CertStoreLocation 'Cert:\LocalMachine\Root' }
$present = Get-Item -LiteralPath $certificatePath
if ($present.HasPrivateKey -or $present.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256) -ine $identity.RootSha256) {
    throw 'The disposable runner did not retain the exact public code-signing authority.'
}
Write-Output 'Pinned beta code-signing authority prepared on the disposable Windows runner.'
