# Portable policy regression tests. Real firewall/route acceptance still requires
# an elevated Windows host; these mocks exercise the exact production scripts.
$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path $PSScriptRoot '../src/Vex.Windows.Service/Runtime/NetworkSafetyController.cs'
$source = [System.IO.File]::ReadAllText((Resolve-Path $sourcePath))
$matches = [regex]::Matches($source, 'const string \w+ = """\r?\n(.*?)\r?\n\s*""";', 'Singleline')
$scripts = @($matches | ForEach-Object {$_.Groups[1].Value})
if ($scripts.Count -lt 8) { throw 'Production PowerShell scripts missing' }
foreach ($script in $scripts) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -ne 0) { throw ($errors | Out-String) }
}
function Script-With($marker) {
    $script = @($scripts | Where-Object {$_.Contains($marker)})
    if ($script.Count -ne 1) { throw "Ambiguous script: $marker" }
    [scriptblock]::Create($script[0])
}
function Assert($condition, $message) { if (!$condition) { throw $message } }
function Assert-Rejected([scriptblock]$action, $message) {
    $rejected = $false
    try { & $action | Out-Null } catch { $rejected = $true }
    Assert $rejected $message
}
$findRoute = Script-With '# Never use Find-NetRoute'
$verify = Script-With 'firewall_external_allow_active'
$capture = Script-With 'Version=2;Profiles='
$arm = Script-With 'New-NetFirewallRule -Name $names[0]'
$restore = Script-With '# Migration of the old profile-only journal'
$install = Script-With "if(`$null -ne `$existing){'existing';return}"

$script:physical = @([pscustomobject]@{Status='Up';InterfaceIndex=10},[pscustomobject]@{Status='Up';InterfaceIndex=20})
$script:defaults4 = @(
    [pscustomobject]@{InterfaceIndex=99;NextHop='0.0.0.0';RouteMetric=0},
    [pscustomobject]@{InterfaceIndex=20;NextHop='192.168.1.1';RouteMetric=1},
    [pscustomobject]@{InterfaceIndex=10;NextHop='192.168.2.1';RouteMetric=30})
$script:defaults6 = @([pscustomobject]@{InterfaceIndex=99;NextHop='::';RouteMetric=0})
$script:hostRoutes = @([pscustomobject]@{DestinationPrefix='203.0.113.1/32';InterfaceIndex=20;NextHop='192.168.1.1'})
function Get-NetAdapter { param([switch]$Physical) $script:physical }
function Get-NetIPInterface { param($AddressFamily,$InterfaceIndex) [pscustomobject]@{InterfaceMetric=$(if($InterfaceIndex -eq 10){5}else{40})} }
function Get-NetRoute {
    [CmdletBinding()]param($AddressFamily,$DestinationPrefix,[int]$InterfaceIndex,$PolicyStore)
    if ($DestinationPrefix -eq '0.0.0.0/0') { return $script:defaults4 }
    if ($DestinationPrefix -eq '::/0') { return $script:defaults6 }
    $script:hostRoutes | Where-Object {$_.DestinationPrefix -eq $DestinationPrefix -and (!$InterfaceIndex -or $_.InterfaceIndex -eq $InterfaceIndex)}
}
function New-NetRoute {
    param($DestinationPrefix,$InterfaceIndex,$NextHop,$RouteMetric,$PolicyStore)
    $script:hostRoutes += [pscustomobject]@{DestinationPrefix=$DestinationPrefix;InterfaceIndex=$InterfaceIndex;NextHop=$NextHop}
}
$route = (& $findRoute '203.0.113.1' 'IPv4' '32' 'False') | ConvertFrom-Json
Assert ($route.InterfaceIndex -eq 10 -and $route.NextHop -eq '192.168.2.1' -and $route.Created) 'Stale host route or tunnel selected instead of physical gateway'
$result = & $install '203.0.113.1' '10' '192.168.2.1' '32'
Assert ($result -eq 'created') 'New physical bypass not created'
$result = & $install '203.0.113.1' '10' '192.168.2.1' '32'
Assert ($result -eq 'existing') 'Existing foreign route must not be claimed as newly created'
$route = (& $findRoute '2001:db8::1' 'IPv6' '128' 'True') | ConvertFrom-Json
Assert $route.Skipped 'Optional AAAA should be skipped without a physical IPv6 uplink'
Assert-Rejected {& $findRoute '2001:db8::1' 'IPv6' '128' 'False'} 'Literal IPv6 endpoint must fail closed without an uplink'
$script:defaults6 += [pscustomobject]@{InterfaceIndex=10;NextHop='fe80::1';RouteMetric=20}
$route = (& $findRoute '2001:db8::1' 'IPv6' '128' 'False') | ConvertFrom-Json
Assert ($route.InterfaceIndex -eq 10 -and $route.NextHop -eq 'fe80::1') 'IPv6 bypass gateway incorrect'

