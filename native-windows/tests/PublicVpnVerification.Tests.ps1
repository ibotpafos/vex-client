# Portable behavioral checks import only the verifier's functions. Networking
# is mocked; actual child-process timeout/output bounds run on every platform.
# The separate non-Windows full-script check must fail before any observation.
#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$sourcePath = Join-Path $PSScriptRoot '../scripts/verify-public-vpn.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'Public VPN verifier does not parse.' }
foreach ($node in @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] })) {
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:checks = 0
function Assert-PublicCheck {
    param([bool]$Condition, [string]$Reason)
    if (-not $Condition) { throw $Reason }
    $script:checks++
}
function Assert-PublicReject {
    param([scriptblock]$Action, [string]$Code = '^public_vpn_')
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    Assert-PublicCheck ($null -ne $caught -and $caught.Exception.Message -match $Code) ('Verifier rejection failed at check ' + $script:checks + '; expected ' + $Code + '; actual: ' + $(if ($null -eq $caught) { 'accepted' } else { $caught.Exception.Message }))
}
function New-PublicResponse {
    param([string]$Output = "8.8.4.4`nVEX_META:200|1.1.1.1|0|0", [int]$ExitCode = 0,
        [bool]$TimedOut = $false, [bool]$OutputExceeded = $false, [int]$ErrorLength = 0)
    return [pscustomobject]@{ Output = $Output; ExitCode = $ExitCode; TimedOut = $TimedOut;
        OutputExceeded = $OutputExceeded; ErrorLength = $ErrorLength }
}
foreach ($public in @('1.1.1.1', '8.8.8.8', '100.128.1.1', '192.0.1.1')) {
    Assert-PublicCheck ((ConvertTo-PublicVpnIpv4 $public) -ceq $public) 'Valid public IPv4 was rejected.'
}
foreach ($bad in @('', 'localhost', '::1', '::ffff:8.8.8.8', '010.1.1.1', '1.1.1', '1.1.1.256', '1.1.1.1 ',
    '0.0.0.0', '10.1.1.1', '100.64.1.1', '100.127.255.255', '127.0.0.1', '169.254.1.1', '172.16.1.1',
    '172.31.1.1', '192.0.0.9', '192.0.2.1', '192.88.99.1', '192.168.1.1', '198.18.1.1', '198.19.1.1',
    '198.51.100.1', '203.0.113.1', '224.0.0.1', '255.255.255.255', '1.1.1.1" --insecure')) {
    Assert-PublicReject { ConvertTo-PublicVpnIpv4 $bad }
}
Assert-PublicReject { Get-PublicVpnExpectedSetHash @() }
Assert-PublicReject { Get-PublicVpnExpectedSetHash @('1.1.1.1', '127.0.0.1') }
Assert-PublicCheck ((Get-PublicVpnExpectedSetHash @('8.8.8.8', '1.1.1.1', '8.8.8.8')) -ceq
    (Get-PublicVpnExpectedSetHash @('1.1.1.1', '8.8.8.8'))) 'Expected exit-set pin is not canonical.'
foreach ($body in @('8.8.4.4', "8.8.4.4`n", "8.8.4.4`r`n")) {
    $parsed = ConvertFrom-PublicVpnCurlResult (New-PublicResponse ($body + "`nVEX_META:200|1.1.1.1|0|0")) '1.1.1.1'
    Assert-PublicCheck ($parsed -ceq '8.8.4.4') 'Plaintext observer IPv4 or AWS newline was misparsed.'
}
foreach ($bad in @('8.8.4.4VEX_META:200|1.1.1.1|0|0', "8.8.4.4`nVEX_META:200|1.1.1.1|0|0`n",
    "8.8.4.4`nVEX_META:200|1.1.1.1|0", "8.8.4.4`nVEX_META:200|1.1.1.1|0|0garbage",
    "8.8.4.4`nVEX_META:302|1.1.1.1|0|0", "8.8.4.4`nVEX_META:500|1.1.1.1|0|0",
    "8.8.4.4`nVEX_META:200|1.1.1.1|1|0", "8.8.4.4`nVEX_META:200|1.1.1.1|0|60",
    "8.8.4.4`nVEX_META:200|8.8.8.8|0|0", "8.8.4.4`nVEX_META:200|127.0.0.1|0|0",
    "{`"ip`":`"8.8.4.4`"}`nVEX_META:200|1.1.1.1|0|0", "8.8.4.4 1.1.1.1`nVEX_META:200|1.1.1.1|0|0",
    " 8.8.4.4`nVEX_META:200|1.1.1.1|0|0", "010.1.1.1`nVEX_META:200|1.1.1.1|0|0",
    "127.0.0.1`nVEX_META:200|1.1.1.1|0|0", (('x' * 300) + "`nVEX_META:200|1.1.1.1|0|0"))) {
    Assert-PublicReject { ConvertFrom-PublicVpnCurlResult (New-PublicResponse $bad) '1.1.1.1' }
}
Assert-PublicReject { ConvertFrom-PublicVpnCurlResult (New-PublicResponse -ExitCode 22) '1.1.1.1' }
Assert-PublicReject { ConvertFrom-PublicVpnCurlResult (New-PublicResponse -TimedOut $true) '1.1.1.1' } 'public_vpn_probe_timeout'
Assert-PublicReject { ConvertFrom-PublicVpnCurlResult (New-PublicResponse -OutputExceeded $true) '1.1.1.1' } 'public_vpn_probe_output_limit'
Assert-PublicReject { ConvertFrom-PublicVpnCurlResult (New-PublicResponse -ErrorLength 1) '1.1.1.1' }
$argsText = Get-PublicVpnCurlArguments 'api.ipify.org' '1.1.1.1'
Assert-PublicCheck ($argsText.StartsWith('--disable ') -and $argsText.Contains('--proxy ""') -and
    $argsText.Contains('--noproxy "*"') -and $argsText.Contains('--resolve "api.ipify.org:443:1.1.1.1"') -and
    $argsText -notmatch '--insecure|--location|--config|--interface') 'Probe can inherit proxy/config, bypass TLS, redirect, or force a physical/tunnel socket instead of normal routing.'
