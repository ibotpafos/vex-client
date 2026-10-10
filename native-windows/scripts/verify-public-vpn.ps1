#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Baseline', 'Connected', 'Restored')][string]$Phase,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][string[]]$ExpectedVpnExitIpv4,
    [string]$BaselinePath,
    [string]$ConnectedPath,
    [ValidateRange(30, 1800)][int]$MaximumBaselineAgeSeconds = 600
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Observes an already installed, manually authenticated/connected VEX client.
# This script never connects/disconnects, changes routes/firewall/DNS, installs
# anything, or reads account, authorization, configuration or private key files.
# Its local JSON evidence is not a signed attestation or an anti-replay protocol.

function Assert-PublicVpnWindows {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'public_vpn_requires_windows'
    }
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        throw 'public_vpn_requires_native_64bit_powershell'
    }
}

function Assert-PublicVpnAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'public_vpn_requires_elevated_administrator'
        }
    }
    finally { $identity.Dispose() }
}

function ConvertTo-PublicVpnIpv4 {
    param([string]$Value)
    if ($Value -notmatch '^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$') {
        throw 'public_vpn_invalid_ipv4'
    }
    $octets = @($Value.Split('.') | ForEach-Object { [int]$_ })
    if (@($octets | Where-Object { $_ -gt 255 }).Count -ne 0) { throw 'public_vpn_invalid_ipv4' }
    # Public unicast only. Exclude private, shared, loopback, link-local,
    # protocol/documentation/benchmark, multicast and reserved address blocks.
    if ($octets[0] -eq 0 -or $octets[0] -eq 10 -or $octets[0] -eq 127 -or $octets[0] -ge 224 -or
        ($octets[0] -eq 100 -and $octets[1] -ge 64 -and $octets[1] -le 127) -or
        ($octets[0] -eq 169 -and $octets[1] -eq 254) -or
        ($octets[0] -eq 172 -and $octets[1] -ge 16 -and $octets[1] -le 31) -or
        ($octets[0] -eq 192 -and $octets[1] -eq 168) -or
        ($octets[0] -eq 192 -and $octets[1] -eq 0 -and $octets[2] -in @(0, 2)) -or
        ($octets[0] -eq 192 -and $octets[1] -eq 88 -and $octets[2] -eq 99) -or
        ($octets[0] -eq 198 -and $octets[1] -in @(18, 19)) -or
        ($octets[0] -eq 198 -and $octets[1] -eq 51 -and $octets[2] -eq 100) -or
        ($octets[0] -eq 203 -and $octets[1] -eq 0 -and $octets[2] -eq 113)) {
        throw 'public_vpn_nonpublic_ipv4'
    }
    return $Value
}

function Get-PublicVpnHash {
    param([byte[]]$Bytes)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Get-PublicVpnTextHash {
    param([string]$Value)
    return Get-PublicVpnHash ([Text.Encoding]::UTF8.GetBytes($Value))
}

function Get-PublicVpnExpectedSetHash {
    param([string[]]$Values)
    if ($null -eq $Values -or $Values.Count -lt 1 -or $Values.Count -gt 16) { throw 'public_vpn_expected_exit_required' }
    $canonical = @($Values | ForEach-Object { ConvertTo-PublicVpnIpv4 $_ } | Sort-Object -Unique)
    return Get-PublicVpnTextHash ($canonical -join ',')
}

function Get-PublicVpnMachineHash {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $base.OpenSubKey('SOFTWARE\Microsoft\Cryptography', $false)
        if ($null -eq $key) { throw 'public_vpn_machine_identity_unavailable' }
        try { $value = [string]$key.GetValue('MachineGuid', $null) } finally { $key.Dispose() }
        $guid = [Guid]::Empty
        if (-not [Guid]::TryParse($value, [ref]$guid) -or $guid -eq [Guid]::Empty) {
            throw 'public_vpn_machine_identity_invalid'
        }
        return Get-PublicVpnTextHash ('vex.windows.public-vpn.machine.v1:' + $guid.ToString('N'))
    }
    finally { $base.Dispose() }
}

