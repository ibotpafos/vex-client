# Portable regression for the exact CI fixture tool resolver/process wrapper.
# Import function definitions only; never execute the Windows networking fixture.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../scripts/invoke-vpn-acceptance.ps1'))
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'VPN acceptance fixture does not parse.' }
foreach ($name in @('Resolve-FixtureTool', 'Invoke-FixtureProcess', 'Resolve-FixtureHostAddress',
    'Read-FixtureEndpointRoutes', 'Get-FixtureHarnessCheckNames', 'Assert-FixtureHarnessResult', 'Get-FixtureAcceptanceLogSummary')) {
    $functions = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true))
    if ($functions.Count -ne 1) { throw "Fixture production function missing: $name" }
    . ([scriptblock]::Create($functions[0].Extent.Text))
}
$script:expectedTool = Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
function Get-Command {
    param($Name, $CommandType)
    if ($Name -notin @('go', 'dotnet') -or $CommandType -ne 'Application') {
        throw 'Unexpected fixture command lookup.'
    }
    # Hosted Windows runners have both setup-action and preinstalled SDKs.
    [pscustomobject]@{Source=$script:expectedTool}
    [pscustomobject]@{Source='missing-preinstalled-sdk'}
}
foreach ($name in @('go', 'dotnet')) {
    $tool = Resolve-FixtureTool -Name $name
    if ($tool -isnot [string] -or $tool -cne $script:expectedTool) {
        throw 'Multiple PATH matches became a concatenated executable path.'
    }
    Invoke-FixtureProcess -FilePath $tool -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'exit 0') -TimeoutSeconds 10
}
Write-Output 'VPN acceptance SDK resolution and actual child-process regression passed.'

# Import the exact wrapper validator above; missing, false or truthy non-boolean
# connected-owner death evidence must fail even if the producer claims passed.
$summary = [ordered]@{
    schema = 'vex.windows-vpn-acceptance.v1'; passed = $true
    full_tunnel_checks_requested = $true; actual_public_internet_vpn_egress_verified = $false
}
$scmFlags = @('scm_private_pipe_authenticated', 'scm_bad_token_rejected', 'scm_raw_config_rejected',
    'scm_tampered_profile_rejected', 'scm_signed_connect_verified', 'scm_status_diagnostics_verified',
    'scm_crash_status_restored', 'scm_disconnect_verified', 'scm_disconnect_survived_restart',
    'scm_stop_cleanup_verified', 'scm_graceful_stop_survived_restart',
    'scm_authorization_expiry_cleanup_verified', 'scm_fixture_service_removed')
$fullFlags = @('full_tunnel_dns_verified', 'full_tunnel_https_verified',
    'full_control_plane_https_bypass_verified', 'full_physical_tcp_prebaseline_verified',
    'full_physical_tcp_blocked', 'full_physical_tcp_restored', 'full_vendor_demand_start_verified',
    'full_vendor_routes_verified', 'full_physical_route_retained_verified', 'full_anti_leak_enabled',
    'full_controller_death_watchdog_verified', 'full_owned_cleanup_verified')
$activeFlags = @('full_active_controller_connected_verified', 'full_active_controller_death_cleanup_verified',
    'full_active_controller_network_restored_verified', 'full_active_controller_lease_not_expired_verified')