$env:SystemRoot = 'C:\Windows'
$script:profiles = @('Domain','Private','Public' | ForEach-Object {[pscustomobject]@{Name=$_;Enabled='True';DefaultOutboundAction='Allow'}})
$script:rules = @(
    [pscustomobject]@{Name='ExistingAllow';Direction='Outbound';Action='Allow';Enabled='True';Group='Other';DisplayName='Original'},
    [pscustomobject]@{Name='SurvivingAllow';Direction='Outbound';Action='Allow';Enabled='True';Group='Other';DisplayName='Surviving'},
    [pscustomobject]@{Name='ExistingDisabled';Direction='Outbound';Action='Allow';Enabled='False';Group='Other';DisplayName='Disabled'},
    [pscustomobject]@{Name='UnrelatedVexGroup';Direction='Inbound';Action='Allow';Enabled='True';Group='VEX VPN AntiLeak';DisplayName='Customer rule'})
$script:filters = @{}
function Get-Service { param($Name) [pscustomobject]@{Status='Running'} }
function Get-NetFirewallProfile { param($PolicyStore) $script:profiles }
function Get-NetFirewallRule { [CmdletBinding()]param($PolicyStore) $script:rules }
function Disable-NetFirewallRule { param([Parameter(ValueFromPipeline)]$InputObject) process {$InputObject.Enabled='False'} }
function Enable-NetFirewallRule { param([Parameter(ValueFromPipeline)]$InputObject) process {$InputObject.Enabled='True'} }
function Remove-NetFirewallRule { param([Parameter(ValueFromPipeline)]$InputObject) process {$script:rules=@($script:rules | Where-Object {$_.Name -cne $InputObject.Name})} }
function Set-NetFirewallProfile {
    param($Profile,$PolicyStore,$DefaultOutboundAction,$Enabled)
    foreach ($item in $script:profiles | Where-Object {$_.Name -in @($Profile)}) {
        if ($DefaultOutboundAction) {$item.DefaultOutboundAction=$DefaultOutboundAction}
        if ($Enabled) {$item.Enabled=$Enabled}
    }
}
function New-NetFirewallRule {
    param($Name,$DisplayName,$Group,$PolicyStore,$Direction,$Action,$InterfaceAlias,$Profile,$RemoteAddress,$InterfaceType,$Protocol,$LocalPort,$RemotePort,$Program,$Service,$IcmpType)
    $script:rules += [pscustomobject]@{Name=$Name;Direction=$Direction;Action=$Action;Enabled='True';Group=$Group;DisplayName=$DisplayName}
    $script:filters[$Name]=@{
        Interface=[pscustomobject]@{InterfaceAlias=@($InterfaceAlias)}
        Type=[pscustomobject]@{InterfaceType=@($InterfaceType)}
        Address=[pscustomobject]@{RemoteAddress=@($RemoteAddress)}
        Port=[pscustomobject]@{Protocol=$Protocol;LocalPort=@($LocalPort);RemotePort=@($RemotePort);IcmpType=@($IcmpType)}
        Application=[pscustomobject]@{Program=$Program};Service=[pscustomobject]@{Service=$Service}
    }
}
function Get-NetFirewallInterfaceFilter { param([Parameter(ValueFromPipeline)]$InputObject) process {$script:filters[$InputObject.Name].Interface} }
function Get-NetFirewallInterfaceTypeFilter { param([Parameter(ValueFromPipeline)]$InputObject) process {$script:filters[$InputObject.Name].Type} }
function Get-NetFirewallAddressFilter { param([Parameter(ValueFromPipeline)]$InputObject) process {$script:filters[$InputObject.Name].Address} }
function Get-NetFirewallPortFilter { param([Parameter(ValueFromPipeline)]$InputObject) process {$script:filters[$InputObject.Name].Port} }
function Get-NetFirewallApplicationFilter { param([Parameter(ValueFromPipeline)]$InputObject) process {$script:filters[$InputObject.Name].Application} }
function Get-NetFirewallServiceFilter { param([Parameter(ValueFromPipeline)]$InputObject) process {$script:filters[$InputObject.Name].Service} }
$names = @('Tunnel','Protected','Dhcp4','Dhcp6','Neighbor' | ForEach-Object {"VEX.AntiLeak.test.$_"})
$ips = @('203.0.113.1','2001:db8::1')
$namesJson = ConvertTo-Json -InputObject $names -Compress
$ipsJson = ConvertTo-Json -InputObject $ips -Compress
$stateJson = & $capture $namesJson 'VEX VPN' $ipsJson
$state = $stateJson | ConvertFrom-Json
Assert (@($state.DisabledOutboundAllowRuleNames).Count -eq 2 -and 'ExistingAllow' -in $state.DisabledOutboundAllowRuleNames -and 'SurvivingAllow' -in $state.DisabledOutboundAllowRuleNames) 'Snapshot must contain only previously enabled local outbound allows'
& $arm $stateJson $ipsJson | Out-Null
Assert (($script:rules | Where-Object Name -eq 'ExistingAllow').Enabled -eq 'False') 'Default outbound block alone must not leave old allow rules enabled'
Assert ((& $verify $stateJson) -eq 'ok') 'Expected bounded firewall policy should verify'
$script:rules += [pscustomobject]@{Name='GpoAllow';Direction='Outbound';Action='Allow';Enabled='True';Group='GPO';DisplayName='GPO'}
Assert-Rejected {& $verify $stateJson} 'An effective GPO allow must prevent a false protected state'
$script:rules = @($script:rules | Where-Object Name -ne 'GpoAllow')
$script:filters[$names[1]].Address.RemoteAddress=@('Any')
Assert-Rejected {& $verify $stateJson} 'A broadened protected-endpoint rule must be rejected'
$script:filters[$names[1]].Address.RemoteAddress=$ips
$script:filters[$names[0]].Interface.InterfaceAlias=@('Any')
Assert-Rejected {& $verify $stateJson} 'A broadened tunnel-interface rule must be rejected'
$script:filters[$names[0]].Interface.InterfaceAlias=@('VEX VPN')
$script:filters[$names[2]].Port.LocalPort=@('Any')
Assert-Rejected {& $verify $stateJson} 'A broadened DHCP exception must be rejected'
$script:filters[$names[2]].Port.LocalPort=@('68')
$script:filters[$names[4]].Port.IcmpType=@('Any')
Assert-Rejected {& $verify $stateJson} 'A broadened IPv6 neighbor exception must be rejected'
$script:filters[$names[4]].Port.IcmpType=@('133','135','136')
Assert ((& $verify $stateJson) -eq 'ok') 'Restored bounded filters should verify'
# A third party deleted its old rule while VEX was active: do not recreate it
# and still restore the profiles so disconnect cannot trap the user offline.
$script:rules = @($script:rules | Where-Object Name -ne 'ExistingAllow')
Assert ((& $restore $stateJson) -eq 'ok') 'External rule deletion must not prevent restoring original profiles'
Assert (@($script:profiles | Where-Object DefaultOutboundAction -ne 'Allow').Count -eq 0) 'Original outbound profile actions not restored'
Assert (@($script:rules | Where-Object {$_.Name -in $names}).Count -eq 0) 'Owned rules not removed'
Assert (($script:rules | Where-Object Name -eq 'SurvivingAllow').Enabled -eq 'True') 'Surviving snapshotted rule not re-enabled'
Assert (($script:rules | Where-Object Name -eq 'ExistingDisabled').Enabled -eq 'False') 'Previously disabled rule unexpectedly enabled'
Assert (@($script:rules | Where-Object Name -eq 'UnrelatedVexGroup').Count -eq 1) 'Unrelated rule in the same group deleted'
$script:rules += @(
    [pscustomobject]@{Name='LegacyTunnel';Direction='Outbound';Action='Allow';Enabled='True';Group='VEX VPN AntiLeak';DisplayName='VEX VPN tunnel'},
    [pscustomobject]@{Name='LegacyBypass';Direction='Outbound';Action='Allow';Enabled='True';Group='VEX VPN AntiLeak';DisplayName='VEX VPN bypass 203.0.113.1'})