Assert-PublicReject { Get-PublicVpnCurlArguments 'attacker.invalid' '1.1.1.1' }
Assert-PublicReject { Get-PublicVpnCurlArguments 'api.ipify.org' '1.1.1.1" --insecure' }

Initialize-PublicVpnNativeProbe
$script:childPath = Join-Path $PSHOME $(if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' }
} else { 'pwsh' })
function Invoke-PublicChild {
    param([string]$Command, [int]$Timeout = 5000, [int]$Limit = 512)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
    return [VexPublicVpnBoundedProcess]::Run($script:childPath, ('-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encoded), $Timeout, $Limit)
}
$child = Invoke-PublicChild '[Console]::Write("8.8.4.4`nVEX_META:200|1.1.1.1|0|0")'
Assert-PublicCheck ((ConvertFrom-PublicVpnCurlResult $child '1.1.1.1') -ceq '8.8.4.4') 'Actual bounded child output lost valid metadata.'
$child = Invoke-PublicChild '[Console]::Write("x" * 100000)'
Assert-PublicCheck ($child.OutputExceeded -and $child.Output.Length -le 512) 'Unbounded actual stdout escaped the process limit.'
$child = Invoke-PublicChild '[Console]::Error.Write("x" * 100000)'
Assert-PublicCheck ($child.OutputExceeded -and $child.ErrorLength -le 512) 'Unbounded actual stderr escaped the process limit.'
$clock = [Diagnostics.Stopwatch]::StartNew()
$child = Invoke-PublicChild 'Start-Sleep -Seconds 20' -Timeout 250
Assert-PublicCheck ($child.TimedOut -and $clock.Elapsed.TotalSeconds -lt 5) 'Actual hanging child was not killed inside its deadline.'
$child = Invoke-PublicChild '[Console]::Write(($null -eq [Environment]::GetEnvironmentVariable("HTTPS_PROXY") -and $null -eq [Environment]::GetEnvironmentVariable("ALL_PROXY")))'
Assert-PublicCheck ($child.Output -ceq 'True') 'Probe inherited HTTPS/ALL proxy environment.'
Assert-PublicReject { [VexPublicVpnBoundedProcess]::Run($script:childPath, '', 0, 512) } 'public_vpn_process_budget_invalid'

$script:routeIndex = 7
$script:routeSourceIndex = 7
$script:routeSource = '10.8.0.2'
$script:routeCount = 1
function Find-NetRoute {
    param($RemoteIPAddress, $ErrorAction)
    for ($i = 0; $i -lt $script:routeCount; $i++) {
        [pscustomobject]@{ DestinationPrefix = '0.0.0.0/0'; InterfaceIndex = $script:routeIndex; NextHop = '0.0.0.0' }
    }
    [pscustomobject]@{ IPAddress = $script:routeSource; InterfaceIndex = $script:routeSourceIndex }
}
$state = [pscustomobject]@{ Phase = 'Connected'; VexIndex = 7; PhysicalIndexes = @() }
Assert-PublicCheck ((Get-PublicVpnRoute '1.1.1.1' $state).InterfaceIndex -eq 7) 'Actual best-route result rejected the VEX interface.'
$script:routeIndex = 3; $script:routeSourceIndex = 3
Assert-PublicReject { Get-PublicVpnRoute '1.1.1.1' $state } 'public_vpn_observer_route_wrong_interface'
$state = [pscustomobject]@{ Phase = 'Baseline'; VexIndex = 0; PhysicalIndexes = @(3) }
Assert-PublicCheck ((Get-PublicVpnRoute '1.1.1.1' $state).InterfaceIndex -eq 3) 'Physical default route was rejected.'
$script:routeIndex = 7; $script:routeSourceIndex = 7
Assert-PublicReject { Get-PublicVpnRoute '1.1.1.1' $state } 'public_vpn_observer_route_wrong_interface'
$script:routeIndex = 3; $script:routeSourceIndex = 4
Assert-PublicReject { Get-PublicVpnRoute '1.1.1.1' $state } 'public_vpn_best_route_invalid'
$script:routeSourceIndex = 3; $script:routeCount = 0
Assert-PublicReject { Get-PublicVpnRoute '1.1.1.1' $state } 'public_vpn_best_route_invalid'
$script:routeCount = 2
Assert-PublicReject { Get-PublicVpnRoute '1.1.1.1' $state } 'public_vpn_best_route_invalid'
$script:routeCount = 1; $script:routeSource = '127.0.0.1'
Assert-PublicReject { Get-PublicVpnRoute '1.1.1.1' $state } 'public_vpn_route_source_invalid'

$now = [DateTimeOffset]::UtcNow
$machine = 'a' * 64
$expected = Get-PublicVpnExpectedSetHash @('8.8.4.4')
function New-PublicDocument {
    param([string]$PhaseName = 'Baseline', [DateTimeOffset]$Started = $now.AddSeconds(-10),
        [DateTimeOffset]$Completed = $now.AddSeconds(-1), [string]$Ip = '1.1.1.1')
    $ipHash = Get-PublicVpnTextHash $Ip
    $observers = @()
    foreach ($hostName in @('api.ipify.org', 'checkip.amazonaws.com')) {
        $observers += [pscustomobject]@{ observer = $hostName; observed_at_utc = $Started.AddSeconds(1).ToString('O');
            public_ipv4_sha256 = $ipHash; remote_ipv4_sha256 = ('b' * 64); interface_index = 3;
            route_source_sha256 = ('c' * 64); route_verified = $true; https_status = 200; tls_verified = $true;
            redirects = 0; proxy_disabled = $true; ipv4_only = $true }
    }
    return [pscustomobject]@{ schema = 'vex.windows-public-vpn-verification.v1'; phase = $PhaseName;
        run_id = [Guid]::NewGuid().ToString('N'); observation_id = [Guid]::NewGuid().ToString('N');
        machine_sha256 = $machine; expected_exit_set_sha256 = $expected; started_at_utc = $Started.ToString('O');
        completed_at_utc = $Completed.ToString('O'); public_ipv4_sha256 = $ipHash; observers = $observers;
        passed = $true; baseline_sha256 = $null; stage = 'completed';
        actual_public_internet_vpn_egress_verified = $PhaseName -eq 'Connected'; restored_baseline_egress_verified = $false;
        authenticated_application_verified = $false; dns_leakage_verified = $false; ipv6_verified = $false;
        failure_recovery_verified = $false; signed_installed_ipc_verified = $false; reboot_verified = $false }
}
$valid = New-PublicDocument
$null = Assert-PublicVpnDocument $valid 'Baseline' $machine $expected $now 600
$script:checks++
foreach ($mutation in @(
    { param($d) $d.schema = 'vex.windows-public-vpn-verification.v0' },
    { param($d) $d.phase = 'Connected' },
    { param($d) $d.run_id = [Guid]::Empty.ToString('N') },
    { param($d) $d.observation_id = 'bad' },
    { param($d) $d.machine_sha256 = ('f' * 64) },
    { param($d) $d.expected_exit_set_sha256 = ('f' * 64) },
    { param($d) $d.passed = 'true' },
    { param($d) $d.stage = 'network-preflight' },
    { param($d) $d.actual_public_internet_vpn_egress_verified = $true },
    { param($d) $d.authenticated_application_verified = $true },
    { param($d) $d.dns_leakage_verified = 'false' },
    { param($d) $d.public_ipv4_sha256 = 'garbage' },
    { param($d) $d.observers[0].public_ipv4_sha256 = ('f' * 64) },
    { param($d) $d.observers[0].tls_verified = 'true' },
    { param($d) $d.observers[0].route_verified = $false },
    { param($d) $d.observers[0].proxy_disabled = $false },
    { param($d) $d.observers[0].ipv4_only = $false },
    { param($d) $d.observers[0].https_status = '200' },
    { param($d) $d.observers[0].redirects = '0' },
    { param($d) $d.observers[0].interface_index = '3' },
    { param($d) $d.observers[0].remote_ipv4_sha256 = 'not-a-hash' },
    { param($d) $d.observers[0].observed_at_utc = $now.AddMinutes(-5).ToString('O') },
    { param($d) $d.observers[0].observer = $d.observers[1].observer },
    { param($d) $d.observers = @($d.observers[0]) },
    { param($d) $d.PSObject.Properties.Remove('completed_at_utc') },
    { param($d) $d.observers[0].PSObject.Properties.Remove('tls_verified') }
)) {
    $document = New-PublicDocument
    & $mutation $document
    Assert-PublicReject { Assert-PublicVpnDocument $document 'Baseline' $machine $expected $now 600 }
}
# JSON integer decoding differs across 5.1/7. Validate early observer failures
# for Int32 AND Int64 so an unparenthesized -and cannot reset preceding -or.
foreach ($index in @([int]3, [long]3)) {
    foreach ($mutation in @(
        { param($o) $o.observer = 'attacker.invalid' },
        { param($o) $o.observed_at_utc = $now.AddMinutes(-5).ToString('O') },
        { param($o) $o.public_ipv4_sha256 = ('f' * 64) },
        { param($o) $o.remote_ipv4_sha256 = 'garbage' },
        { param($o) $o.route_source_sha256 = 'garbage' }
    )) {
        $document = New-PublicDocument
        $document.observers[0].interface_index = $index
        & $mutation $document.observers[0]
        Assert-PublicReject { Assert-PublicVpnDocument $document 'Baseline' $machine $expected $now 600 } 'public_vpn_prior_observers_invalid'
    }
}
foreach ($document in @(
    (New-PublicDocument -Started $now.AddSeconds(-1000) -Completed $now.AddSeconds(-990)),
    (New-PublicDocument -Started $now.AddSeconds(60) -Completed $now.AddSeconds(70)),
    (New-PublicDocument -Started $now.AddSeconds(-1) -Completed $now.AddSeconds(-10)),
    (New-PublicDocument -Started $now.AddSeconds(-100) -Completed $now.AddSeconds(-1))
)) {
    Assert-PublicReject { Assert-PublicVpnDocument $document 'Baseline' $machine $expected $now 600 } 'public_vpn_prior_evidence_stale_or_future'
}
Assert-PublicReject { ConvertTo-PublicVpnTimestamp '2026-01-01' }
Assert-PublicReject { ConvertTo-PublicVpnTimestamp $now.ToOffset([TimeSpan]::FromHours(1)).ToString('O') }
$baselineHash = Get-PublicVpnTextHash '1.1.1.1'
$pair = @([pscustomobject]@{ parsed_ipv4 = '8.8.4.4' }, [pscustomobject]@{ parsed_ipv4 = '8.8.4.4' })
Assert-PublicCheck ((Test-PublicVpnPhaseResults 'Connected' $pair @('8.8.4.4') $baselineHash) -ceq
    (Get-PublicVpnTextHash '8.8.4.4')) 'Real expected remote exit was not accepted.'
Assert-PublicReject { Test-PublicVpnPhaseResults 'Connected' $pair @('8.8.4.4') (Get-PublicVpnTextHash '8.8.4.4') }
Assert-PublicReject { Test-PublicVpnPhaseResults 'Connected' $pair @('8.8.8.8') $baselineHash }
Assert-PublicReject { Test-PublicVpnPhaseResults 'Restored' $pair @('8.8.4.4') $baselineHash }
Assert-PublicReject { Test-PublicVpnPhaseResults 'Baseline' $pair @('8.8.4.4') $null }
$pair[1].parsed_ipv4 = '8.8.8.8'
Assert-PublicReject { Test-PublicVpnPhaseResults 'Connected' $pair @('8.8.4.4') $baselineHash }

$root = Join-Path ([IO.Path]::GetTempPath()) ('vex-public-verifier-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
try {
    $path = Join-Path $root 'baseline.json'
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(((New-PublicDocument) | ConvertTo-Json -Depth 6))
    [IO.File]::WriteAllBytes($path, $bytes)
    $read = Read-PublicVpnEvidence $path
    $null = Assert-PublicVpnDocument $read.Document 'Baseline' $machine $expected $now 600
    Assert-PublicCheck ($read.Sha256 -ceq (Get-PublicVpnHash $bytes)) 'Baseline chain hash does not cover the exact artifact bytes.'
    Assert-PublicReject { Read-PublicVpnEvidence '' }
    [IO.File]::WriteAllText($path, ('x' * 16385))
    Assert-PublicReject { Read-PublicVpnEvidence $path } 'public_vpn_prior_evidence_size_invalid'
    [IO.File]::WriteAllBytes($path, [byte[]]@(0xc3, 0x28))
    $badUtf8 = $false
    try { Read-PublicVpnEvidence $path | Out-Null } catch { $badUtf8 = $true }
    Assert-PublicCheck $badUtf8 'Invalid UTF-8 baseline bytes were silently normalized.'

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        $nonWindowsOutput = Join-Path $root 'must-not-be-created.json'
        $command = '$ErrorActionPreference="Stop"; try { & ' + "'" + $sourcePath.Replace("'", "''") +
            "'" + ' -Phase Baseline -ResultPath ' + "'" + $nonWindowsOutput.Replace("'", "''") +
            "'" + ' -ExpectedVpnExitIpv4 8.8.4.4 } catch { [Console]::Write($_.Exception.Message) }'
        $child = Invoke-PublicChild $command
        Assert-PublicCheck ($child.Output -ceq 'public_vpn_requires_windows' -and -not [IO.File]::Exists($nonWindowsOutput)) 'Non-Windows full verifier ran observations or created evidence.'
    }

    # Run the actual top-level phase orchestration with only OS/network/probe
    # dependencies substituted. This exercises CreateNew, chain order and flags.
    $mainText = $ast.ParamBlock.Extent.Text + "`n" + (@($ast.EndBlock.Statements |
        Where-Object { $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] } |
        ForEach-Object { $_.Extent.Text }) -join "`n")
    $main = [scriptblock]::Create($mainText)
    function Assert-PublicVpnWindows { }
    function Assert-PublicVpnAdministrator { }
    function Get-PublicVpnMachineHash { return $machine }
    function Resolve-PublicVpnSystemCurl { return $script:childPath }
    function Get-PublicVpnNetworkState {
        param($PhaseName)
        return [pscustomobject]@{ Phase = $PhaseName; VexIndex = $(if ($PhaseName -eq 'Connected') { 7 } else { 0 }); PhysicalIndexes = @(3) }
    }
    $script:observationIp = '1.1.1.1'
    function Invoke-PublicVpnObserver {
        param($HostName, $State, $CurlPath)
        return [pscustomobject]@{ observer = $HostName; observed_at_utc = [DateTimeOffset]::UtcNow.ToString('O');
            public_ipv4_sha256 = (Get-PublicVpnTextHash $script:observationIp); remote_ipv4_sha256 = ('b' * 64);
            interface_index = $(if ($State.Phase -eq 'Connected') { 7 } else { 3 }); route_source_sha256 = ('c' * 64);
            route_verified = $true; https_status = 200; tls_verified = $true; redirects = 0; proxy_disabled = $true;
            ipv4_only = $true; parsed_ipv4 = $script:observationIp }
    }
    $baselinePath = Join-Path $root 'actual-baseline.json'
    & $main -Phase Baseline -ResultPath $baselinePath -ExpectedVpnExitIpv4 @('8.8.4.4') | Out-Null
    $baseline = Read-PublicVpnEvidence $baselinePath
    Assert-PublicCheck ($baseline.Document.passed -and -not $baseline.Document.actual_public_internet_vpn_egress_verified) 'Baseline claims a VPN proof.'
    $beforeHash = $baseline.Sha256
    $rejected = $false
    try { & $main -Phase Baseline -ResultPath $baselinePath -ExpectedVpnExitIpv4 @('8.8.4.4') | Out-Null } catch { $rejected = $true }
    Assert-PublicCheck ($rejected -and (Read-PublicVpnEvidence $baselinePath).Sha256 -ceq $beforeHash) 'Existing output artifact was overwritten.'
    $script:observationIp = '8.8.4.4'
    $connectedPath = Join-Path $root 'actual-connected.json'
    & $main -Phase Connected -ResultPath $connectedPath -BaselinePath $baselinePath -ExpectedVpnExitIpv4 @('8.8.4.4') | Out-Null
    $connected = Read-PublicVpnEvidence $connectedPath
    Assert-PublicCheck ($connected.Document.passed -and $connected.Document.actual_public_internet_vpn_egress_verified -and
        $connected.Document.baseline_sha256 -ceq $baseline.Sha256 -and $connected.Document.run_id -ceq $baseline.Document.run_id) 'Connected phase failed to establish its baseline chain.'
    foreach ($flag in @('authenticated_application_verified', 'dns_leakage_verified', 'ipv6_verified',
        'failure_recovery_verified', 'signed_installed_ipc_verified', 'reboot_verified')) {
        Assert-PublicCheck (-not $connected.Document.$flag) 'Public egress phase overclaimed another acceptance gate.'
    }
    $script:observationIp = '1.1.1.1'
    $restoredPath = Join-Path $root 'actual-restored.json'
    & $main -Phase Restored -ResultPath $restoredPath -BaselinePath $baselinePath -ConnectedPath $connectedPath -ExpectedVpnExitIpv4 @('8.8.4.4') | Out-Null
    $restored = Read-PublicVpnEvidence $restoredPath
    Assert-PublicCheck ($restored.Document.passed -and $restored.Document.restored_baseline_egress_verified -and
        -not $restored.Document.actual_public_internet_vpn_egress_verified -and $restored.Document.connected_sha256 -ceq $connected.Sha256) 'Restored phase failed its connected chain or overclaimed current VPN egress.'
    $missingBaselineOutput = Join-Path $root 'missing-baseline-result.json'
    Assert-PublicReject { & $main -Phase Connected -ResultPath $missingBaselineOutput -ExpectedVpnExitIpv4 @('8.8.4.4') }
    Assert-PublicCheck (-not [IO.File]::Exists($missingBaselineOutput)) 'Missing baseline produced a result file.'
    $wrongPhaseOutput = Join-Path $root 'wrong-phase-result.json'
    Assert-PublicReject { & $main -Phase Connected -ResultPath $wrongPhaseOutput -BaselinePath $connectedPath -ExpectedVpnExitIpv4 @('8.8.4.4') }
    Assert-PublicCheck (-not [IO.File]::Exists($wrongPhaseOutput)) 'Connected evidence was replayed as baseline.'
    $mutated = Read-PublicVpnEvidence $connectedPath
    $mutated.Document.baseline_sha256 = ('f' * 64)
    $badConnectedPath = Join-Path $root 'bad-connected.json'
    [IO.File]::WriteAllText($badConnectedPath, ($mutated.Document | ConvertTo-Json -Depth 6))
    Assert-PublicReject { & $main -Phase Restored -ResultPath (Join-Path $root 'bad-chain-result.json') -BaselinePath $baselinePath -ConnectedPath $badConnectedPath -ExpectedVpnExitIpv4 @('8.8.4.4') } 'public_vpn_prior_phase_chain_invalid'
    $script:observationIp = '8.8.8.8'
    $wrongExitPath = Join-Path $root 'wrong-exit-result.json'
    Assert-PublicReject { & $main -Phase Connected -ResultPath $wrongExitPath -BaselinePath $baselinePath -ExpectedVpnExitIpv4 @('8.8.4.4') } 'public_vpn_exit_not_expected_or_not_changed'
    $wrongExit = Read-PublicVpnEvidence $wrongExitPath
    Assert-PublicCheck (-not $wrongExit.Document.passed -and -not $wrongExit.Document.actual_public_internet_vpn_egress_verified) 'Failed observation claims public egress.'
}
finally { Remove-Item -LiteralPath $root -Recurse -Force }
Write-Output ('Public VPN verifier: {0} behavioral checks passed; no live network or VPN state changed.' -f $script:checks)