foreach ($field in $scmFlags + $fullFlags + $activeFlags) { $summary[$field] = $true }
foreach ($field in @('full_physical_dns_supported', 'full_physical_dns_blocked', 'full_physical_dns_restored')) {
    $summary[$field] = $false
}
Assert-FixtureHarnessResult -Result ([pscustomobject]$summary) -FullTunnelChecks
foreach ($field in $scmFlags + $fullFlags + $activeFlags + @('passed')) {
    foreach ($invalid in @($false, 'true', 1, $null, 'missing')) {
        $candidate = $summary | ConvertTo-Json -Depth 4 | ConvertFrom-Json
        if ($invalid -is [string] -and $invalid -ceq 'missing') { $candidate.PSObject.Properties.Remove($field) }
        else { $candidate.$field = $invalid }
        $rejected = $false
        try { Assert-FixtureHarnessResult -Result $candidate -FullTunnelChecks } catch { $rejected = $true }
        if (-not $rejected) { throw "Fixture accepted missing or non-true mandatory evidence: $field" }
    }
}
foreach ($field in @('full_physical_dns_supported', 'full_physical_dns_blocked', 'full_physical_dns_restored')) {
    $summary[$field] = $true
}
Assert-FixtureHarnessResult -Result ([pscustomobject]$summary) -FullTunnelChecks
$summary.full_physical_dns_restored = $false
$rejected = $false
try { Assert-FixtureHarnessResult -Result ([pscustomobject]$summary) -FullTunnelChecks } catch { $rejected = $true }
if (-not $rejected) { throw 'Fixture accepted unconfirmed supported physical DNS restoration.' }
$summary.full_physical_dns_restored = $true
$summary.full_tunnel_checks_requested = $false
$rejected = $false
try { Assert-FixtureHarnessResult -Result ([pscustomobject]$summary) -FullTunnelChecks } catch { $rejected = $true }
if (-not $rejected) { throw 'Fixture accepted a narrow-route result as FULL qualification.' }
foreach ($field in $fullFlags + $activeFlags + @('full_physical_dns_supported', 'full_physical_dns_blocked', 'full_physical_dns_restored')) {
    $summary.Remove($field)
}
Assert-FixtureHarnessResult -Result ([pscustomobject]$summary)
Write-Output 'VPN acceptance source-bound mandatory SCM/FULL/active-controller summary regressions passed.'

function Get-NetAdapter {
    param([switch]$Physical)
    [pscustomobject]@{Status='Up';InterfaceIndex=10}
    [pscustomobject]@{Status='Up';InterfaceIndex=20}
}
$script:fixtureNativeRoutes = @([pscustomobject]@{InterfaceIndex=10;NextHop='0.0.0.0';RouteMetric=256})
function Get-NetRoute {
    param($AddressFamily,$DestinationPrefix,$PolicyStore)
    if ($DestinationPrefix -eq '0.0.0.0/0') {
        # A tunnel/virtual default must not be selected. Physical metrics count
        # both route and interface cost, just like the qualified vendor monitor.
        [pscustomobject]@{InterfaceIndex=99;NextHop='10.0.0.1';RouteMetric=0}
        [pscustomobject]@{InterfaceIndex=20;NextHop='192.168.1.1';RouteMetric=1}
        [pscustomobject]@{InterfaceIndex=10;NextHop='192.168.2.1';RouteMetric=30}
    } else { $script:fixtureNativeRoutes }
}
function Get-NetIPInterface {
    param($AddressFamily,$InterfaceIndex)
    [pscustomobject]@{InterfaceMetric=$(if($InterfaceIndex -eq 10){5}else{100})}
}
$script:fixtureAddressPresent = $true
function Get-NetIPAddress {
    param($AddressFamily,$InterfaceIndex,$PolicyStore)
    if ($InterfaceIndex -ne 10) { throw 'Fixture selected the wrong physical interface.' }
    if ($script:fixtureAddressPresent) {
        [pscustomobject]@{IPAddress='192.168.2.2';AddressState='Preferred';SkipAsSource=$false}
        [pscustomobject]@{IPAddress='10.253.253.1';AddressState='Preferred';SkipAsSource=$false}
        [pscustomobject]@{IPAddress='127.0.0.1';AddressState='Preferred';SkipAsSource=$false}
    }
}
$hostAddress = Resolve-FixtureHostAddress
if ($hostAddress -cne '192.168.2.2') { throw 'Fixture did not select an existing physical source address.' }
$nativeBefore = Read-FixtureEndpointRoutes -Address $hostAddress
if ($nativeBefore -cne (Read-FixtureEndpointRoutes -Address $hostAddress)) { throw 'Native endpoint route baseline is unstable.' }
$script:fixtureNativeRoutes += [pscustomobject]@{InterfaceIndex=10;NextHop='192.168.2.1';RouteMetric=1}
if ($nativeBefore -ceq (Read-FixtureEndpointRoutes -Address $hostAddress)) { throw 'Native endpoint route mutation escaped cleanup validation.' }
$script:fixtureAddressPresent = $false
$rejected = $false
try { Resolve-FixtureHostAddress | Out-Null } catch { $rejected = $true }
if (-not $rejected) { throw 'Fixture accepted an interface without a currently assigned source address.' }
Write-Output 'VPN fixture native physical endpoint selection and unchanged-route regressions passed.'