function Resolve-PublicVpnSystemCurl {
    $curl = Join-Path ([Environment]::GetFolderPath('System')) 'curl.exe'
    if (-not (Test-Path -LiteralPath $curl -PathType Leaf)) { throw 'public_vpn_system_curl_unavailable' }
    return $curl
}

function Initialize-PublicVpnNativeProbe {
    if ($null -ne ('VexPublicVpnBoundedProcess' -as [type])) { return }
    # Both pipes are drained in bounded C# readers, not unbounded ReadToEnd or
    # PowerShell callbacks that require a runspace on a worker thread.
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
public sealed class VexPublicVpnProcessResult
{
    public int ExitCode;
    public string Output;
    public int ErrorLength;
    public bool TimedOut;
    public bool OutputExceeded;
}
public static class VexPublicVpnBoundedProcess
{
    private sealed class Capture
    {
        public readonly StringBuilder Text = new StringBuilder();
        public int Count;
        public int Total;
        public int Exceeded;
    }
    private static void Read(StreamReader reader, Capture capture, Capture combined, int limit)
    {
        char[] buffer = new char[128];
        int count;
        while ((count = reader.Read(buffer, 0, buffer.Length)) > 0)
        {
            if (Interlocked.Add(ref combined.Total, count) > limit)
            { Interlocked.Exchange(ref combined.Exceeded, 1); return; }
            capture.Text.Append(buffer, 0, count);
            capture.Count += count;
        }
    }
    public static VexPublicVpnProcessResult Run(string executable, string arguments, int timeoutMilliseconds, int limit)
    {
        if (timeoutMilliseconds < 1 || timeoutMilliseconds > 30000 || limit < 32 || limit > 4096)
            throw new ArgumentException("public_vpn_process_budget_invalid");
        var start = new ProcessStartInfo(executable, arguments);
        start.UseShellExecute = false; start.CreateNoWindow = true;
        start.RedirectStandardOutput = true; start.RedirectStandardError = true;
        // Empty explicit proxy options also override inherited proxy settings.
        foreach (string key in new string[] { "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy" })
            start.EnvironmentVariables.Remove(key);
        using (var process = new Process())
        {
            process.StartInfo = start;
            if (!process.Start()) throw new IOException("public_vpn_process_start_failed");
            var output = new Capture(); var errors = new Capture(); var combined = new Capture();
            Task stdout = Task.Run(delegate { Read(process.StandardOutput, output, combined, limit); });
            Task stderr = Task.Run(delegate { Read(process.StandardError, errors, combined, limit); });
            var timer = Stopwatch.StartNew(); bool timedOut = false;
            while (!process.WaitForExit(20))
            {
                if (Volatile.Read(ref combined.Exceeded) != 0 || timer.ElapsedMilliseconds >= timeoutMilliseconds)
                {
                    timedOut = timer.ElapsedMilliseconds >= timeoutMilliseconds;
                    try { process.Kill(); } catch (InvalidOperationException) { }
                    if (!process.WaitForExit(2000)) throw new IOException("public_vpn_process_kill_failed");
                    break;
                }
            }
            if (!Task.WaitAll(new Task[] { stdout, stderr }, 2000)) throw new IOException("public_vpn_process_drain_failed");
            return new VexPublicVpnProcessResult { ExitCode = process.ExitCode, Output = output.Text.ToString(),
                ErrorLength = errors.Count, TimedOut = timedOut, OutputExceeded = combined.Exceeded != 0 };
        }
    }
}
'@
}

function Get-PublicVpnCurlArguments {
    param([string]$HostName, [string]$Address)
    if ($HostName -notin @('api.ipify.org', 'checkip.amazonaws.com')) { throw 'public_vpn_observer_not_allowed' }
    $null = ConvertTo-PublicVpnIpv4 $Address
    # --disable MUST be the first option: a user's .curlrc must never replace
    # proxy/TLS/redirect/output limits or execute a different request.
    return '--disable --ipv4 --silent --show-error --fail --proto "=https" --connect-timeout 5 --max-time 12 --max-redirs 0 --proxy "" --noproxy "*" --max-filesize 64 --resolve "' +
        $HostName + ':443:' + $Address + '" --write-out "\nVEX_META:%{http_code}|%{remote_ip}|%{num_redirects}|%{ssl_verify_result}" "https://' + $HostName + '/"'
}

