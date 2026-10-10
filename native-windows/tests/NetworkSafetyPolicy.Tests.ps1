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
$capture = Script-With 'Version=3;Profiles='
$arm = Script-With 'New-NetFirewallRule -Name $names[0]'
$refresh = Script-With '# Narrow an existing owned policy'
$restore = Script-With '# Migration of the old profile-only journal'
$install = Script-With "if(`$null -ne `$existing){'existing';return}"
$verifyRoute = Script-With '# Verify the effective route after owned stale routes were removed'
$removeRoutes = Script-With 'route_cleanup_failed'

$script:physical = @([pscustomobject]@{Status='Up';InterfaceIndex=10},[pscustomobject]@{Status='Up';InterfaceIndex=20})
$script:defaults4 = @(
    [pscustomobject]@{InterfaceIndex=99;NextHop='0.0.0.0';RouteMetric=0},
    [pscustomobject]@{InterfaceIndex=20;NextHop='192.168.1.1';RouteMetric=1},
    [pscustomobject]@{InterfaceIndex=10;NextHop='192.168.2.1';RouteMetric=30})
$script:defaults6 = @([pscustomobject]@{InterfaceIndex=99;NextHop='::';RouteMetric=0})
$script:hostRoutes = @([pscustomobject]@{DestinationPrefix='203.0.113.1/32';InterfaceIndex=20;NextHop='192.168.1.1';RouteMetric=0;Protocol='NetMgmt'})
$routeReceiptDirectory=Join-Path ([IO.Path]::GetTempPath()) ('vex-route-policy-'+[Guid]::NewGuid().ToString('N'))
$routeCreationId='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$routeReceiptPath=Join-Path $routeReceiptDirectory ($routeCreationId+'.json')
$routeMetric='51234'
$script:physicalLookups = 0
function Get-NetAdapter { param([switch]$Physical) $script:physicalLookups++; $script:physical }
function Get-NetIPInterface { param($AddressFamily,$InterfaceIndex) [pscustomobject]@{InterfaceMetric=$(if($InterfaceIndex -eq 10){5}else{40})} }
function Get-NetIPAddress {
    param($AddressFamily,$IPAddress,$PolicyStore)
    if($IPAddress -eq '192.168.2.2'){
        [pscustomobject]@{IPAddress=$IPAddress;InterfaceIndex=10;AddressState='Preferred'}
    }
    if($IPAddress -eq '10.253.253.2'){
        [pscustomobject]@{IPAddress=$IPAddress;InterfaceIndex=99;AddressState='Preferred'}
    }
}
function Get-NetRoute {
    [CmdletBinding()]param($AddressFamily,$DestinationPrefix,[int]$InterfaceIndex,$PolicyStore)
    if($script:routeQueryFails){throw 'CIM route query unavailable'}
    if(!$DestinationPrefix){return $script:hostRoutes}
    if ($DestinationPrefix -eq '0.0.0.0/0') { return $script:defaults4 }
    if ($DestinationPrefix -eq '::/0') { return $script:defaults6 }
    $script:hostRoutes | Where-Object {$_.DestinationPrefix -eq $DestinationPrefix -and (!$InterfaceIndex -or $_.InterfaceIndex -eq $InterfaceIndex)}
}
function New-NetRoute {
    param($DestinationPrefix,$InterfaceIndex,$NextHop,$RouteMetric,$Protocol,$PolicyStore)
    $script:hostRoutes += [pscustomobject]@{DestinationPrefix=$DestinationPrefix;InterfaceIndex=$InterfaceIndex;NextHop=$NextHop;RouteMetric=$RouteMetric;Protocol=$Protocol}
}
function Find-NetRoute {
    [CmdletBinding()]param($RemoteIPAddress)
    # Like Windows, return selected address metadata and the effective route.
    [pscustomobject]@{IPAddress=$RemoteIPAddress;InterfaceIndex=$script:effectiveRoute.InterfaceIndex}
    $script:effectiveRoute
}
function Remove-NetRoute {
    [CmdletBinding(SupportsShouldProcess)]param([Parameter(ValueFromPipeline)]$InputObject)
    process {if($script:skipRouteRemoval){return};$script:hostRoutes=@($script:hostRoutes | Where-Object {
        $_.DestinationPrefix -ne $InputObject.DestinationPrefix -or $_.InterfaceIndex -ne $InputObject.InterfaceIndex -or $_.NextHop -ne $InputObject.NextHop -or $_.RouteMetric -ne $InputObject.RouteMetric -or $_.Protocol -ne $InputObject.Protocol
    })}
}
foreach ($loopback in @('127.0.0.1', '127.10.20.30', '::1')) {
    $route = (& $findRoute $loopback $(if($loopback.Contains(':')){'IPv6'}else{'IPv4'}) '32' 'False') | ConvertFrom-Json
    Assert ($route.Loopback -and !$route.Created) 'Loopback endpoint must use its native route without a physical bypass'
}
Assert ($script:physicalLookups -eq 0 -and $script:hostRoutes.Count -eq 1) 'Loopback endpoint touched physical route state'
$route = (& $findRoute '203.0.113.1' 'IPv4' '32' 'False') | ConvertFrom-Json
Assert ($script:physicalLookups -eq 1) 'External endpoint must still resolve its physical uplink'
Assert ($route.InterfaceIndex -eq 10 -and $route.NextHop -eq '192.168.2.1' -and $route.Created) 'Stale host route or tunnel selected instead of physical gateway'
$result = & $install '203.0.113.1' '10' '192.168.2.1' '32' $routeMetric $routeCreationId $routeReceiptPath
Assert ($result -eq 'created') 'New physical bypass not created'
$proof=[IO.File]::ReadAllText($routeReceiptPath) | ConvertFrom-Json
Assert ($proof.CreationId -ceq $routeCreationId -and $proof.RouteMetric -eq $routeMetric -and $proof.Protocol -ceq 'NetMgmt') 'Creation must durably confirm actual route metadata before acknowledgment'
$result = & $install '203.0.113.1' '10' '192.168.2.1' '32' $routeMetric $routeCreationId $routeReceiptPath
Assert ($result -eq 'existing') 'Existing foreign route must not be claimed as newly created'
$script:effectiveRoute=[pscustomobject]@{InterfaceIndex=10;NextHop='192.168.2.1'}
Assert ((& $verifyRoute '203.0.113.1' '10' '192.168.2.1') -eq 'ok') 'Correct effective physical interface and gateway should verify'
$script:effectiveRoute=[pscustomobject]@{InterfaceIndex=10;NextHop='192.168.1.1'}
$routesBeforeConflict=$script:hostRoutes.Count
Assert-Rejected {& $verifyRoute '203.0.113.1' '10' '192.168.2.1'} 'Foreign lower-metric route via stale gateway on the same NIC must fail verification'
Assert ($script:hostRoutes.Count -eq $routesBeforeConflict) 'Effective route verification must not delete foreign routes'
$script:effectiveRoute=[pscustomobject]@{InterfaceIndex=20;NextHop='192.168.2.1'}
Assert-Rejected {& $verifyRoute '203.0.113.1' '10' '192.168.2.1'} 'Correct next-hop on a different NIC must fail verification'
$script:effectiveRoute=[pscustomobject]@{InterfaceIndex=10;NextHop='fe80::1%10'}
Assert ((& $verifyRoute '2001:db8::1' '10' 'fe80::1') -eq 'ok') 'IPv6 next-hop must compare address bytes while binding the interface separately'
& $removeRoutes '203.0.113.1' '10' '192.168.2.1' '32' $routeMetric $routeCreationId $routeReceiptPath | Out-Null
Assert ($script:hostRoutes.Count -eq 1 -and $script:hostRoutes[0].InterfaceIndex -eq 20) 'Cleanup must remove only the owned route tuple and preserve foreign routes'
# Reinstall after cleanup for the subsequent physical-uplink assertions.
Assert ((& $install '203.0.113.1' '10' '192.168.2.1' '32' $routeMetric $routeCreationId $routeReceiptPath) -eq 'created') 'Owned route should be reusable after verified cleanup'
$script:skipRouteRemoval=$true
Assert-Rejected {& $removeRoutes '203.0.113.1' '10' '192.168.2.1' '32' $routeMetric $routeCreationId $routeReceiptPath} 'A silent owned-route removal failure must not claim verified cleanup'
$script:skipRouteRemoval=$false
Assert ($script:hostRoutes.Count -eq 2) 'Failed cleanup must retain ownership and preserve the foreign route'
$script:routeQueryFails=$true
Assert-Rejected {& $removeRoutes '203.0.113.1' '10' '192.168.2.1' '32' $routeMetric $routeCreationId $routeReceiptPath} 'Provider read failure must not be mistaken for an absent route'
$script:routeQueryFails=$false
Assert ([IO.File]::Exists($routeReceiptPath) -and $script:hostRoutes.Count -eq 2) 'Provider read failure discarded durable creation evidence'
# A reset removed VEX's route and another owner replaced the identical tuple.
# Its independent metric/protocol must survive both journal and receipt cleanup.
($script:hostRoutes | Where-Object InterfaceIndex -eq 10).RouteMetric=333
& $removeRoutes '203.0.113.1' '10' '192.168.2.1' '32' $routeMetric $routeCreationId $routeReceiptPath | Out-Null
Assert ($script:hostRoutes.Count -eq 2 -and ![IO.File]::Exists($routeReceiptPath)) 'Foreign same-tuple replacement was removed or old evidence retained'
$pendingId='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$pendingPath=Join-Path $routeReceiptDirectory ($pendingId+'.json')
Assert ((& $install '203.0.113.1' '10' '192.168.2.1' '32' '51235' $pendingId $pendingPath) -eq 'existing') 'Concurrent foreign creation must be acknowledged without acquiring ownership'
Assert (![IO.File]::Exists($pendingPath)) 'Existing foreign route acquired a creation receipt'
# Cancellation/crash before that existing acknowledgment leaves a pending plan.
& $removeRoutes '203.0.113.1' '10' '192.168.2.1' '32' '51235' $pendingId $pendingPath | Out-Null
Assert ($script:hostRoutes.Count -eq 2) 'Pending-plan rollback deleted a differently fingerprinted foreign route'
Assert-Rejected {& $removeRoutes '203.0.113.1' '10' '192.168.2.1' '32' '0' '' ''} 'A still-present legacy tuple must remain ambiguous rather than being deleted'
Assert ($script:hostRoutes.Count -eq 2) 'Legacy cleanup removed an ambiguously owned route'
$script:hostRoutes=@($script:hostRoutes | Where-Object InterfaceIndex -ne 10)
& $removeRoutes '203.0.113.1' '10' '192.168.2.1' '32' '0' '' '' | Out-Null
# Genuine creation with cancellation after the durable receipt remains cleanable.
Assert ((& $install '203.0.113.1' '10' '192.168.2.1' '32' $routeMetric $routeCreationId $routeReceiptPath) -eq 'created') 'Fresh confirmed route was not created'
$savedProof=[IO.File]::ReadAllText($routeReceiptPath)
[IO.File]::Delete($routeReceiptPath)
Assert-Rejected {& $removeRoutes '203.0.113.1' '10' '192.168.2.1' '32' $routeMetric $routeCreationId $routeReceiptPath} 'Matching planned metadata without completed-creation evidence must not authorize deletion'
Assert ($script:hostRoutes.Count -eq 2) 'Missing-receipt cleanup removed an ambiguous route'
[IO.File]::WriteAllText($routeReceiptPath,$savedProof.Replace($routeCreationId,$pendingId))
Assert-Rejected {& $removeRoutes '203.0.113.1' '10' '192.168.2.1' '32' $routeMetric $routeCreationId $routeReceiptPath} 'Wrong creation receipt must not authorize deletion'
[IO.File]::WriteAllText($routeReceiptPath,$savedProof)
& $removeRoutes '203.0.113.1' '10' '192.168.2.1' '32' $routeMetric $routeCreationId $routeReceiptPath | Out-Null
Assert ($script:hostRoutes.Count -eq 1 -and ![IO.File]::Exists($routeReceiptPath)) 'Late-cancel rollback failed to remove the genuinely confirmed route'
# Same metric alone is insufficient when the provider protocol changed.
Assert ((& $install '203.0.113.1' '10' '192.168.2.1' '32' $routeMetric $routeCreationId $routeReceiptPath) -eq 'created') 'Protocol replacement setup failed'
($script:hostRoutes | Where-Object InterfaceIndex -eq 10).Protocol='Local'
& $removeRoutes '203.0.113.1' '10' '192.168.2.1' '32' $routeMetric $routeCreationId $routeReceiptPath | Out-Null
Assert ($script:hostRoutes.Count -eq 2) 'Same-metric foreign protocol replacement was deleted'
$route = (& $findRoute '2001:db8::1' 'IPv6' '128' 'True') | ConvertFrom-Json
Assert $route.Skipped 'Optional AAAA should be skipped without a physical IPv6 uplink'
Assert-Rejected {& $findRoute '2001:db8::1' 'IPv6' '128' 'False'} 'Literal IPv6 endpoint must fail closed without an uplink'
$script:defaults6 += [pscustomobject]@{InterfaceIndex=10;NextHop='fe80::1';RouteMetric=20}
$route = (& $findRoute '2001:db8::1' 'IPv6' '128' 'False') | ConvertFrom-Json
Assert ($route.InterfaceIndex -eq 10 -and $route.NextHop -eq 'fe80::1') 'IPv6 bypass gateway incorrect'
$routesBeforeNative = $script:hostRoutes.Count
$route = (& $findRoute '192.168.2.2' 'IPv4' '32' 'False' 'True') | ConvertFrom-Json
Assert ($route.NativeLocal -and !$route.Created -and $route.InterfaceIndex -eq 10) 'Assigned physical endpoint must retain its native local route'
Assert ($script:hostRoutes.Count -eq $routesBeforeNative) 'Native physical endpoint installed a gateway route'
Assert-Rejected {& $findRoute '203.0.113.3' 'IPv4' '32' 'False' 'True'} 'Trusted local endpoint option must reject an unassigned external address'
Assert-Rejected {& $findRoute '10.253.253.2' 'IPv4' '32' 'False' 'True'} 'Trusted local endpoint option must reject a tunnel address'
$route = (& $findRoute '192.168.2.2' 'IPv4' '32' 'False' 'False') | ConvertFrom-Json
Assert (!$route.NativeLocal -and $route.NextHop -eq '192.168.2.1') 'Production default must preserve normal bypass admission'