# Exercise the exact C# DNS query/retransmission/parser against an ephemeral
# loopback UDP server. Substitute only socket binding and destination port;
# this portable test never creates a tunnel or touches any host network state.
$probeSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../scripts/Vex.Windows.VpnAcceptance/Program.cs'))
$start = $probeSource.IndexOf('    private static async Task<int> ProbeDnsAsync(')
$end = $probeSource.IndexOf('    private static async Task ProbeHttpsAsync(', $start)
if ($start -lt 0 -or $end -le $start) { throw 'Fixture DNS production methods missing.' }
$probeMethods = $probeSource.Substring($start, $end - $start).Replace('), 53)', '), _port)')
$regression = @'
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
public static class VexFixtureDnsRegression
{
    private const string ServerIp = "127.0.0.1";
    private const string Host = "fixture.vex.invalid";
    private static int _port;
    private static Socket TunnelSocket(SocketType type, ProtocolType protocol, int index)
    {
        var socket = new Socket(AddressFamily.InterNetwork, type, protocol);
        socket.Bind(new IPEndPoint(IPAddress.Loopback, 0));
        return socket;
    }
    private static void Require(bool condition, string code)
    { if (!condition) { throw new InvalidOperationException(code); } }
    public static void Run() { RunAsync().GetAwaiter().GetResult(); }
    private static async Task RunAsync()
    {
        await AnswerAsync(dropFirst: true, invalidAddress: false);
        await AnswerAsync(dropFirst: false, invalidAddress: true);
        using var server = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        server.Bind(new IPEndPoint(IPAddress.Loopback, 0));
        _port = ((IPEndPoint)server.LocalEndPoint).Port;
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(250));
        var started = DateTime.UtcNow;
        try { await ProbeDnsAsync(1, cancellation.Token); throw new Exception("Missing DNS cancellation"); }
        catch (OperationCanceledException) { }
        Require(DateTime.UtcNow - started < TimeSpan.FromSeconds(3), "DNS cancellation exceeded deadline");
    }
    private static async Task AnswerAsync(bool dropFirst, bool invalidAddress)
    {
        using var server = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        server.Bind(new IPEndPoint(IPAddress.Loopback, 0));
        _port = ((IPEndPoint)server.LocalEndPoint).Port;
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var answer = Task.Run(async () =>
        {
            var packet = new byte[1232];
            var received = await server.ReceiveFromAsync(packet, SocketFlags.None, new IPEndPoint(IPAddress.Any, 0), deadline.Token);
            if (dropFirst)
            {
                received = await server.ReceiveFromAsync(packet, SocketFlags.None, new IPEndPoint(IPAddress.Any, 0), deadline.Token);
            }
            var response = new byte[received.ReceivedBytes + 16];
            Array.Copy(packet, response, received.ReceivedBytes);
            response[2] = 0x81; response[3] = 0x80; response[7] = 1;
            byte[] resource = [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 0, 0, 4, 127, 0, 0, (byte)(invalidAddress ? 9 : 1)];
            Array.Copy(resource, 0, response, received.ReceivedBytes, resource.Length);
            await server.SendToAsync(response, SocketFlags.None, received.RemoteEndPoint, deadline.Token);
        });
        try
        {
            var attempts = await ProbeDnsAsync(1, deadline.Token);
            Require(!invalidAddress, "Incorrect DNS answer accepted");
            Require(!dropFirst || attempts >= 2, "Lost DNS request was not retransmitted");
        }
        catch (InvalidOperationException exception) when (invalidAddress && exception.Message == "fixture_dns_answer_invalid") { }
        await answer;
    }
