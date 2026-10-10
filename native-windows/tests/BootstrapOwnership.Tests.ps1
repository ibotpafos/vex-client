# Execute the production bootstrap functions with Windows commands mocked.
# No elevated operations or package registration take place on this host.
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    # These functions run with mocked Windows providers in both host versions.
    Add-Type -AssemblyName System.Security
    Add-Type -AssemblyName System.ServiceProcess
    $null = [Security.Cryptography.ProtectedData]
    $null = [ServiceProcess.ServiceControllerStatus]::Running
}
$sourcePath = Join-Path $PSScriptRoot '../scripts/bootstrap-native-windows.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path $sourcePath), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($function in $ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]}, $false)) {
    Invoke-Expression $function.Extent.Text
}
function Assert($condition, $message) { if (!$condition) { throw $message } }
function Assert-Rejected([scriptblock]$body, $message) {
    $rejected = $false
    try { & $body | Out-Null } catch { $rejected = $true }
    Assert $rejected $message
}
$realServicePhase = (Get-Item Function:Invoke-ServicePhase).ScriptBlock
$realInstall = (Get-Item Function:Install-Package).ScriptBlock
$original = 'S-1-5-21-100-200-300-1001'
$administrator = 'S-1-5-21-100-200-300-500'
$script:OwnerSid = $original
$script:Phase = 'User'
$script:Action = 'Install'
$script:CurrentSid = $original
$script:InstallDirectory = '/packages/vex-original'
$script:MetadataPath = '/artifacts/package-metadata.json'
$env:WINDIR = '/trusted-windows'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('vex-bootstrap-ownership-' + [guid]::NewGuid().ToString('N'))
$env:ProgramData = $temporary
$null = New-Item -ItemType Directory -Path $temporary
function Get-CurrentUserSid { $script:CurrentSid }
function Get-SystemPowerShellPath { '/trusted-windows/System32/WindowsPowerShell/v1.0/powershell.exe' }
function Assert-Administrator { }
function Get-VexDataDirectory { Join-Path $temporary 'VEX/VPN' }
function Get-Service { param($Name, $ErrorAction) return $null }
$script:Metadata = [pscustomobject]@{
    package_name = 'VEX.Native'; package_sha256 = 'package-pin'; bootstrap_file = 'bootstrap-native-windows.ps1'
    bootstrap_sha256 = 'bootstrap-pin'; client_certificate_sha256 = 'certificate-pin'
}
function Read-PackageMetadata { param($Path) $script:Metadata }
function Assert-ReleaseArtifacts { param($Path,$MetadataFile,$ScriptsRoot) $script:Metadata }
$script:HashChecks = @()
$script:SignatureChecks = @()
function Assert-Hash { param($Path,$Expected,$Description) $script:HashChecks += [pscustomobject]@{Path=$Path;Expected=$Expected} }
function Assert-ScriptSignature { param($Path,$ExpectedCertificateSha256) $script:SignatureChecks += $ExpectedCertificateSha256 }
$script:AppxCalls = @()
function Get-AppxPackage {
    param($Name,$User,$ErrorAction)
    $script:AppxCalls += [pscustomobject]@{Name=$Name;User=$User}
    if ($script:NoPackage) { return }
    [pscustomobject]@{
        Version = [version]'1.2.3.4'; InstallLocation = $(if($User -eq $original -or $script:CurrentSid -eq $original){'/packages/vex-original'}else{'/packages/admin'})
        PackageFullName = 'original-package'; PackageFamilyName = 'VEX.Native_publisher'
    }
}
$script:NoPackage = $false
$script:Registrations = 0; $script:Removals = 0; $script:Provisioned = 0; $script:Verified = 0
function Add-AppxPackage { param($Path,$ForceApplicationShutdown,$ErrorAction,[switch]$ForceUpdateFromAnyVersion) $script:Registrations++ }
function Remove-AppxPackage { param($Package,$ErrorAction) $script:Removals++ }
function Invoke-ServiceProvisioning { param($Metadata,$InstallDirectory) $script:Provisioned++; Assert ($InstallDirectory -eq '/packages/vex-original') 'Admin package payload selected' }
function Assert-InstalledState { param($Metadata,$InstallDirectory) $script:Verified++ }
function Invoke-ServiceRemoval { param($Metadata,$InstallDirectory) $script:Removals++ }
$script:Stopped = 0
function Stop-ServiceForPackageUpdate { $script:Stopped++ }
try {
    Assert-OriginalUserContext
    $script:CurrentSid = $administrator
    Assert-Rejected { Assert-OriginalUserContext } 'Other-admin token must not register or relaunch the owning user app'
    Assert-Rejected { & $realInstall -Path '/release.msix' -MetadataFile $MetadataPath } 'Elevated other-admin install must be refused before Add-AppxPackage'
    Assert ($script:Registrations -eq 0) 'Cross-user package mutation occurred'

    $script:Phase = 'Service'
    Invoke-ServiceAction -Metadata $script:Metadata
    Assert ($script:AppxCalls[-1].User -eq $original) 'Service phase must query original OwnerSid, not current administrator or AllUsers'
    Assert ($script:Provisioned -eq 1 -and $script:Verified -eq 1 -and $script:Registrations -eq 0) 'Service phase must provision and verify only; no MSIX registration'
    $script:InstallDirectory = '/packages/admin'
    Assert-Rejected { Invoke-ServiceAction -Metadata $script:Metadata } 'Admin-owned payload must not replace original user service'
    $script:InstallDirectory = '/packages/vex-original'
    $script:OwnerSid = ''
    Assert-Rejected { Resolve-OwnerSid } 'Service phase must never default OwnerSid to elevated administrator'
    $script:OwnerSid = $original

    $ownerFile = Join-Path $temporary 'VEX/VPN/owner-sid'
    $null = New-Item -ItemType Directory -Path (Split-Path $ownerFile)
    [IO.File]::WriteAllText($ownerFile, $administrator)
    $script:Action = 'Prepare'
    Assert-Rejected { Invoke-ServiceAction -Metadata $script:Metadata } 'Foreign service ownership must refuse stop and authorization reassignment'
    Assert ($script:Stopped -eq 0) 'Foreign-owned service stopped before ownership validation'
    [IO.File]::WriteAllText($ownerFile, $original)
    Invoke-ServiceAction -Metadata $script:Metadata
    Assert ($script:Stopped -eq 1 -and $script:Registrations -eq 0) 'Prepare must stop only the owning service without MSIX mutation'

    $script:Phase = 'User'; $script:CurrentSid = $original; $script:Action = 'Install'
    $script:Timeout = 0; $script:Disposed = $false; $script:TimedOut = $false; $script:ProcessExitCode = 0
    function Start-Process {
        param($FilePath,$ArgumentList,$Verb,[switch]$PassThru)
        $script:Launch = [pscustomobject]@{File=$FilePath;Arguments=$ArgumentList;Verb=$Verb}
        $process = [pscustomobject]@{ExitCode=$script:ProcessExitCode}
        $process | Add-Member ScriptMethod WaitForExit { param($milliseconds) $script:Timeout=$milliseconds; return !$script:TimedOut }
        $process | Add-Member ScriptMethod Dispose { $script:Disposed=$true }
        return $process
    }
    & $realServicePhase -ServiceAction 'Install' -MetadataFile $MetadataPath -ScriptsRoot '/signed artifacts' -PackageInstallDirectory '/packages/vex-original'
    Assert ($script:Launch.Verb -eq 'RunAs' -and $script:Launch.File.Contains('System32') -and $script:Launch.File.Contains('WindowsPowerShell')) 'Elevation must use trusted system PowerShell'
    Assert ($script:Launch.Arguments.Contains('"-Phase" "Service"') -and $script:Launch.Arguments.Contains('"-OwnerSid" "'+$original+'"')) 'Elevated command must carry original OwnerSid and service-only phase'
    Assert ($script:Timeout -eq 180000 -and $script:Disposed) 'Service elevation wait must be bounded and process handles disposed'
    Assert ($script:HashChecks[-1].Expected -eq 'bootstrap-pin' -and $script:SignatureChecks[-1] -eq 'certificate-pin') 'Service entrypoint release hash and signer pin must be checked before elevation'
    $script:TimedOut = $true
    Assert-Rejected { & $realServicePhase -ServiceAction 'Install' -MetadataFile $MetadataPath -ScriptsRoot '/signed artifacts' } 'Timed-out elevation must not report successful installation'
    $script:TimedOut = $false; $script:ProcessExitCode = 1
    Assert-Rejected { & $realServicePhase -ServiceAction 'Install' -MetadataFile $MetadataPath -ScriptsRoot '/signed artifacts' } 'Failed service phase must not report successful installation'
    Assert-Rejected { Quote-NativeArgument 'unsafe"argument' } 'Native command arguments must reject quote injection'

    $script:Phases = @()
    function Invoke-ServicePhase { param($ServiceAction,$MetadataFile,$ScriptsRoot,$PackageInstallDirectory) $script:Phases += $ServiceAction }
    Assert-Rejected { & $realInstall -Path '/release.msix' -MetadataFile $MetadataPath -ForceUpdate } 'Downgrade bypass must be restricted to explicit Rollback'
    & $realInstall -Path '/release.msix' -MetadataFile $MetadataPath -ScriptsRoot '/signed artifacts'
    Assert ($script:Registrations -eq 1 -and $script:Phases.Count -eq 2 -and $script:Phases[0] -eq 'Prepare' -and $script:Phases[1] -eq 'Install') 'Update must stop existing service before original-user registration and provision afterwards'
    Assert ($script:AppxCalls[-1].User -eq $null) 'User registration must query only the original current-user package'
    Assert (($ast.Extent.Text -notmatch 'Remove-AppxPackage[^\r\n]*-AllUsers') -and ($ast.Extent.Text -notmatch 'Get-AppxPackage[^\r\n]*-AllUsers')) 'Bootstrap must not register or remove all users packages'
    foreach ($helper in @('install-vpn-service.ps1','uninstall-vpn-service.ps1')) {
        $helperText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot ('../scripts/'+$helper)))
        $helperTokens = $null; $helperErrors = $null
        [Management.Automation.Language.Parser]::ParseInput($helperText,[ref]$helperTokens,[ref]$helperErrors) | Out-Null
        Assert ($helperErrors.Count -eq 0) "$helper does not parse"
        Assert ($helperText.Contains('[Environment+SpecialFolder]::System') -and $helperText -notmatch '&\s+sc\.exe') "$helper must use fixed system sc.exe instead of inherited PATH"
    }
    Write-Output 'Bootstrap ownership and bounded service-phase regressions passed'
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
