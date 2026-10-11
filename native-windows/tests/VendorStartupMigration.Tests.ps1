# Real bootstrap qualification and Prepare ordering with harmless SCM providers.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { Add-Type -AssemblyName System.ServiceProcess }
function Assert($condition,$message) { if (-not $condition) { throw $message } }
function Assert-Rejected([scriptblock]$body,$message) {
    $rejected=$false
    try { & $body|Out-Null } catch { $rejected=$true }
    Assert $rejected $message
}
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Resolve-Path (Join-Path $PSScriptRoot '../scripts/bootstrap-native-windows.ps1')),[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'Bootstrap does not parse'
foreach ($definition in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) { Invoke-Expression $definition.Extent.Text }
$temp=Join-Path ([IO.Path]::GetTempPath()) ('vex-vendor-startup-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $temp
try {
    $script:installRoot=Join-Path $temp 'old-package'
    $script:dataRoot=Join-Path $temp 'state'
    $null=New-Item -ItemType Directory -Path $dataRoot
    [IO.File]::WriteAllText((Join-Path $dataRoot 'bootstrap-state.json'),'{"schema":"vex.windows-service-bootstrap.v1","amneziawg_sha256":"old-protected-pin"}')
    $script:OwnerSid='S-1-5-21-100-200-300-1001'; $script:Phase='Service'; $script:Action='Prepare'
    $metadata=[pscustomobject]@{package_name='VEX.Fixture';amneziawg_sha256='replacement-pin'}
    $expectedExecutable=Join-Path $installRoot 'amneziawg.exe'
    $expectedConfig=Join-Path $dataRoot 'Private\vex.conf'
    $nativeParser=(Get-Item Function:Get-VendorCommandLineArguments).ScriptBlock
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $args=@(& $nativeParser ('"'+$expectedExecutable+'" /tunnelservice "'+$expectedConfig+'"'))
        Assert ($args.Count -eq 3 -and $args[0] -eq $expectedExecutable -and $args[2] -eq $expectedConfig) 'Actual Windows command-line parsing rejected equivalent legacy/new quoting'
    }
    $realRemoval=(Get-Item Function:Invoke-OldVendorRemoval).ScriptBlock
    $realControllerStop=(Get-Item Function:Stop-ServiceForPackageUpdate).ScriptBlock
    $script:arguments=@($expectedExecutable,'/tunnelservice',$expectedConfig)
    function Get-VendorCommandLineArguments { param($CommandLine) $script:arguments }
    function Get-VexDataDirectory { $script:dataRoot }
    function Assert-Administrator { }
    function Assert-ServiceOwnership { }
    function Assert-PrivateStateAcl { param($Path) $script:events+='acl' }
    function Assert-NoReparsePath { param($Path) }
    function Get-InstalledPackage { param($Name,[switch]$ServiceScope) Assert $ServiceScope 'Migration must query original user package'; [pscustomobject]@{InstallLocation=$script:installRoot} }
    $script:rejectPins=$false
    function Assert-InstalledState {
        param($Metadata,$InstallDirectory,[switch]$AllowStopped)
        Assert ($Metadata.amneziawg_sha256 -eq 'old-protected-pin' -and $InstallDirectory -eq $script:installRoot -and $AllowStopped) 'Migration used replacement metadata instead of protected old release identity'
        $script:events+='old-payload'
        if ($script:rejectPins) { throw 'Old protected payload mismatch' }
    }
    $script:readFailure=$false; $script:registration=$null
    function Read-VendorServiceRegistration { if ($script:readFailure) { throw 'SCM configuration query failure' }; $script:registration }
    $script:foreignAfterStop=$false; $script:vendorStatus='Stopped'
    function Get-Service {
        param($Name,$ErrorAction)
        Assert ($Name -ceq 'AmneziaWGTunnel$vex') 'Migration queried another vendor service'
        $service=[pscustomobject]@{Status=$script:vendorStatus}
        $service | Add-Member ScriptMethod Dispose { }
        $service
    }
    function Stop-ServiceForPackageUpdate { $script:events+='stop'; if ($script:foreignAfterStop) { $script:arguments[0]='C:\foreign\amneziawg.exe' } }
    function Invoke-OldVendorRemoval { param($Executable) Assert ($Executable -eq $expectedExecutable) 'Wrong retained executable removed'; $script:events+='remove'; $script:registration=$null }
    $script:ignoreMutation=$false
    function Set-Service {
        param($Name,$StartupType,$ErrorAction)
        Assert ($Name -ceq 'AmneziaWGTunnel$vex' -and $StartupType -eq 'Manual') 'Migration changed wrong service or unsupported configuration'
        $script:events+='demand'
        if (-not $script:ignoreMutation) { $script:registration.Start=3 }
    }
    function Reset-Registration {
        $script:events=@(); $script:arguments=@($expectedExecutable,'/tunnelservice',$expectedConfig)
        $script:registration=[pscustomobject]@{ImagePath='fixture command';Type=16;Start=2;ObjectName='LocalSystem';DependOnService=@('Nsi','TcpIp');ServiceSidType=1}
        $script:readFailure=$false; $script:rejectPins=$false; $script:ignoreMutation=$false; $script:foreignAfterStop=$false; $script:vendorStatus='Stopped'
    }
    $script:events=@(); Invoke-ServiceAction -Metadata $metadata
    Assert (($script:events -join ',') -eq 'stop') 'Absent vendor must leave configuration untouched and permit normal Prepare'
    Reset-Registration; Invoke-ServiceAction -Metadata $metadata
    Assert (($script:events -join ',') -eq 'acl,old-payload,demand,stop,acl,old-payload,remove' -and $null -eq $script:registration) 'Automatic vendor must be qualified and switched to demand before controller stop'
    Reset-Registration; $script:registration.Start=3; Invoke-ServiceAction -Metadata $metadata
    Assert (($script:events -join ',') -eq 'acl,old-payload,stop,acl,old-payload,remove') 'Existing demand-start service must remain unchanged'
    foreach ($mutation in @(
        { $script:arguments[0]='C:\foreign\amneziawg.exe' }, { $script:arguments[1]='/other-switch' },
        { $script:arguments[2]='C:\foreign\vex.conf' }, { $script:arguments+= 'extra' },
        { $script:registration.Type=32 }, { $script:registration.Start=4 },
        { $script:registration.ObjectName='LocalService' }, { $script:registration.ServiceSidType=0 },
        { $script:registration.DependOnService=@('Nsi') }, { $script:registration.DependOnService=@('Nsi','Nsi') },
        { $script:readFailure=$true }, { $script:rejectPins=$true }
    )) {
        Reset-Registration; & $mutation
        Assert-Rejected { Invoke-ServiceAction -Metadata $metadata } 'Foreign, malformed or unverifiable vendor registration was accepted'
        Assert ('demand' -notin $script:events -and 'stop' -notin $script:events) 'Rejected vendor registration was changed or prior controller stopped'
    }
    Reset-Registration; $script:ignoreMutation=$true
    Assert-Rejected { Invoke-ServiceAction -Metadata $metadata } 'Unconfirmed demand-start update reported success'
    Assert ('stop' -notin $script:events) 'Failed demand-start update stopped controller'
    Reset-Registration; $script:foreignAfterStop=$true
    Assert-Rejected { Invoke-ServiceAction -Metadata $metadata } 'Vendor identity changed after controller stop was removed'
    Assert ('remove' -notin $script:events) 'Replaced vendor registration was removed'
    Reset-Registration; $script:vendorStatus='Running'
    Assert-Rejected { Invoke-ServiceAction -Metadata $metadata } 'Still-running retained vendor was removed'
    Assert ('remove' -notin $script:events) 'Migration removed a running vendor instead of requiring controller cleanup'
    Reset-Registration
    Assert-Rejected { Wait-OldVendorRemoved -TimeoutSeconds 0 } 'Remaining vendor registration reported removal success'
    $script:registration=$null; Wait-OldVendorRemoved -TimeoutSeconds 0
    $script:processWaits=@(); $script:processDisposals=0; $script:processKills=0; $script:processTimeout=$false; $script:processExit=0
    function Start-Process {
        param($FilePath,$ArgumentList,[switch]$PassThru,$WindowStyle,$ErrorAction)
        Assert ($FilePath -eq $expectedExecutable -and $ArgumentList -ceq '/uninstalltunnelservice vex') 'Migration must call only the protected old vendor for the owned tunnel'
        $process=[pscustomobject]@{ExitCode=$script:processExit}
        $process|Add-Member ScriptMethod WaitForExit { param($milliseconds) $script:processWaits += $milliseconds; return -not $script:processTimeout }
        $process|Add-Member ScriptMethod Dispose { $script:processDisposals++ }
        $process|Add-Member ScriptMethod Kill { $script:processKills++ }
        $process
    }
    & $realRemoval -Executable $expectedExecutable
    Assert ($script:processWaits[0] -eq 30000 -and $script:processDisposals -eq 1) 'Retained vendor removal was not bounded or disposed'
    $script:processTimeout=$true
    Assert-Rejected { & $realRemoval -Executable $expectedExecutable } 'Hung vendor removal reported success'
    Assert ($script:processKills -eq 1 -and $script:processWaits[-1] -eq 5000 -and $script:processDisposals -eq 2) 'Hung retained vendor process was not terminated within a bounded wait'
    $script:processTimeout=$false; $script:processExit=1
    Assert-Rejected { & $realRemoval -Executable $expectedExecutable } 'Failed vendor removal reported success'
    function Get-Service { param($Name,$ErrorAction) throw 'SCM query permission failure' }
    Assert-Rejected { & $realControllerStop } 'Controller query failure was treated as absence before vendor removal'
    Write-Output 'Retained vendor startup migration, old protected pins, foreign preservation and Prepare ordering regressions passed'
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