$env:SystemRoot = 'C:\Windows'
$script:profiles = @('Domain','Private','Public' | ForEach-Object {[pscustomobject]@{Name=$_;Enabled='True';DefaultOutboundAction='Allow'}})
($script:profiles | Where-Object Name -eq 'Private').Enabled='False'
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
    param($Name,$DisplayName,$Group,$PolicyStore,$Direction,$Action,$InterfaceAlias,$Profile,$RemoteAddress,$InterfaceType,$Protocol,$LocalPort,$RemotePort,$Program,$Service,$IcmpType,$Enabled='True')
    $script:rules += [pscustomobject]@{Name=$Name;Direction=$Direction;Action=$Action;Enabled=$Enabled;Group=$Group;DisplayName=$DisplayName}
    $script:filters[$Name]=@{
        Interface=[pscustomobject]@{InterfaceAlias=@($InterfaceAlias);RuleName=$Name}
        Type=[pscustomobject]@{InterfaceType=@($InterfaceType)}
        Address=[pscustomobject]@{RemoteAddress=@($RemoteAddress)}
        Port=[pscustomobject]@{Protocol=$Protocol;LocalPort=@($LocalPort);RemotePort=@($RemotePort);IcmpType=@($IcmpType)}
        Application=[pscustomobject]@{Program=$Program};Service=[pscustomobject]@{Service=$Service}
    }
}
function Set-NetFirewallRule {
    param([Parameter(ValueFromPipeline)]$InputObject,$Protocol,$RemotePort,$RemoteAddress,$Enabled)
    process {
        if($PSBoundParameters.ContainsKey('Protocol')){$script:filters[$InputObject.Name].Port.Protocol=$Protocol}
        if($PSBoundParameters.ContainsKey('RemotePort')){$script:filters[$InputObject.Name].Port.RemotePort=@($RemotePort)}
        if($PSBoundParameters.ContainsKey('RemoteAddress')){$script:filters[$InputObject.Name].Address.RemoteAddress=@($RemoteAddress)}
        if($PSBoundParameters.ContainsKey('Enabled')){$InputObject.Enabled=$Enabled}
    }
}
function Set-NetFirewallInterfaceFilter {
    param([Parameter(ValueFromPipeline)]$InputObject,$InterfaceAlias)
    process {$InputObject.InterfaceAlias=@($InterfaceAlias)}
}
function Get-NetFirewallInterfaceFilter { param([Parameter(ValueFromPipeline)]$InputObject) process {$script:filters[$InputObject.Name].Interface} }
function Get-NetFirewallInterfaceTypeFilter { param([Parameter(ValueFromPipeline)]$InputObject) process {$script:filters[$InputObject.Name].Type} }
function Get-NetFirewallAddressFilter { param([Parameter(ValueFromPipeline)]$InputObject) process {$script:filters[$InputObject.Name].Address} }
function Get-NetFirewallPortFilter { param([Parameter(ValueFromPipeline)]$InputObject) process {$script:filters[$InputObject.Name].Port} }
function Get-NetFirewallApplicationFilter { param([Parameter(ValueFromPipeline)]$InputObject) process {$script:filters[$InputObject.Name].Application} }
function Get-NetFirewallServiceFilter { param([Parameter(ValueFromPipeline)]$InputObject) process {$script:filters[$InputObject.Name].Service} }
$names = @('Tunnel','Protected','Dhcp4','Dhcp6','Neighbor','ControlPlane' | ForEach-Object {"VEX.AntiLeak.test.$_"})
$ips = @('203.0.113.1','2001:db8::1')
$controlIps = @('203.0.113.2','2001:db8::2')
$allIps = @($ips)+@($controlIps)
$namesJson = ConvertTo-Json -InputObject $names -Compress
$ipsJson = ConvertTo-Json -InputObject $ips -Compress
$controlJson = ConvertTo-Json -InputObject $controlIps -Compress
$allIpsJson = ConvertTo-Json -InputObject $allIps -Compress
$stateJson = & $capture $namesJson 'VEX VPN' $allIpsJson $ipsJson '51820' $controlJson
$state = $stateJson | ConvertFrom-Json
Assert (@($state.DisabledOutboundAllowRuleNames).Count -eq 2 -and 'ExistingAllow' -in $state.DisabledOutboundAllowRuleNames -and 'SurvivingAllow' -in $state.DisabledOutboundAllowRuleNames) 'Snapshot must contain only previously enabled local outbound allows'
& $arm $stateJson $ipsJson | Out-Null
Assert (($script:rules | Where-Object Name -eq 'ExistingAllow').Enabled -eq 'False') 'Default outbound block alone must not leave old allow rules enabled'
Assert ((& $verify $stateJson) -eq 'ok') 'Expected bounded firewall policy should verify'
Assert ($script:filters[$names[1]].Port.Protocol -eq 'UDP' -and $script:filters[$names[1]].Port.RemotePort[0] -eq '51820') 'Physical endpoint exception must admit only the signed UDP port'
Assert ($script:filters[$names[5]].Port.Protocol -eq 'TCP' -and $script:filters[$names[5]].Port.RemotePort[0] -eq '443') 'Physical control-plane exception must admit only HTTPS'
Assert ($script:filters[$names[1]].Address.RemoteAddress.Count -eq $ips.Count -and $controlIps[0] -notin $script:filters[$names[1]].Address.RemoteAddress) 'Control-plane hosts must not inherit the VPN UDP exception'
Assert ($ips[0] -notin $script:filters[$names[5]].Address.RemoteAddress) 'VPN endpoint must not inherit a physical HTTPS exception'
$script:rules += [pscustomobject]@{Name='GpoAllow';Direction='Outbound';Action='Allow';Enabled='True';Group='GPO';DisplayName='GPO'}
Assert-Rejected {& $verify $stateJson} 'An effective GPO allow must prevent a false protected state'
$script:rules = @($script:rules | Where-Object Name -ne 'GpoAllow')
$script:filters[$names[1]].Address.RemoteAddress=@('Any')
Assert-Rejected {& $verify $stateJson} 'A broadened protected-endpoint rule must be rejected'
$script:filters[$names[1]].Address.RemoteAddress=$ips
$script:filters[$names[1]].Port.Protocol='Any'
Assert-Rejected {& $verify $stateJson} 'A physical all-protocol endpoint exception must be rejected'
$script:filters[$names[1]].Port.Protocol='UDP'
$script:filters[$names[1]].Port.RemotePort=@('Any')
Assert-Rejected {& $verify $stateJson} 'A physical all-port endpoint exception must be rejected'
$script:filters[$names[1]].Port.RemotePort=@('51820')
$script:filters[$names[5]].Port.RemotePort=@('22','443')
Assert-Rejected {& $verify $stateJson} 'An extra physical control-plane SSH exception must be rejected'
$script:filters[$names[5]].Port.RemotePort=@('443')
$script:filters[$names[5]].Address.RemoteAddress=@('Any')
Assert-Rejected {& $verify $stateJson} 'A broadened physical control-plane address exception must be rejected'
$script:filters[$names[5]].Address.RemoteAddress=$controlIps
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
# Migrate an already armed v2 rule set while retaining its original baseline:
# the narrow refresh must not disarm, enable old allows, or claim foreign rules.
$v2=[pscustomobject]@{Version=2;Profiles=$state.Profiles;DisabledOutboundAllowRuleNames=$state.DisabledOutboundAllowRuleNames;OwnedRuleNames=@($names[0..4]);AdapterName=$state.AdapterName;ProtectedAddresses=$allIps}
Assert-Rejected {& $verify (ConvertTo-Json -InputObject $v2 -Compress -Depth 5)} 'The legacy broad v2 policy must never be advertised as verified'
$script:rules=@($script:rules | Where-Object {$_.Name -cne $names[5]})
$script:filters[$names[1]].Port.Protocol='Any'
$script:filters[$names[1]].Port.RemotePort=@('Any')
$script:filters[$names[1]].Address.RemoteAddress=$allIps
$migrationNames=@($names[0..4])+@($names[0]+'.ControlPlane')
$migrated=$stateJson | ConvertFrom-Json
$migrated.OwnedRuleNames=$migrationNames
$migrated.AdapterName='VEX replacement'
$migrated.EndpointAddresses=@('203.0.113.7')
$migrated.EndpointPort=51821
$migratedJson=ConvertTo-Json -InputObject $migrated -Compress -Depth 5
& $refresh $migratedJson | Out-Null
Assert ((& $verify $migratedJson) -eq 'ok') 'Migration/refresh must narrow the old physical rule and create a bounded control rule'
Assert (($script:rules | Where-Object Name -eq 'SurvivingAllow').Enabled -eq 'False') 'Migration re-enabled a previously suppressed local allow'
Assert (@($script:profiles | Where-Object DefaultOutboundAction -ne 'Block').Count -eq 0) 'Migration temporarily restored permissive firewall profiles'
Assert ($script:filters[$migrationNames[1]].Port.RemotePort[0] -eq '51821' -and $script:filters[$migrationNames[1]].Address.RemoteAddress[0] -eq '203.0.113.7') 'Endpoint replacement retained an obsolete port/address exception'
Assert (@($script:rules | Where-Object Name -eq 'UnrelatedVexGroup').Count -eq 1) 'Migration modified an unrelated same-group rule'
# An offline control-plane DNS answer is advisory. Disable its owned exception
# instead of creating an Any-address rule or failing a valid cached VPN path.
$migrated.ControlPlaneAddresses=@()
$offlineJson=ConvertTo-Json -InputObject $migrated -Compress -Depth 5
& $refresh $offlineJson | Out-Null
Assert ((& $verify $offlineJson) -eq 'ok') 'Absent control addresses should leave a verified UDP-only physical policy'
$controlRule=$script:rules | Where-Object {$_.Name -ceq $migrationNames[5]}
Assert ($controlRule.Enabled -eq 'False') 'Empty control-plane scope must disable its physical exception'
$controlRule.Enabled='True'
Assert-Rejected {& $verify $offlineJson} 'An enabled placeholder control-plane exception must fail verification'
$controlRule.Enabled='False'
$stateJson=$offlineJson
$names=$migrationNames
$namesJson=ConvertTo-Json -InputObject $names -Compress
# A third party deleted its old rule while VEX was active: do not recreate it
# and still restore the profiles so disconnect cannot trap the user offline.
$script:rules = @($script:rules | Where-Object Name -ne 'ExistingAllow')
Assert ((& $restore $stateJson) -eq 'ok') 'External rule deletion must not prevent restoring original profiles'
Assert (@($script:profiles | Where-Object DefaultOutboundAction -ne 'Allow').Count -eq 0) 'Original outbound profile actions not restored'
Assert (($script:profiles | Where-Object Name -eq 'Private').Enabled -eq 'False') 'Originally disabled profile was not restored after v2 migration'
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