function ConvertFrom-PublicVpnCurlResult {
    param($Result, [string]$ExpectedRemoteAddress)
    $null = ConvertTo-PublicVpnIpv4 $ExpectedRemoteAddress
    if ($Result.TimedOut) { throw 'public_vpn_probe_timeout' }
    if ($Result.OutputExceeded -or $Result.Output.Length -gt 256 -or $Result.ErrorLength -gt 256) {
        throw 'public_vpn_probe_output_limit'
    }
    if ($Result.ExitCode -ne 0) { throw 'public_vpn_probe_http_tls_or_network_failure' }
    if ($Result.Output -notmatch '\A(?<body>[0-9.]{7,15})(?:\r?\n)?\nVEX_META:(?<status>[0-9]{3})\|(?<remote>[0-9.]{7,15})\|(?<redirects>[0-9]+)\|(?<tls>[0-9]+)\z') {
        throw 'public_vpn_probe_response_invalid'
    }
    $metadata = @{}
    foreach ($name in @('body', 'status', 'remote', 'redirects', 'tls')) { $metadata[$name] = $Matches[$name] }
    $ip = ConvertTo-PublicVpnIpv4 $metadata.body
    if ($metadata.status -cne '200' -or $metadata.redirects -cne '0' -or $metadata.tls -cne '0' -or
        $metadata.remote -cne $ExpectedRemoteAddress -or $Result.ErrorLength -ne 0) {
        throw 'public_vpn_probe_http_tls_or_route_invalid'
    }
    return $ip
}

function Resolve-PublicVpnObserver {
    param([string]$HostName)
    if ($HostName -notin @('api.ipify.org', 'checkip.amazonaws.com')) { throw 'public_vpn_observer_not_allowed' }
    $pending = [Net.Dns]::GetHostAddressesAsync($HostName)
    if (-not $pending.Wait(5000)) { throw 'public_vpn_observer_dns_timeout' }
    $addresses = @($pending.Result | Where-Object AddressFamily -eq ([Net.Sockets.AddressFamily]::InterNetwork) |
        ForEach-Object { ConvertTo-PublicVpnIpv4 $_.ToString() } | Sort-Object -Unique)
    if ($addresses.Count -eq 0) { throw 'public_vpn_observer_ipv4_missing' }
    return $addresses[0]
}

function Get-PublicVpnNetworkState {
    param([string]$PhaseName)
    $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop)
    $vex = @($adapters | Where-Object Name -ieq 'vex')
    if ($PhaseName -eq 'Connected') {
        if ($vex.Count -ne 1 -or $vex[0].Status -cne 'Up' -or $vex[0].InterfaceDescription -notmatch '(?i)amnezia|wintun') {
            throw 'public_vpn_vex_adapter_not_up'
        }
        Assert-PublicVpnOwnedVendor
        return [pscustomobject]@{ VexIndex = [int]$vex[0].InterfaceIndex; PhysicalIndexes = @(); Phase = $PhaseName }
    }
    if (@($vex | Where-Object Status -ne 'Disconnected').Count -gt 0) { throw 'public_vpn_vex_adapter_not_disconnected' }
    $vendor = @(Get-CimInstance -ClassName Win32_Service -OperationTimeoutSec 5 -Filter 'Name=''AmneziaWGTunnel$vex''' -ErrorAction Stop)
    if (@($vendor | Where-Object State -ne 'Stopped').Count -gt 0) { throw 'public_vpn_vendor_not_stopped' }
    $physical = @($adapters | Where-Object { $_.Status -ceq 'Up' -and $_.HardwareInterface } |
        ForEach-Object { [int]$_.InterfaceIndex })
    if ($physical.Count -eq 0) { throw 'public_vpn_physical_interface_missing' }
    return [pscustomobject]@{ VexIndex = 0; PhysicalIndexes = $physical; Phase = $PhaseName }
}

