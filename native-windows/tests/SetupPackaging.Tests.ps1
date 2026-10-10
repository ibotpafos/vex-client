# Exercise the actual release packager's Setup pipeline with isolated providers.
# No .NET build, certificate signing, package installation or network occurs.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../packaging/ReleaseValidation.ps1')
function Assert($condition,$message) { if (-not $condition) { throw $message } }
function Assert-Rejected([scriptblock]$body,$message) {
    $rejected=$false
    try { & $body | Out-Null } catch { $rejected=$true }
    Assert $rejected $message
}
$sourcePath=(Resolve-Path (Join-Path $PSScriptRoot '../packaging/package-native-windows.ps1')).Path
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'Packager does not parse'
foreach ($definition in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    if ($definition.Name -in @('Publish-SignedSetup','Invoke-SignTool')) { Invoke-Expression $definition.Extent.Text }
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('vex-setup-packaging-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $temp
$global:VexSetupPackagingFixture=@{Mode='valid';Arch='x64';Calls=@();SignCalls=@();Certificate=('A'*64)}
function dotnet {
    $Arguments=@($args)
    $global:VexSetupPackagingFixture.Calls += ,@($Arguments)
    $global:LASTEXITCODE=0
    if ($global:VexSetupPackagingFixture.Mode -eq 'publish-fail') { $global:LASTEXITCODE=9; return }
    if ($global:VexSetupPackagingFixture.Mode -eq 'missing-output') { return }
    $outputIndex=[Array]::IndexOf([object[]]$Arguments,'-o')
    $output=[string]$Arguments[$outputIndex+1]
    $null=New-Item -ItemType Directory -Path $output -Force
    $machine=if ($global:VexSetupPackagingFixture.Arch -eq 'arm64') { 0xAA64 } else { 0x8664 }
    if ($global:VexSetupPackagingFixture.Mode -eq 'wrong-arch') { $machine=if ($machine -eq 0x8664) { 0xAA64 } else { 0x8664 } }
    $bytes=[byte[]]::new(128)
    [BitConverter]::GetBytes([uint16]0x5A4D).CopyTo($bytes,0)
    [BitConverter]::GetBytes([uint32]64).CopyTo($bytes,0x3C)
    [BitConverter]::GetBytes([uint32]0x00004550).CopyTo($bytes,64)
    [BitConverter]::GetBytes([uint16]$machine).CopyTo($bytes,68)
    [IO.File]::WriteAllBytes((Join-Path $output 'Vex.Windows.Setup.exe'),$bytes)
}
function Import-PfxFromBase64 { param($Base64,$DestinationPath) [IO.File]::WriteAllText($DestinationPath,'isolated fixture key, not a private certificate') }
function Get-PfxCertificateSha256 { param($Path,$Password) $global:VexSetupPackagingFixture.Certificate }
function Invoke-FixtureSignTool {
    param([Parameter(ValueFromRemainingArguments=$true)][object[]]$Arguments)
    $global:VexSetupPackagingFixture.SignCalls += ,@($Arguments)
    $global:LASTEXITCODE=0
    if (($Arguments[0] -eq 'sign' -and $global:VexSetupPackagingFixture.Mode -eq 'sign-fail') -or
        ($Arguments[0] -eq 'verify' -and $global:VexSetupPackagingFixture.Mode -eq 'verify-fail')) { $global:LASTEXITCODE=5 }
}
$timestampUri='https://timestamp.example.test/'
try {
    foreach ($architecture in @('x64','arm64')) {
        $release=Join-Path $temp "release $architecture"
        $null=New-Item -ItemType Directory -Path $release
        $metadataPath=Join-Path $release 'package-metadata.json'
        [IO.File]::WriteAllText($metadataPath,'{"schema":"vex.windows-package-output.v2","version":"2.3.4.5"}')
        $metadataHash=(Get-FileHash -LiteralPath $metadataPath).Hash
        $setupPath=Join-Path $release "VEX.Setup.$architecture.exe"
        $pfxPath=Join-Path $release 'temporary-codesign.pfx'
        $arguments=@{ProjectPath=(Join-Path $temp 'Vex.Windows.Setup.csproj'); MetadataPath=$metadataPath; Architecture=$architecture; Version='2.3.4.5'; Configuration='Release'; PublishDirectory=(Join-Path $release 'setup-publish'); SetupPath=$setupPath; SignTool='Invoke-FixtureSignTool'; PfxBase64='fixture'; PfxPassword='fixture'; TemporaryPfxPath=$pfxPath; ExpectedCertificateSha256=('A'*64)}
        $global:VexSetupPackagingFixture.Arch=$architecture
        $global:VexSetupPackagingFixture.Mode='valid'; $global:VexSetupPackagingFixture.SignCalls=@()
        Publish-SignedSetup @arguments
        $call=$global:VexSetupPackagingFixture.Calls[-1]
        Assert ((Test-Path -LiteralPath $setupPath) -and -not (Test-Path -LiteralPath $pfxPath)) 'Signed Setup output missing or private PFX retained'
        Assert ($call[0] -eq 'publish' -and $call[1] -eq $arguments.ProjectPath -and
            "win-$architecture" -in $call -and '--self-contained' -in $call -and 'true' -in $call -and
            '-p:PublishSingleFile=true' -in $call -and '-p:IncludeNativeLibrariesForSelfExtract=true' -in $call -and
            "-p:ReleaseMetadataPath=$((Get-Item -LiteralPath $metadataPath).FullName)" -in $call -and
            '-p:AssemblyVersion=2.3.4.5' -in $call -and '-p:FileVersion=2.3.4.5' -in $call) ('Actual Setup publish arguments lost architecture, completed metadata, native runtime or exact version: ' + ($call -join ' | '))
        Assert ($global:VexSetupPackagingFixture.SignCalls.Count -eq 2 -and
            $global:VexSetupPackagingFixture.SignCalls[0][0] -eq 'sign' -and
            '/tr' -in $global:VexSetupPackagingFixture.SignCalls[0] -and $timestampUri -in $global:VexSetupPackagingFixture.SignCalls[0] -and
            $global:VexSetupPackagingFixture.SignCalls[0][-1] -eq $setupPath -and
            $global:VexSetupPackagingFixture.SignCalls[1][0] -eq 'verify' -and
            '/pa' -in $global:VexSetupPackagingFixture.SignCalls[1] -and '/all' -in $global:VexSetupPackagingFixture.SignCalls[1]) 'Final release Setup did not use real packager sign/timestamp/trust-verification sequence'
        Assert ((Get-FileHash -LiteralPath $metadataPath).Hash -eq $metadataHash) 'Setup publish rewrote completed metadata and created a circular hash'
        foreach ($mode in @('publish-fail','missing-output','wrong-arch','sign-fail','verify-fail')) {
            # A previous successful candidate must be cleared before each attempt.
            [IO.File]::WriteAllText($setupPath,'stale previous release setup')
            $global:VexSetupPackagingFixture.Mode=$mode
            Assert-Rejected { Publish-SignedSetup @arguments } ('Broken Setup candidate admitted: '+$mode)
            Assert (-not (Test-Path -LiteralPath $setupPath) -and -not (Test-Path -LiteralPath $pfxPath)) 'Failed Setup publish left a stale/unsigned final launcher or private PFX eligible for release'
        }
        $global:VexSetupPackagingFixture.Mode='valid'; $global:VexSetupPackagingFixture.Certificate=('B'*64)
        Assert-Rejected { Publish-SignedSetup @arguments } 'Another signing certificate was accepted for release Setup'
        Assert (-not (Test-Path -LiteralPath $setupPath) -and -not (Test-Path -LiteralPath $pfxPath)) 'Wrong signer left final Setup output or PFX behind'
        $global:VexSetupPackagingFixture.Certificate=('A'*64)
        $saved=$arguments.MetadataPath; $arguments.MetadataPath=Join-Path $release 'missing-metadata.json'
        [IO.File]::WriteAllText($setupPath,'stale Setup despite missing metadata')
        $before=$global:VexSetupPackagingFixture.Calls.Count
        Assert-Rejected { Publish-SignedSetup @arguments } 'Missing final metadata reached Setup compilation'
        Assert ($global:VexSetupPackagingFixture.Calls.Count -eq $before -and -not (Test-Path -LiteralPath $setupPath)) 'Missing final metadata compiled or retained an unverified stale Setup'
        $arguments.MetadataPath=$saved
    }
    # Confirm the release script actually calls the tested pipeline only after
    # writing the final package metadata, and does not add launcher hash fields.
    $topCommands=$ast.EndBlock.Statements | ForEach-Object {
        $_.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$false)
    }
    $metadataWrite=$topCommands | Where-Object { $_.GetCommandName() -eq 'Write-Utf8NoBom' -and $_.Extent.Text -match '-Path \$metadataPath' } | Select-Object -Last 1
    $setupPublish=$topCommands | Where-Object { $_.GetCommandName() -eq 'Publish-SignedSetup' } | Select-Object -Last 1
    Assert ($null -ne $metadataWrite -and $null -ne $setupPublish -and $setupPublish.Extent.StartOffset -gt $metadataWrite.Extent.EndOffset) 'Setup embeds metadata before its final release write'
    Assert ($ast.Extent.Text -notmatch '^\s*setup_sha256\s*=' ) 'Setup digest must be in signed bootstrap entry instead of circular embedded metadata'
    Write-Output 'Actual Setup release pipeline passed: x64/ARM64, final metadata embedding, sign/timestamp/trust checks, stale failure rejection and PFX cleanup'
} finally {
    Remove-Variable -Name VexSetupPackagingFixture -Scope Global
    Remove-Item -LiteralPath $temp -Recurse -Force
}