# Exercise exact production capture/arm/verify/restore with 5.1-shaped JSON
# output too. A non-enumerated array must remain a flat journal/address list.
function Test-WindowsPowerShellJsonPolicy {
    function ConvertFrom-Json {
        [CmdletBinding()]param([Parameter(ValueFromPipeline=$true)]$InputObject)
        process {
            $decoded=Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $InputObject -NoEnumerate
            Write-Output -NoEnumerate $decoded
        }
    }
    $compatJson=& $capture $namesJson 'VEX VPN' $allIpsJson $ipsJson '51820' $controlJson
    $compat=Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $compatJson
    Assert ($compat.OwnedRuleNames.Count -eq $names.Count -and $compat.OwnedRuleNames[0] -is [string]) '5.1 capture nested the owned rule names'
    Assert ($compat.ProtectedAddresses.Count -eq $allIps.Count -and $compat.ProtectedAddresses[0] -is [string]) '5.1 capture nested protected addresses'
    Assert ($compat.EndpointAddresses.Count -eq $ips.Count -and $compat.EndpointAddresses[0] -is [string]) '5.1 capture nested endpoint addresses'
    Assert ($compat.ControlPlaneAddresses.Count -eq $controlIps.Count -and $compat.ControlPlaneAddresses[0] -is [string]) '5.1 capture nested control-plane addresses'
    & $arm $compatJson $ipsJson | Out-Null
    Assert ((& $verify $compatJson) -eq 'ok') '5.1 JSON output broadened or broke the bounded firewall policy'
    Assert ((& $restore $compatJson) -eq 'ok') '5.1-shaped journal could not restore original firewall state'
}
Test-WindowsPowerShellJsonPolicy