function Assert-PublicVpnOwnedVendor {
    $controller = @(Get-CimInstance -ClassName Win32_Service -OperationTimeoutSec 5 -Filter 'Name=''VEX VPN Service''' -ErrorAction Stop)
    $vendor = @(Get-CimInstance -ClassName Win32_Service -OperationTimeoutSec 5 -Filter 'Name=''AmneziaWGTunnel$vex''' -ErrorAction Stop)
    if ($controller.Count -ne 1 -or $vendor.Count -ne 1 -or $controller[0].State -cne 'Running' -or
        $vendor[0].State -cne 'Running' -or $controller[0].StartName -ine 'LocalSystem' -or
        $vendor[0].StartName -ine 'LocalSystem' -or $vendor[0].StartMode -cne 'Manual' -or
        $controller[0].ServiceType -cne 'Own Process' -or $vendor[0].ServiceType -cne 'Own Process' -or
        $controller[0].PathName -notmatch '^"(?<image>[^"\r\n]+\\Vex\.Windows\.Service\.exe)"$') {
        throw 'public_vpn_installed_service_identity_invalid'
    }
    $controllerImage = $Matches.image
    $vendorImage = Join-Path ([IO.Path]::GetDirectoryName($controllerImage)) 'amneziawg.exe'
    $data = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'VEX\VPN'
    $config = Join-Path $data 'Private\vex.conf'
    if ($vendor[0].PathName -cne ('"' + $vendorImage + '" /tunnelservice "' + $config + '"')) {
        throw 'public_vpn_vendor_not_owned_by_vex'
    }
    foreach ($entry in @(@($controller[0], $controllerImage), @($vendor[0], $vendorImage))) {
        if ([int]$entry[0].ProcessId -le 0) { throw 'public_vpn_service_process_missing' }
        $process = @(Get-CimInstance -ClassName Win32_Process -OperationTimeoutSec 5 -Filter ('ProcessId=' + [int]$entry[0].ProcessId) -ErrorAction Stop)
        if ($process.Count -ne 1 -or $process[0].ExecutablePath -ine $entry[1]) { throw 'public_vpn_service_process_identity_invalid' }
    }
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $base.OpenSubKey('SOFTWARE\VEX\VPN', $false)
        if ($null -eq $key) { throw 'public_vpn_installed_service_pin_missing' }
        try { $controllerPin = [string]$key.GetValue('ServiceExecutableSha256', $null) } finally { $key.Dispose() }
    }
    finally { $base.Dispose() }
    # Hash pins only. NEVER open vex.conf, profiles, ipc-token.bin or account data.
    $vendorPinPath = Join-Path $data 'amneziawg-sha256'
    if ((Get-Item -LiteralPath $vendorPinPath -ErrorAction Stop).Length -gt 128) { throw 'public_vpn_vendor_pin_invalid' }
    $vendorPin = [IO.File]::ReadAllText($vendorPinPath).Trim()
    if ($controllerPin -notmatch '^[A-Fa-f0-9]{64}$' -or $vendorPin -notmatch '^[A-Fa-f0-9]{64}$' -or
        (Get-FileHash -LiteralPath $controllerImage -Algorithm SHA256).Hash -ine $controllerPin -or
        (Get-FileHash -LiteralPath $vendorImage -Algorithm SHA256).Hash -ine $vendorPin) {
        throw 'public_vpn_installed_runtime_hash_mismatch'
    }
}

