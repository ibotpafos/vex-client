# Run the actual C# launcher's literal verifier with a harmless fixture script.
# Only Authenticode is mocked; file hashes and metadata pins are real.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Assert($condition,$message) { if (-not $condition) { throw $message } }
function Assert-Rejected([scriptblock]$body,$message) {
    $rejected=$false
    try { & $body | Out-Null } catch { $rejected=$true }
    Assert $rejected $message
}
$source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../src/Vex.Windows.App/Services/NativeUpdateService.Windows.cs'))
$match=[regex]::Match($source,'private const string VerifiedBootstrapCommand = """\r?\n(?<body>[\s\S]*?)\r?\n        """;')
Assert $match.Success 'Actual launch verifier template was not found'
$template=$match.Groups['body'].Value
$productionTokens=$null; $productionErrors=$null
$productionAst=[Management.Automation.Language.Parser]::ParseFile((Resolve-Path (Join-Path $PSScriptRoot '../scripts/bootstrap-native-windows.ps1')),[ref]$productionTokens,[ref]$productionErrors)
Assert ($productionErrors.Count -eq 0) 'Service bootstrap does not parse'
foreach ($definition in $productionAst.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    if ($definition.Name -eq 'New-VerifiedServiceCommand') { Invoke-Expression $definition.Extent.Text }
}
$tokens=$null; $errors=$null
[Management.Automation.Language.Parser]::ParseInput($template,[ref]$tokens,[ref]$errors) | Out-Null
Assert ($errors.Count -eq 0) 'Launch verifier does not parse in this PowerShell host'
$originalModulePath=$env:PSModulePath
$isNativeWindowsPowerShell=[Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and $PSVersionTable.PSEdition -eq 'Desktop'
function Get-TestVerifier([string]$command) {
    Assert ($command.Contains('$env:PSModulePath = $systemModules') -and
        $command.Contains('Microsoft.PowerShell.Core\Import-Module') -and
        $command.Contains("[IO.Path]::Combine(`$systemModules, `$module, (`$module + '.psd1'))") -and
        $command.Contains('Microsoft.PowerShell.Core\Get-Command') -and $command.Contains('-ListImported') -and
        $command.Contains('Microsoft.PowerShell.Utility\Get-FileHash') -and
        $command.Contains('Microsoft.PowerShell.Security\Get-AuthenticodeSignature')) 'Verifier does not select trusted system modules and qualified cryptographic providers'
    if (-not $isNativeWindowsPowerShell) {
        # Actual launch is fixed WinPS5.1. Core/Linux cannot load its protected
        # .NET Framework modules; inspect exact prefix and test the shared body.
        $command=[regex]::Replace($command,'(?s)# VEX_TRUSTED_POWERSHELL_MODULES_BEGIN.*?# VEX_TRUSTED_POWERSHELL_MODULES_END','')
    }
    return $command.Replace('Microsoft.PowerShell.Security\Get-AuthenticodeSignature','Get-FixtureAuthenticodeSignature')
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('vex-bootstrap-launch-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $temp
try {
    # Quotes, spaces, $ and backticks remain data after Base64 JSON transport.
    $bootstrap=Join-Path $temp "verified ' fixture.ps1"
    $metadataPath=Join-Path $temp 'package-metadata.json'
    $marker=Join-Path $temp 'invoked.json'
    [IO.File]::WriteAllText($bootstrap, @'
param($Phase,$Action,$PackagePath,$MetadataPath,$OwnerSid,$InstallDirectory,[switch]$RelaunchAfterInstall)
$heldAgainstWrite=$true
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    foreach ($held in @($PSCommandPath,$MetadataPath)) {
        try { $writer=[IO.File]::Open($held,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite); $writer.Dispose(); $heldAgainstWrite=$false } catch [IO.IOException] { }
    }
}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'invoked.json'), (@{Phase=$Phase;Action=$Action;PackagePath=$PackagePath;OwnerSid=$OwnerSid;Relaunch=[bool]$RelaunchAfterInstall;InstallDirectory=$InstallDirectory;HeldAgainstWrite=$heldAgainstWrite}|ConvertTo-Json))
'@)
    $certificateBytes=[Text.Encoding]::UTF8.GetBytes('mock trusted certificate')
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $certificatePin=[BitConverter]::ToString($sha.ComputeHash($certificateBytes)).Replace('-','') } finally { $sha.Dispose() }
    [IO.File]::WriteAllText($metadataPath, (@{client_certificate_sha256=$certificatePin}|ConvertTo-Json))
    $script:signatureStatus=[Management.Automation.SignatureStatus]::Valid
    $script:signerBytes=$certificateBytes
    function Get-FixtureAuthenticodeSignature { param($LiteralPath) [pscustomobject]@{Status=$script:signatureStatus;SignerCertificate=[pscustomobject]@{RawData=$script:signerBytes}} }
    $inputData=@{BootstrapPath=$bootstrap;MetadataPath=$metadataPath;PackagePath="C:\fixture\literal `$() `` ' package.msix";BootstrapSha256=(Get-FileHash $bootstrap).Hash;MetadataSha256=(Get-FileHash $metadataPath).Hash;OwnerSid='S-1-5-21-100-200-300-1001'}
    function Invoke-Verifier {
        $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($inputData|ConvertTo-Json)))
        if ($script:mode -eq 'Service') {
            $serviceInput=@{BootstrapPath=$inputData.BootstrapPath;MetadataPath=$inputData.MetadataPath;BootstrapSha256=$inputData.BootstrapSha256;MetadataSha256=$inputData.MetadataSha256;CertificateSha256=$certificatePin;ServiceAction='Install';OwnerSid=$inputData.OwnerSid;InstallDirectory="C:\fixture\old package"}
            $serviceCommand=New-VerifiedServiceCommand -InputData $serviceInput
            & ([scriptblock]::Create((Get-TestVerifier ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($serviceCommand))))))
        } else {
            & ([scriptblock]::Create((Get-TestVerifier ($template.Replace('__VEX_BOOTSTRAP_INPUT__',$encoded)))))
        }
    }
    $hostileModuleRoot=Join-Path $temp 'hostile-modules'
    $utilityDirectory=Join-Path $hostileModuleRoot 'Microsoft.PowerShell.Utility'
    $null=New-Item -ItemType Directory -Path $utilityDirectory -Force
    $hostileMarker=Join-Path $temp 'hostile-module-loaded'
    [IO.File]::WriteAllText((Join-Path $utilityDirectory 'Microsoft.PowerShell.Utility.psm1'), "[IO.File]::WriteAllText('$($hostileMarker.Replace("'","''"))','hijacked')")
    foreach ($script:mode in @('User','Service')) {
    $env:PSModulePath=$hostileModuleRoot
    $script:signatureStatus=[Management.Automation.SignatureStatus]::Valid; $script:signerBytes=$certificateBytes
    Invoke-Verifier
    $result=Get-Content -LiteralPath $marker -Raw|ConvertFrom-Json
    Assert ($result.Phase -eq $script:mode -and $result.Action -eq 'Install' -and ($script:mode -eq 'Service' -or ($result.Relaunch -and $result.PackagePath -ceq $inputData.PackagePath)) -and $result.HeldAgainstWrite -and $result.OwnerSid -eq $inputData.OwnerSid) 'Verified launcher did not preserve original-user arguments'
    Assert (-not (Test-Path -LiteralPath $hostileMarker)) 'Verifier loaded an untrusted user module'
    if ($isNativeWindowsPowerShell) {
        $trustedModules=[IO.Path]::Combine([Environment]::GetFolderPath([Environment+SpecialFolder]::System),'WindowsPowerShell','v1.0','Modules')
        Assert ($env:PSModulePath -eq $trustedModules) 'Actual WinPS verifier retained hostile module autoload paths'
    }
    Remove-Item -LiteralPath $marker
    foreach ($field in @('BootstrapSha256','MetadataSha256')) {
        $old=$inputData[$field]; $inputData[$field]='0'*64
        Assert-Rejected { Invoke-Verifier } 'Tampered signed-release file hash was executed'
        Assert (-not (Test-Path -LiteralPath $marker)) 'Unverified script was executed'
        $inputData[$field]=$old
    }
    $script:signatureStatus=[Management.Automation.SignatureStatus]::NotTrusted
    Assert-Rejected { Invoke-Verifier } 'Untrusted Authenticode signer was executed'
    Assert (-not (Test-Path -LiteralPath $marker)) 'Untrusted script was invoked'
    $script:signatureStatus=[Management.Automation.SignatureStatus]::Valid
    $script:signerBytes=[Text.Encoding]::UTF8.GetBytes('another trusted certificate')
    Assert-Rejected { Invoke-Verifier } 'Valid but unpinned signer was executed'
    Assert (-not (Test-Path -LiteralPath $marker)) 'Unpinned script was invoked'
    }
    Write-Output 'Actual unattended bootstrap verifier hash, signer and argument transport regressions passed'
} finally { $env:PSModulePath=$originalModulePath; Remove-Item -LiteralPath $temp -Recurse -Force }