$legacy = ConvertTo-Json -InputObject @($script:profiles | Select-Object Name,DefaultOutboundAction) -Compress
Assert ((& $restore $legacy) -eq 'ok') 'Legacy profile-only journal cleanup failed'
Assert (@($script:rules | Where-Object {$_.Name -in @('LegacyTunnel','LegacyBypass')}).Count -eq 0) 'Recognized legacy owned rules not removed'
Assert (@($script:rules | Where-Object Name -eq 'UnrelatedVexGroup').Count -eq 1) 'Legacy cleanup deleted unrelated same-group rule'

# Exercise the actual production wrapper over encoded program + JSON stdin.
Assert ($source -match 'var wrapper = "(.*?)" \+ script \+ "(.*?)";') 'Production argument wrapper missing'
$prefix = ConvertFrom-Json ('"'+$Matches[1]+'"')
$suffix = ConvertFrom-Json ('"'+$Matches[2]+'"')
$wrapper = $prefix + 'ConvertTo-Json -InputObject @($args) -Compress' + $suffix
$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseInput($wrapper,[ref]$tokens,[ref]$errors) | Out-Null
Assert ($errors.Count -eq 0) 'Production argument wrapper does not parse'
$arguments = @('ВЕКС сеть $() ` { "quoted" }', ('line'+[Environment]::NewLine+'break'), ('x'*4096), '')
$executable = Join-Path $PSHOME $(if($env:OS -eq 'Windows_NT'){'pwsh.exe'}else{'pwsh'})
$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName=$executable;$startInfo.UseShellExecute=$false
$startInfo.RedirectStandardInput=$true;$startInfo.RedirectStandardOutput=$true;$startInfo.RedirectStandardError=$true
$startInfo.StandardInputEncoding=[Text.UTF8Encoding]::new($false);$startInfo.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$startInfo.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
foreach($option in @('-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapper)))){$startInfo.ArgumentList.Add($option)}
$process = [System.Diagnostics.Process]::Start($startInfo)
try {
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    $process.StandardInput.Write((ConvertTo-Json -InputObject $arguments -Compress));$process.StandardInput.Close()
    if(!$process.WaitForExit(10000)){$process.Kill($true);throw 'Argument transport test timed out'}
    Assert ($process.ExitCode -eq 0) ('Argument transport failed: '+$stderr.GetAwaiter().GetResult())
    $actual=@($stdout.GetAwaiter().GetResult() | ConvertFrom-Json)
    Assert ($actual.Count -eq $arguments.Count) 'Argument count changed during transport'
    for($i=0;$i -lt $arguments.Count;$i++){Assert ($actual[$i] -ceq $arguments[$i]) "Argument $i changed or executed during transport"}
} finally {$process.Dispose()}
Write-Output 'Network safety policy regression tests passed' 