function Get-PublicVpnRoute {
    param([string]$Address, $State)
    $null = ConvertTo-PublicVpnIpv4 $Address
    $values = @(Find-NetRoute -RemoteIPAddress $Address -ErrorAction Stop)
    $routes = @($values | Where-Object { $null -ne $_.PSObject.Properties['DestinationPrefix'] })
    $sources = @($values | Where-Object { $null -ne $_.PSObject.Properties['IPAddress'] })
    if ($routes.Count -ne 1 -or $sources.Count -ne 1 -or [int]$routes[0].InterfaceIndex -le 0 -or
        [int]$routes[0].InterfaceIndex -ne [int]$sources[0].InterfaceIndex) { throw 'public_vpn_best_route_invalid' }
    $index = [int]$routes[0].InterfaceIndex
    $source = [Net.IPAddress]::None
    if (-not [Net.IPAddress]::TryParse([string]$sources[0].IPAddress, [ref]$source) -or
        $source.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or [Net.IPAddress]::IsLoopback($source) -or
        $source.Equals([Net.IPAddress]::Any)) { throw 'public_vpn_route_source_invalid' }
    if (($State.Phase -eq 'Connected' -and $index -ne $State.VexIndex) -or
        ($State.Phase -ne 'Connected' -and $index -notin $State.PhysicalIndexes)) { throw 'public_vpn_observer_route_wrong_interface' }
    return [pscustomobject]@{ InterfaceIndex = $index; SourceHash = (Get-PublicVpnTextHash $source.ToString());
        Prefix = [string]$routes[0].DestinationPrefix; NextHopHash = (Get-PublicVpnTextHash ([string]$routes[0].NextHop)) }
}

function Invoke-PublicVpnObserver {
    param([string]$HostName, $State, [string]$CurlPath)
    $address = Resolve-PublicVpnObserver $HostName
    $before = Get-PublicVpnRoute $address $State
    $arguments = Get-PublicVpnCurlArguments $HostName $address
    $response = [VexPublicVpnBoundedProcess]::Run($CurlPath, $arguments, 15000, 512)
    $ip = ConvertFrom-PublicVpnCurlResult $response $address
    $after = Get-PublicVpnRoute $address $State
    if (($before | ConvertTo-Json -Compress) -cne ($after | ConvertTo-Json -Compress)) { throw 'public_vpn_route_changed_during_probe' }
    return [pscustomobject]@{ observer = $HostName; observed_at_utc = [DateTimeOffset]::UtcNow.ToString('O');
        public_ipv4_sha256 = (Get-PublicVpnTextHash $ip); remote_ipv4_sha256 = (Get-PublicVpnTextHash $address);
        interface_index = $after.InterfaceIndex; route_source_sha256 = $after.SourceHash;
        route_verified = $true; https_status = 200; tls_verified = $true; redirects = 0; proxy_disabled = $true;
        ipv4_only = $true; parsed_ipv4 = $ip }
}

