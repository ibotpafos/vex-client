# Read-only probes for the explicitly disposable production acceptance host.
# Requests follow normal OS routing: never bind curl to the physical adapter.

function Resolve-WindowsRussianDirectObserver {
    $pending = [Net.Dns]::GetHostAddressesAsync('yandex.ru')
    if (-not $pending.Wait(5000)) { throw 'russian_direct_observer_dns_timeout' }
    $addresses = @($pending.Result | Where-Object AddressFamily -eq ([Net.Sockets.AddressFamily]::InterNetwork) |
        ForEach-Object { ConvertTo-PublicVpnIpv4 $_.ToString() } | Sort-Object -Unique)
    if ($addresses.Count -lt 1) { throw 'russian_direct_observer_ipv4_missing' }
    return $addresses[0]
}

function Test-WindowsRussianDirectSocket {
    param($Socket, [int]$ExpectedProcessId, [string]$RemoteAddress, [int]$PhysicalIndex, [int]$VexIndex, [object[]]$LocalAddresses)
    if ($ExpectedProcessId -le 0 -or $PhysicalIndex -le 0 -or $VexIndex -le 0 -or $PhysicalIndex -eq $VexIndex -or
        [int]$Socket.OwningProcess -ne $ExpectedProcessId -or $Socket.RemoteAddress -cne $RemoteAddress -or
        [int]$Socket.RemotePort -ne 443 -or [int]$Socket.State -ne 5) { return $false }
    $local = @($LocalAddresses | Where-Object { $_.IPAddress -ceq $Socket.LocalAddress -and [int]$_.InterfaceIndex -eq $PhysicalIndex })
    return $local.Count -eq 1
}