'@
Add-Type -TypeDefinition ($regression + $probeMethods + '}')
[VexFixtureDnsRegression]::Run()
Write-Output 'VPN acceptance actual DNS dropped-datagram retry, strict answer and cancellation regressions passed.'

# Failure diagnostics reuse the validator's check names and must never echo an
# arbitrary result field, string, path, key, or exception body.
$wrapper = [pscustomobject]@{passed=$false;stage='runtime-acceptance';cleanup_stage='completed';fixture_private_material_removed=$true}
$harness = [ordered]@{passed=$false;stage='tunnel-dns';failure_category='tls';private_key='QSECRET';endpoint='QSECRET';error='QSECRET'}
foreach ($field in @(Get-FixtureHarnessCheckNames -FullTunnelChecks)) { $harness[$field]=$true }
$harness.scm_disconnect_verified=$false
$harness.scm_signed_connect_verified='true'
$harness.Remove('full_tunnel_dns_verified')
$log = Get-FixtureAcceptanceLogSummary -WrapperResult $wrapper -HarnessResult ([pscustomobject]$harness) -FullTunnelChecks
if ($log.Contains('QSECRET') -or $log.Contains('private_key') -or $log.Contains('"endpoint":')) { throw 'Acceptance diagnostics leaked arbitrary source data.' }
$parsed = $log | ConvertFrom-Json
if ($parsed.stage -cne 'runtime-acceptance' -or $parsed.harness_stage -cne 'tunnel-dns' -or $parsed.harness_passed -or $parsed.passed -or $parsed.failure_category -cne 'tls') { throw 'Acceptance diagnostic stage/verdict changed.' }
$expected = @('full_tunnel_dns_verified','scm_disconnect_verified','scm_signed_connect_verified') | Sort-Object
if (($parsed.failed_or_missing_checks | Sort-Object) -join ',' -cne ($expected -join ',')) { throw 'Acceptance diagnostic lost missing/false/non-boolean evidence.' }
$harness.stage='QSECRET'
$harness.failure_category='QSECRET'
$wrapper.stage='QSECRET'
$log = Get-FixtureAcceptanceLogSummary -WrapperResult $wrapper -HarnessResult ([pscustomobject]$harness)
if ($log.Contains('QSECRET')) { throw 'Unknown diagnostic stage escaped the allowlist.' }
$parsed = (Get-FixtureAcceptanceLogSummary -WrapperResult $wrapper -HarnessResult $null) | ConvertFrom-Json
if ($parsed.harness_available -or $parsed.harness_passed -or $parsed.failed_or_missing_checks.Count -ne 0) { throw 'Missing harness report invented diagnostic evidence.' }
Write-Output 'VPN acceptance allowlisted failure diagnostics regression passed.'

foreach ($stage in @('full-control-https-baseline', 'full-physical-dns-baseline')) {
    $harness.stage = $stage
    $harness.failure_category = 'connection'
    $parsed = (Get-FixtureAcceptanceLogSummary -WrapperResult $wrapper -HarnessResult ([pscustomobject]$harness)) | ConvertFrom-Json
    if ($parsed.harness_stage -cne $stage -or $parsed.failure_category -cne 'connection') { throw 'Physical prebaseline diagnostics lost a fixed stage or category.' }
}

foreach ($value in @($true, $false, $null, 'QSECRET', 1)) {
    foreach ($field in @('full_control_probe_parent_cancelled','full_control_probe_budget_expired','full_control_probe_inner_timeout', 'full_control_probe_tcp_connected')) { $harness[$field]=$value }
    $log=Get-FixtureAcceptanceLogSummary -WrapperResult $wrapper -HarnessResult ([pscustomobject]$harness)
    if ($log.Contains('QSECRET')) { throw 'Control probe cancellation diagnostic leaked non-boolean data.' }
    $parsed=$log | ConvertFrom-Json
    $expected=if($value -is [bool]){$value}else{$null}
    foreach ($field in @('full_control_probe_parent_cancelled','full_control_probe_budget_expired','full_control_probe_inner_timeout', 'full_control_probe_tcp_connected')) {
        if ($parsed.$field -cne $expected) { throw 'Control probe cancellation diagnostic changed false or missing evidence.' }
    }
}