function Assert-PublicVpnDocument {
    param($Document, [string]$ExpectedPhase, [string]$MachineHash, [string]$ExpectedSetHash, [DateTimeOffset]$Now,
        [int]$MaximumAgeSeconds)
    foreach ($name in @('schema', 'phase', 'run_id', 'observation_id', 'machine_sha256', 'expected_exit_set_sha256',
        'started_at_utc', 'completed_at_utc', 'observers', 'passed', 'public_ipv4_sha256', 'stage',
        'actual_public_internet_vpn_egress_verified', 'restored_baseline_egress_verified',
        'authenticated_application_verified', 'dns_leakage_verified', 'ipv6_verified',
        'failure_recovery_verified', 'signed_installed_ipc_verified', 'reboot_verified')) {
        if ($null -eq $Document.PSObject.Properties[$name]) { throw 'public_vpn_prior_evidence_incomplete' }
    }
    $run = [Guid]::Empty; $observation = [Guid]::Empty
    if ($Document.schema -cne 'vex.windows-public-vpn-verification.v1' -or $Document.phase -cne $ExpectedPhase -or
        $Document.passed -isnot [bool] -or -not $Document.passed -or $Document.stage -cne 'completed' -or
        -not [Guid]::TryParseExact([string]$Document.run_id, 'N', [ref]$run) -or $run -eq [Guid]::Empty -or
        -not [Guid]::TryParseExact([string]$Document.observation_id, 'N', [ref]$observation) -or $observation -eq [Guid]::Empty -or
        $Document.machine_sha256 -cne $MachineHash -or $Document.expected_exit_set_sha256 -cne $ExpectedSetHash -or
        $Document.public_ipv4_sha256 -notmatch '^[a-f0-9]{64}$') { throw 'public_vpn_prior_evidence_identity_invalid' }
    foreach ($name in @('authenticated_application_verified', 'dns_leakage_verified', 'ipv6_verified',
        'failure_recovery_verified', 'signed_installed_ipc_verified', 'reboot_verified', 'restored_baseline_egress_verified')) {
        if ($Document.$name -isnot [bool] -or $Document.$name) { throw 'public_vpn_prior_evidence_overclaims' }
    }
    if ($Document.actual_public_internet_vpn_egress_verified -isnot [bool] -or
        $Document.actual_public_internet_vpn_egress_verified -ne ($ExpectedPhase -eq 'Connected')) {
        throw 'public_vpn_prior_evidence_phase_claim_invalid'
    }
    $started = ConvertTo-PublicVpnTimestamp $Document.started_at_utc
    $completed = ConvertTo-PublicVpnTimestamp $Document.completed_at_utc
    if ($completed -lt $started -or ($completed - $started).TotalSeconds -gt 90 -or
        $started -gt $Now.AddSeconds(5) -or $completed -gt $Now.AddSeconds(5) -or
        ($Now - $completed).TotalSeconds -gt $MaximumAgeSeconds) { throw 'public_vpn_prior_evidence_stale_or_future' }
    $observers = @($Document.observers)
    if ($observers.Count -ne 2 -or @($observers | ForEach-Object { $_.observer } | Sort-Object -Unique).Count -ne 2) {
        throw 'public_vpn_prior_observers_invalid'
    }
    foreach ($observer in $observers) {
        foreach ($name in @('observer', 'observed_at_utc', 'public_ipv4_sha256', 'remote_ipv4_sha256', 'interface_index',
            'route_source_sha256', 'route_verified', 'https_status', 'tls_verified', 'redirects', 'proxy_disabled', 'ipv4_only')) {
            if ($null -eq $observer.PSObject.Properties[$name]) { throw 'public_vpn_prior_observers_incomplete' }
        }
        $observed = ConvertTo-PublicVpnTimestamp $observer.observed_at_utc
        if ($observer.observer -notin @('api.ipify.org', 'checkip.amazonaws.com') -or $observed -lt $started -or
            $observed -gt $completed -or $observer.public_ipv4_sha256 -cne $Document.public_ipv4_sha256 -or
            $observer.remote_ipv4_sha256 -notmatch '^[a-f0-9]{64}$' -or $observer.route_source_sha256 -notmatch '^[a-f0-9]{64}$' -or
            ($observer.interface_index -isnot [int] -and $observer.interface_index -isnot [long]) -or
            $observer.interface_index -le 0 -or
            ($observer.https_status -isnot [int] -and $observer.https_status -isnot [long]) -or
            ($observer.redirects -isnot [int] -and $observer.redirects -isnot [long]) -or
            $observer.https_status -ne 200 -or $observer.redirects -ne 0) {
            throw 'public_vpn_prior_observers_invalid'
        }
        foreach ($name in @('route_verified', 'tls_verified', 'proxy_disabled', 'ipv4_only')) {
            if ($observer.$name -isnot [bool] -or -not $observer.$name) { throw 'public_vpn_prior_observers_invalid' }
        }
    }
    return $completed
}

function ConvertTo-PublicVpnTimestamp {
    param($Value)
    $date = [DateTimeOffset]::MinValue
    if ($Value -isnot [string] -or $Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}\+00:00$' -or
        -not [DateTimeOffset]::TryParseExact($Value, 'O', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$date) -or $date.Offset -ne [TimeSpan]::Zero) {
        throw 'public_vpn_prior_timestamp_invalid'
    }
    return $date
}