function Invoke-WindowsRussianDirectProbe {
    param([bool]$DisposableRunner, [string]$RemoteAddress, [string]$BaselinePath, [string]$ConnectedPath, [string]$ResultPath)
    Assert-AcceptanceRunner $DisposableRunner
    $null = ConvertTo-PublicVpnIpv4 $RemoteAddress
    $baseline = Read-PublicVpnEvidence $BaselinePath; $connected = Read-PublicVpnEvidence $ConnectedPath
    $machine = Get-PublicVpnMachineHash; $now = [DateTimeOffset]::UtcNow
    $null = Assert-PublicVpnDocument $baseline.Document 'Baseline' $machine $baseline.Document.expected_exit_set_sha256 $now 600
    $null = Assert-PublicVpnDocument $connected.Document 'Connected' $machine $baseline.Document.expected_exit_set_sha256 $now 600
    if ($connected.Document.run_id -cne $baseline.Document.run_id -or $connected.Document.baseline_sha256 -cne $baseline.Sha256 -or
        $connected.Document.public_ipv4_sha256 -ceq $baseline.Document.public_ipv4_sha256) { throw 'russian_direct_foreign_vpn_proof_invalid' }
    $physicalIndices = @($baseline.Document.observers | ForEach-Object { [int]$_.interface_index } | Sort-Object -Unique)
    $vexIndices = @($connected.Document.observers | ForEach-Object { [int]$_.interface_index } | Sort-Object -Unique)
    if ($physicalIndices.Count -ne 1 -or $vexIndices.Count -ne 1 -or $physicalIndices[0] -eq $vexIndices[0]) { throw 'russian_direct_interface_identity_invalid' }
    $engine = Get-PublicVpnOwnedRoutingProcess
    Initialize-PublicVpnNativeProbe
    $curl = Resolve-PublicVpnSystemCurl
    $output = [IO.File]::Open([IO.Path]::GetFullPath($ResultPath), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $proof = [ordered]@{ schema = 'vex.windows-russian-direct-verification.v1'; passed = $false; failure_code = $null;
        run_id = $baseline.Document.run_id; machine_sha256 = $machine; baseline_sha256 = $baseline.Sha256; connected_sha256 = $connected.Sha256;
        started_at_utc = [DateTimeOffset]::UtcNow.ToString('O'); completed_at_utc = $null;
        observer = 'yandex.ru'; remote_ipv4_sha256 = Get-PublicVpnTextHash $RemoteAddress; local_ipv4_sha256 = $null;
        router_sha256 = $engine.RouterSha256; physical_interface_index = $physicalIndices[0]; vex_interface_index = $vexIndices[0];
        owned_router_verified = $true; foreign_vpn_egress_verified = $true; physical_socket_verified = $false;
        https_status = 0; tls_verified = $false; redirects = 0; proxy_disabled = $true; ipv4_only = $true }
    $pending = $null; $failure = $null
    try {
        # Slow only the bounded public response, so its established socket can
        # be independently attributed to the signed router and physical NIC.
        $arguments = '--disable --ipv4 --silent --show-error --fail --proto "=https" --connect-timeout 5 --max-time 20 --max-redirs 0 --proxy "" --noproxy "*" --max-filesize 65536 --limit-rate 8192 --resolve "yandex.ru:443:' +
            $RemoteAddress + '" --output NUL --write-out "VEX_META:%{http_code}|%{remote_ip}|%{num_redirects}|%{ssl_verify_result}" "https://yandex.ru/robots.txt"'
        $pending = [VexPublicVpnBoundedProcess]::Begin($curl, $arguments, 25000, 1024)
        $timer = [Diagnostics.Stopwatch]::StartNew(); $observed = $null
        while (-not $pending.IsCompleted -and $timer.ElapsedMilliseconds -lt 26000) {
            $query = "OwningProcess=" + $engine.ProcessId + " AND RemoteAddress='" + $RemoteAddress + "' AND RemotePort=443 AND State=5"
            $connections = @(Get-CimInstance -Namespace 'root/StandardCimv2' -ClassName MSFT_NetTCPConnection -OperationTimeoutSec 2 -ErrorAction Stop -Filter $query)
            foreach ($connection in $connections) {
                $local = @(Get-NetIPAddress -AddressFamily IPv4 -IPAddress $connection.LocalAddress -ErrorAction Stop)
                if (Test-WindowsRussianDirectSocket $connection $engine.ProcessId $RemoteAddress $physicalIndices[0] $vexIndices[0] $local) { $observed = $connection; break }
            }
            if ($null -ne $observed) { break }
            Start-Sleep -Milliseconds 50
        }
        $result = $pending.GetAwaiter().GetResult()
        if ($result.TimedOut -or $result.OutputExceeded -or $result.ExitCode -ne 0 -or $result.ErrorLength -ne 0 -or
            $result.Output -cne ('VEX_META:200|' + $RemoteAddress + '|0|0')) { throw 'russian_direct_https_probe_failed' }
        if ($null -eq $observed) { throw 'russian_direct_physical_socket_not_observed' }
        $finalEngine = Get-PublicVpnOwnedRoutingProcess
        if ($finalEngine.ProcessId -ne $engine.ProcessId -or $finalEngine.RouterSha256 -cne $engine.RouterSha256) { throw 'russian_direct_router_changed' }
        $proof.local_ipv4_sha256 = Get-PublicVpnTextHash $observed.LocalAddress
        $proof.physical_socket_verified = $true; $proof.https_status = 200; $proof.tls_verified = $true; $proof.passed = $true
    } catch {
        $failure = $_; $code = [string]$_.Exception.Message
        $proof.failure_code = $(if ($code -match '^russian_direct_[a-z0-9_]+$') { $code } else { 'russian_direct_observation_failed' })
    } finally {
        # The worker itself owns the fixed child deadline and drains bounded
        # output. Do not leave a request running when an OS observation fails.
        if ($null -ne $pending) { try { $null = $pending.GetAwaiter().GetResult() } catch {} }
        $proof.completed_at_utc = [DateTimeOffset]::UtcNow.ToString('O')
        try { $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($proof | ConvertTo-Json -Depth 5)); $output.Write($bytes, 0, $bytes.Length); $output.Flush() }
        finally { $output.Dispose() }
    }
    if ($null -ne $failure) { throw $proof.failure_code }
}