# Exercise the actual production wrapper over encoded program + JSON stdin.
Assert ($source -match 'var wrapper = "(.*?)" \+ script \+ "(.*?)";') 'Production argument wrapper missing'
$prefix = ConvertFrom-Json ('"'+$Matches[1]+'"')
$suffix = ConvertFrom-Json ('"'+$Matches[2]+'"')
$wrapper = $prefix + 'ConvertTo-Json -InputObject @($args) -Compress' + $suffix
$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseInput($wrapper,[ref]$tokens,[ref]$errors) | Out-Null
Assert ($errors.Count -eq 0) 'Production argument wrapper does not parse'
$arguments = @('ВЕКС сеть $() ` { "quoted" }', ('line'+[Environment]::NewLine+'break'), ('x'*4096), '')
$pwsh = Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
$cases = @([pscustomobject]@{Executable=$pwsh;Wrapper=$wrapper})
# Reproduce 5.1's non-enumerating JSON output on every portable test host.
$cases += [pscustomobject]@{
    Executable=$pwsh
    Wrapper=$wrapper.Replace('ConvertFrom-Json ([Console]::In.ReadToEnd())', 'ConvertFrom-Json ([Console]::In.ReadToEnd()) -NoEnumerate')
}
if ($IsWindows) {
    # Also run the actual host used by the service, rather than only pwsh 7.
    $cases += [pscustomobject]@{
        Executable=(Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell/v1.0/powershell.exe')
        Wrapper=$wrapper
    }
}
foreach ($case in $cases) {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName=$case.Executable;$startInfo.UseShellExecute=$false
    $startInfo.RedirectStandardInput=$true;$startInfo.RedirectStandardOutput=$true;$startInfo.RedirectStandardError=$true
    $startInfo.StandardInputEncoding=[Text.UTF8Encoding]::new($false);$startInfo.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$startInfo.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    foreach($option in @('-NoProfile','-NonInteractive','-ExecutionPolicy','AllSigned','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($case.Wrapper)))){$startInfo.ArgumentList.Add($option)}
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
}
Write-Output 'Network safety policy regression tests passed' 
if([IO.Directory]::Exists($routeReceiptDirectory)){[IO.Directory]::Delete($routeReceiptDirectory,$true)}