function Read-PublicVpnEvidence {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'public_vpn_prior_evidence_required' }
    $stream = [IO.File]::Open([IO.Path]::GetFullPath($Path), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -lt 1 -or $stream.Length -gt 16384) { throw 'public_vpn_prior_evidence_size_invalid' }
        $bytes = New-Object byte[] ([int]$stream.Length)
        $count = $stream.Read($bytes, 0, $bytes.Length)
        if ($count -ne $bytes.Length -or $stream.ReadByte() -ne -1) { throw 'public_vpn_prior_evidence_truncated' }
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $jsonOptions = @{}
        # PowerShell 7.5+ otherwise turns ISO strings into DateTime objects;
        # 5.1 retains strings. Require identical exact timestamp validation.
        if ((Get-Command ConvertFrom-Json -CommandType Cmdlet).Parameters.ContainsKey('DateKind')) {
            $jsonOptions['DateKind'] = 'String'
        }
        $document = $text | ConvertFrom-Json @jsonOptions
        return [pscustomobject]@{ Document = $document; Sha256 = (Get-PublicVpnHash $bytes) }
    }
    finally { $stream.Dispose() }
}

function Test-PublicVpnPhaseResults {
    param([string]$PhaseName, $Observers, [string[]]$ExpectedExits, [string]$BaselineIpHash)
    if (@($Observers).Count -ne 2 -or $Observers[0].parsed_ipv4 -cne $Observers[1].parsed_ipv4) {
        throw 'public_vpn_independent_observers_disagree'
    }
    $ip = ConvertTo-PublicVpnIpv4 $Observers[0].parsed_ipv4
    $hash = Get-PublicVpnTextHash $ip
    if ($PhaseName -eq 'Baseline' -and $ip -in $ExpectedExits) { throw 'public_vpn_baseline_already_uses_expected_exit' }
    if ($PhaseName -eq 'Connected' -and ($ip -notin $ExpectedExits -or $hash -ceq $BaselineIpHash)) {
        throw 'public_vpn_exit_not_expected_or_not_changed'
    }
    if ($PhaseName -eq 'Restored' -and $hash -cne $BaselineIpHash) { throw 'public_vpn_baseline_not_restored' }
    return $hash
}

