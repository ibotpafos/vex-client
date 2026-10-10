# Exercise the native Setup's actual literal PS5.1 guards in harmless child
# processes. Authenticode alone is mocked; hashes, locks, SID transport and the
# pre-job-assignment stdin barrier are real. No VEX service/package is touched.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../src/Vex.Windows.Setup/WindowsBootstrapLauncher.cs'))
$templates = @{}
foreach ($name in @('SignatureCommand', 'BootstrapCommand')) {
    $match = [regex]::Match($source, ('private const string ' + $name + ' = """\r?\n(?<body>[\s\S]*?)\r?\n        """;'))
    Assert $match.Success ('Actual Setup guard is missing: ' + $name)
    $templates[$name] = $match.Groups['body'].Value
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseInput($templates[$name], [ref]$tokens, [ref]$errors) | Out-Null
    Assert ($errors.Count -eq 0) ('Actual Setup guard does not parse: ' + $name)
    Assert ($templates[$name].TrimStart().StartsWith("if ([Console]::In.ReadLine() -cne 'vex-setup-job-ready-v1')")) 'Child executes commands before the job readiness barrier'
}
Assert ($source.IndexOf('childJob.Attach(process)') -lt $source.IndexOf('StandardInput.WriteLineAsync')) 'Parent releases a child before assigning its job'
$nativeWinPS = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and $PSVersionTable.PSEdition -eq 'Desktop'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('vex-setup-guard-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null
$hostExecutable = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
try {
    $bootstrap = Join-Path $temp "literal ' bootstrap.ps1"
    $metadata = Join-Path $temp 'package-metadata.json'
    $setup = Join-Path $temp 'VEX.Setup.x64.exe'
    $marker = Join-Path $temp 'invoked.json'
    $signatureMarker = Join-Path $temp 'signature-checked'
    $moduleMarker = Join-Path $temp 'hostile-module-loaded'
    [IO.File]::WriteAllText($metadata, '{"fixture":"harmless metadata"}')
    [IO.File]::WriteAllText($setup, 'harmless unsigned fixture; Authenticode mocked')
    [IO.File]::WriteAllText($bootstrap, @'
param($Phase,$Action,$PackagePath,$MetadataPath,$OwnerSid,[switch]$RelaunchAfterInstall)
$heldAgainstWrite=$true
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    foreach ($held in @($PSCommandPath,$MetadataPath)) {
        try { $writer=[IO.File]::Open($held,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite); $writer.Dispose(); $heldAgainstWrite=$false } catch [IO.IOException] { }
    }
}
[IO.File]::WriteAllText($PackagePath, (@{Phase=$Phase;Action=$Action;OwnerSid=$OwnerSid;Relaunch=[bool]$RelaunchAfterInstall;HeldAgainstWrite=$heldAgainstWrite}|Microsoft.PowerShell.Utility\ConvertTo-Json))
'@)
    $certificate = [Text.Encoding]::UTF8.GetBytes('isolated mock trusted release certificate')
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $pin = [BitConverter]::ToString($sha.ComputeHash($certificate)).Replace('-', '') } finally { $sha.Dispose() }
    $inputData = @{
        BootstrapPath=$bootstrap;MetadataPath=$metadata;SetupPath=$setup;PackagePath=$marker
        BootstrapSha256=(Get-FileHash -LiteralPath $bootstrap).Hash;MetadataSha256=(Get-FileHash -LiteralPath $metadata).Hash
        CertificateSha256=$pin;OwnerSid='S-1-5-21-100-200-300-1001';Action='Install';HeldPaths=@($bootstrap,$metadata,$setup);Path=$setup
    }
    $hostileRoot = Join-Path $temp 'hostile-modules'
    $utility = Join-Path $hostileRoot 'Microsoft.PowerShell.Utility'
    [IO.Directory]::CreateDirectory($utility) | Out-Null
    [IO.File]::WriteAllText((Join-Path $utility 'Microsoft.PowerShell.Utility.psm1'), "[IO.File]::WriteAllText('$($moduleMarker.Replace("'","''"))','untrusted')")
    $fixtureSignature = @'
$script:fixtureCertificate=[Convert]::FromBase64String('__CERTIFICATE__')
function Get-FixtureAuthenticodeSignature {
    param($LiteralPath)
    [IO.File]::WriteAllText('__SIGNATURE_MARKER__','checked')
    return [pscustomobject]@{Status=[Management.Automation.SignatureStatus]::Valid;SignerCertificate=[pscustomobject]@{RawData=$script:fixtureCertificate}}
}
'@
    $fixtureSignature = $fixtureSignature.Replace('__CERTIFICATE__', [Convert]::ToBase64String($certificate)).Replace('__SIGNATURE_MARKER__', $signatureMarker.Replace("'", "''"))
    function Invoke-GuardChild([string]$TemplateName, [string]$Readiness, [switch]$ProveBlocked) {
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($inputData | ConvertTo-Json -Compress)))
        $command = $templates[$TemplateName].Replace('__INPUT__', $payload)
        Assert ($command.Contains('Microsoft.PowerShell.Core\Get-Command') -and $command.Contains('-ListImported') -and
            $command.Contains('Microsoft.PowerShell.Core\Import-Module') -and $command.Contains('Microsoft.PowerShell.Security\Get-AuthenticodeSignature')) 'Setup guard allows untrusted cryptographic providers'
        if (-not $nativeWinPS) {
            $command = [regex]::Replace($command, '(?s)# VEX_TRUSTED_POWERSHELL_MODULES_BEGIN.*?# VEX_TRUSTED_POWERSHELL_MODULES_END', '')
        }
        $command = $fixtureSignature + "`n" + $command.Replace('Microsoft.PowerShell.Security\Get-AuthenticodeSignature', 'Get-FixtureAuthenticodeSignature')
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $hostExecutable
        $start.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
        $start.UseShellExecute = $false
        $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
        $start.EnvironmentVariables['PSModulePath'] = $hostileRoot
        $process = [Diagnostics.Process]::Start($start)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
            if ($ProveBlocked) {
                Start-Sleep -Milliseconds 400
                Assert (-not $process.HasExited -and -not [IO.File]::Exists($signatureMarker) -and -not [IO.File]::Exists($marker)) 'Child verified or invoked before its parent released the barrier'
            }
            if ($null -ne $Readiness -and $Readiness.Length -gt 0) { $process.StandardInput.WriteLine($Readiness) }
            $process.StandardInput.Close()
            Assert ($process.WaitForExit(15000)) 'Harmless Setup guard child exceeded its deadline'
            Assert ([Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout,$stderr),5000)) 'Setup guard child output remained open'
            return [pscustomobject]@{ExitCode=$process.ExitCode;Output=$stdout.Result}
        }
        finally {
            if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) }
            $process.Dispose()
        }
    }
    foreach ($name in @('SignatureCommand','BootstrapCommand')) {
        foreach ($readiness in @('', 'incorrect-token')) {
            $result = Invoke-GuardChild $name $readiness -ProveBlocked:($readiness -eq '')
            Assert ($result.ExitCode -ne 0 -and -not [IO.File]::Exists($signatureMarker) -and -not [IO.File]::Exists($marker)) 'EOF/wrong readiness token reached verification or installation'
        }
    }
    $result = Invoke-GuardChild SignatureCommand 'vex-setup-job-ready-v1'
    Assert ($result.ExitCode -eq 0 -and ($result.Output | ConvertFrom-Json).passed -and
        [IO.File]::Exists($signatureMarker) -and -not [IO.File]::Exists($marker)) 'Read-only signature guard failed or executed bootstrap'
    Remove-Item -LiteralPath $signatureMarker
    foreach ($sid in @('S-1-5-21-100-200-300-1001', 'S-1-12-1-100-200-300-400')) {
        foreach ($action in @('Install','Repair','Uninstall')) {
            $inputData.OwnerSid=$sid; $inputData.Action=$action
            $result = Invoke-GuardChild BootstrapCommand 'vex-setup-job-ready-v1'
            Assert ($result.ExitCode -eq 0) 'Valid local/AzureAD owner was rejected by actual Setup guard'
            $record = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
            Assert ($record.OwnerSid -ceq $sid -and $record.Phase -ceq 'User' -and $record.Action -ceq $action -and
                $record.Relaunch -eq ($action -ne 'Uninstall') -and $record.HeldAgainstWrite) 'Setup guard changed owner/action or released verified input locks'
            Assert (-not [IO.File]::Exists($moduleMarker)) 'Actual Setup guard loaded a hostile user module'
            Remove-Item -LiteralPath $marker,$signatureMarker
        }
    }
    foreach ($sid in @('S-1-5-18','S-1-12-1-100','S-1-5-21-100-200-300-1001;Write-Output injected')) {
        $inputData.OwnerSid=$sid
        $result = Invoke-GuardChild BootstrapCommand 'vex-setup-job-ready-v1'
        Assert ($result.ExitCode -ne 0 -and -not [IO.File]::Exists($marker)) 'Invalid owner reached the bootstrap'
        if ([IO.File]::Exists($signatureMarker)) { Remove-Item -LiteralPath $signatureMarker }
    }
    $inputData.OwnerSid='S-1-5-21-100-200-300-1001'; $inputData.Action='Install'
    foreach ($field in @('BootstrapSha256','MetadataSha256','CertificateSha256')) {
        $saved=$inputData[$field]; $inputData[$field]='0'*64
        $result=Invoke-GuardChild BootstrapCommand 'vex-setup-job-ready-v1'
        Assert ($result.ExitCode -ne 0 -and -not [IO.File]::Exists($marker)) 'Changed bytes or unpinned trusted signer reached installation'
        $inputData[$field]=$saved
        if ([IO.File]::Exists($signatureMarker)) { Remove-Item -LiteralPath $signatureMarker }
    }
    Write-Output 'Actual native Setup guards passed: readiness/EOF barrier, local and AzureAD owners, User-phase actions, retained locks and trusted modules'
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force }
