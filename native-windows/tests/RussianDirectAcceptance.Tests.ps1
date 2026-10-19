#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../scripts/verify-public-vpn.ps1') -FunctionsOnly
. (Join-Path $PSScriptRoot '../scripts/RussianDirectAcceptance.ps1')

function Assert-DirectFixture([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$image = 'C:\Program Files\VEX\vex-awg.exe'
$parameters = 'C:\ProgramData\VEX\VPN\Private\routing-parameters.json'
function RoutingProcess([string]$CommandLine = ('"' + $image + '" -f --parameters ' + $parameters + ' vex'), [int]$ParentId = 100, [string]$Path = $image) {
    return [pscustomobject]@{ ProcessId = 200; ParentProcessId = $ParentId; ExecutablePath = $Path; CommandLine = $CommandLine }
}
Assert-DirectFixture (Test-PublicVpnRoutingProcessIdentity (RoutingProcess) 100 $image $parameters) 'Exact installed routing child was rejected.'
Assert-DirectFixture (Test-PublicVpnRoutingProcessIdentity (RoutingProcess ('"' + $image + '" -f --parameters "' + $parameters + '" vex')) 100 $image $parameters) 'Quoted fixed parameters were rejected.'
foreach ($process in @(
    (RoutingProcess ('"' + $image + '" --get-routing-authorization vex')),
    (RoutingProcess ('"' + $image + '" -f --parameters C:\Other\parameters.json vex')),
    (RoutingProcess ('"' + $image + '" -f --parameters ' + $parameters + ' other')),
    (RoutingProcess ('"' + $image + '" -f --parameters ' + $parameters + " vex`n")),
    (RoutingProcess -ParentId 999),
    (RoutingProcess -Path 'C:\Other\vex-awg.exe')
)) { Assert-DirectFixture (-not (Test-PublicVpnRoutingProcessIdentity $process 100 $image $parameters)) 'Foreign/control routing process qualified.' }

function SocketFixture([int]$PidValue = 200, [string]$Remote = '77.88.55.50', [string]$Local = '10.1.2.3', [int]$StateValue = 5, [int]$Port = 443) {
    return [pscustomobject]@{ OwningProcess = $PidValue; RemoteAddress = $Remote; LocalAddress = $Local; State = $StateValue; RemotePort = $Port }
}
$locals = @([pscustomobject]@{ IPAddress = '10.1.2.3'; InterfaceIndex = 7 })
Assert-DirectFixture (Test-WindowsRussianDirectSocket (SocketFixture) 200 '77.88.55.50' 7 30 $locals) 'Owned established physical socket was rejected.'
foreach ($socket in @((SocketFixture -PidValue 201), (SocketFixture -Remote '8.8.8.8'),
    (SocketFixture -Local '10.64.0.2'), (SocketFixture -StateValue 6), (SocketFixture -Port 80))) {
    Assert-DirectFixture (-not (Test-WindowsRussianDirectSocket $socket 200 '77.88.55.50' 7 30 $locals)) 'Foreign, closed or tunnel socket qualified.'
}
Assert-DirectFixture (-not (Test-WindowsRussianDirectSocket (SocketFixture) 200 '77.88.55.50' 7 7 $locals)) 'Tunnel interface was accepted as physical.'
Assert-DirectFixture (-not (Test-WindowsRussianDirectSocket (SocketFixture) 200 '77.88.55.50' 7 30 @($locals[0], $locals[0]))) 'Ambiguous local interface qualified.'
Write-Output 'Russian DIRECT process/socket fixtures passed without network or OS mutation.'