# Fail on non-Windows BEFORE DNS, curl, machine identity or result creation.
Assert-PublicVpnWindows
Assert-PublicVpnAdministrator
$expectedHash = Get-PublicVpnExpectedSetHash $ExpectedVpnExitIpv4
$machineHash = Get-PublicVpnMachineHash
$baseline = $null; $connected = $null
$now = [DateTimeOffset]::UtcNow
if ($Phase -eq 'Baseline') {
    if (-not [string]::IsNullOrEmpty($BaselinePath) -or -not [string]::IsNullOrEmpty($ConnectedPath)) {
        throw 'public_vpn_baseline_must_not_reference_prior_evidence'
    }
} else {
    $baseline = Read-PublicVpnEvidence $BaselinePath
    $null = Assert-PublicVpnDocument $baseline.Document 'Baseline' $machineHash $expectedHash $now $MaximumBaselineAgeSeconds
    if ($baseline.Document.public_ipv4_sha256 -in @($ExpectedVpnExitIpv4 | ForEach-Object { Get-PublicVpnTextHash $_ })) {
        throw 'public_vpn_baseline_already_uses_expected_exit'
    }
    if ($Phase -eq 'Restored') {
        $connected = Read-PublicVpnEvidence $ConnectedPath
        $null = Assert-PublicVpnDocument $connected.Document 'Connected' $machineHash $expectedHash $now $MaximumBaselineAgeSeconds
        if ($connected.Document.run_id -cne $baseline.Document.run_id -or
            $connected.Document.observation_id -ceq $baseline.Document.observation_id -or
            $null -eq $connected.Document.PSObject.Properties['baseline_sha256'] -or
            $connected.Document.baseline_sha256 -cne $baseline.Sha256 -or
            (ConvertTo-PublicVpnTimestamp $connected.Document.started_at_utc) -lt (ConvertTo-PublicVpnTimestamp $baseline.Document.completed_at_utc) -or
            $connected.Document.public_ipv4_sha256 -ceq $baseline.Document.public_ipv4_sha256 -or
            $connected.Document.public_ipv4_sha256 -notin @($ExpectedVpnExitIpv4 | ForEach-Object { Get-PublicVpnTextHash $_ })) {
            throw 'public_vpn_prior_phase_chain_invalid'
        }
    } elseif (-not [string]::IsNullOrEmpty($ConnectedPath)) { throw 'public_vpn_connected_must_not_reference_connected_evidence' }
}
$curl = Resolve-PublicVpnSystemCurl
Initialize-PublicVpnNativeProbe
$resultPathFull = [IO.Path]::GetFullPath($ResultPath)
# CreateNew is also the final write handle: no existence-check/overwrite race.
$output = [IO.File]::Open($resultPathFull, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
$result = [ordered]@{
    schema = 'vex.windows-public-vpn-verification.v1'; phase = $Phase
    run_id = $(if ($null -eq $baseline) { [Guid]::NewGuid().ToString('N') } else { $baseline.Document.run_id })
    observation_id = [Guid]::NewGuid().ToString('N'); machine_sha256 = $machineHash; expected_exit_set_sha256 = $expectedHash
    started_at_utc = [DateTimeOffset]::UtcNow.ToString('O'); completed_at_utc = $null
    baseline_sha256 = $(if ($null -eq $baseline) { $null } else { $baseline.Sha256 })
    connected_sha256 = $(if ($null -eq $connected) { $null } else { $connected.Sha256 })
    public_ipv4_sha256 = $null; observers = @(); stage = 'network-preflight'; passed = $false; failure_code = $null
    actual_public_internet_vpn_egress_verified = $false; restored_baseline_egress_verified = $false
    authenticated_application_verified = $false; dns_leakage_verified = $false; ipv6_verified = $false
    failure_recovery_verified = $false; signed_installed_ipc_verified = $false; reboot_verified = $false
}
$failure = $null
try {
    $state = Get-PublicVpnNetworkState $Phase
    $observers = @()
    foreach ($hostName in @('api.ipify.org', 'checkip.amazonaws.com')) {
        $result.stage = 'observer-' + $hostName
        $observers += Invoke-PublicVpnObserver $hostName $state $curl
    }
    $result.stage = 'public-exit-comparison'
    $baselineIpHash = $(if ($null -eq $baseline) { $null } else { $baseline.Document.public_ipv4_sha256 })
    $result.public_ipv4_sha256 = Test-PublicVpnPhaseResults $Phase $observers $ExpectedVpnExitIpv4 $baselineIpHash
    # Recheck service/adapter ownership after both observations as well.
    if ($null -ne $baseline) {
        $null = Assert-PublicVpnDocument $baseline.Document 'Baseline' $machineHash $expectedHash ([DateTimeOffset]::UtcNow) $MaximumBaselineAgeSeconds
    }
    $finalState = Get-PublicVpnNetworkState $Phase
    if ($Phase -eq 'Connected' -and $finalState.VexIndex -ne $state.VexIndex) { throw 'public_vpn_adapter_changed_during_probe' }
    $result.observers = @($observers | Select-Object * -ExcludeProperty parsed_ipv4)
    $result.actual_public_internet_vpn_egress_verified = $Phase -eq 'Connected'
    $result.restored_baseline_egress_verified = $Phase -eq 'Restored'
    if (([DateTimeOffset]::UtcNow - (ConvertTo-PublicVpnTimestamp $result.started_at_utc)).TotalSeconds -gt 90) {
        throw 'public_vpn_observation_budget_exceeded'
    }
    $result.stage = 'completed'; $result.passed = $true
} catch {
    $failure = $_
    $code = [string]$_.Exception.Message
    $result.failure_code = $(if ($code -match '^public_vpn_[a-z0-9_]+$') { $code } else { 'public_vpn_observation_failed' })
} finally {
    $result.completed_at_utc = [DateTimeOffset]::UtcNow.ToString('O')
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($result | ConvertTo-Json -Depth 6))
    try { $output.Write($bytes, 0, $bytes.Length); $output.Flush() } finally { $output.Dispose() }
}
if ($null -ne $failure) { throw $result.failure_code }
Write-Output ('Public VPN {0} observation passed; evidence: {1}' -f $Phase, $resultPathFull)
