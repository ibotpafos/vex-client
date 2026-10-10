[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][switch]$DisposableRunner,
    [Parameter(Mandatory = $true)][string]$ResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# This is a deliberately restrictive CI fixture, never a user's VPN smoke test.
# It must not install over a service, adopt an adapter, change the default route,
# change firewall policy, call production endpoints, or use release credentials.
if (-not $DisposableRunner -or -not $IsWindows -or $env:GITHUB_ACTIONS -cne 'true' -or
    $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or
    [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw 'VPN acceptance requires an explicitly disposable GitHub-hosted Windows runner.'
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'VPN acceptance requires the disposable runner administrator account.'
}
if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64) {
    throw 'This qualified runtime fixture currently covers Windows x64 only.'
}
$vpnServices = @(Get-Service | Where-Object {
    $_.Name -match '^(Amnezia|WireGuard|OpenVPN|VEX)' -or $_.Name -eq 'VEX VPN Service'
})
if ($vpnServices.Count -ne 0) { throw 'A foreign VPN service is installed; refusing to mutate this runner.' }
$adapters = @(Get-NetAdapter -IncludeHidden)
if (@($adapters | Where-Object {
    $_.Name -ieq 'vex' -or $_.InterfaceDescription -match '(?i)wintun|wireguard|amnezia|openvpn|tap-windows|tailscale|zerotier|proton|nordvpn'
}).Count -ne 0) { throw 'A VPN adapter is already present; refusing to mutate this runner.' }
if (Get-Command Get-VpnConnection -ErrorAction SilentlyContinue) {
    $connections = @(Get-VpnConnection) + @(Get-VpnConnection -AllUserConnection)
    if (@($connections | Where-Object ConnectionStatus -ne 'Disconnected').Count -ne 0) {
        throw 'A Windows VPN connection is active; refusing to mutate this runner.'
    }
}
$productionDirectory = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'VEX/VPN'
if (Test-Path -LiteralPath $productionDirectory) { throw 'Production VEX service state is present.' }
$vendorStateDirectory = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'AmneziaWG'
if (Test-Path -LiteralPath $vendorStateDirectory) { throw 'Existing vendor data belongs to another owner.' }
function Get-FixtureWintunDrivers {
    @(Get-WindowsDriver -Online -All | Where-Object {
        [IO.Path]::GetFileName($_.OriginalFileName) -ieq 'wintun.inf'
    })
}
# Do not let the qualified DLL upgrade or remove a foreign driver package.
if (@(Get-FixtureWintunDrivers).Count -ne 0) { throw 'A Wintun driver is already installed; refusing to adopt or upgrade it.' }
if (@(Get-NetIPAddress | Where-Object IPAddress -in @('10.253.253.1', '10.253.253.2')).Count -ne 0 -or
    @(Get-NetRoute | Where-Object DestinationPrefix -eq '10.253.253.1/32').Count -ne 0) {
    throw 'The isolated fixture addresses or route already belong to another owner.'
}
$ResultPath = [IO.Path]::GetFullPath($ResultPath)
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
. (Join-Path $repositoryRoot 'native-windows/packaging/ReleaseValidation.ps1')
$fixtureId = [Guid]::NewGuid().ToString('N')
$fixtureDirectory = Join-Path $env:RUNNER_TEMP "vex-vpn-acceptance-$fixtureId"
if (Test-Path -LiteralPath $fixtureDirectory) { throw 'Fixture directory collision.' }
[IO.Directory]::CreateDirectory($fixtureDirectory) | Out-Null
# Private fixture keys stay outside the uploaded artifact directory. Inheritance
# is removed before any secret material is generated.
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
foreach ($sid in @($principal.Identity.User, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
    [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl',
        'ContainerInherit,ObjectInherit', 'None', 'Allow'))
}
Set-Acl -LiteralPath $fixtureDirectory -AclObject $acl
[IO.File]::WriteAllText((Join-Path $fixtureDirectory 'owned-fixture'), $fixtureId)

function Resolve-FixtureTool {
    param([Parameter(Mandatory = $true)][string]$Name)
    # -CommandType Application returns all PATH matches, including the runner's
    # preinstalled SDK. ProcessStartInfo needs one executable, in PATH order.
    $command = Get-Command -Name $Name -CommandType Application | Select-Object -First 1
    if ($null -eq $command) { throw 'Required fixture SDK executable is missing.' }
    return $command.Source
}

function Resolve-FixtureHostAddress {
    # The qualified Windows runtime binds outer UDP to the physical default
    # interface after startup. Its peer must use an address already local to
    # that interface; 127.0.0.1 can complete an early handshake then lose data.
    $physical = @(Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -ExpandProperty InterfaceIndex)
    $candidate = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -PolicyStore ActiveStore |
        Where-Object { $_.InterfaceIndex -in $physical -and $_.NextHop -ne '0.0.0.0' } | ForEach-Object {
            $interface = Get-NetIPInterface -AddressFamily IPv4 -InterfaceIndex $_.InterfaceIndex
            [pscustomobject]@{InterfaceIndex=$_.InterfaceIndex;Metric=([int]$_.RouteMetric + [int]$interface.InterfaceMetric)}
        } | Sort-Object Metric, InterfaceIndex)
    if ($candidate.Count -eq 0) { throw 'No active physical IPv4 default interface exists for the isolated peer.' }
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $candidate[0].InterfaceIndex -PolicyStore ActiveStore |
        Where-Object { $_.AddressState -eq 'Preferred' -and -not $_.SkipAsSource -and
            $_.IPAddress -notin @('10.253.253.1', '10.253.253.2', '0.0.0.0') -and
            -not [Net.IPAddress]::IsLoopback([Net.IPAddress]::Parse($_.IPAddress)) } | Sort-Object IPAddress)
    if ($addresses.Count -eq 0) { throw 'The isolated peer requires an already assigned physical IPv4 address.' }
    return [string]$addresses[0].IPAddress
}

function Read-FixtureEndpointRoutes {
    param([string]$Address)
    @(Get-NetRoute -DestinationPrefix "$Address/32" -PolicyStore ActiveStore |
        Sort-Object InterfaceIndex, NextHop, RouteMetric | ForEach-Object {
            "$($_.InterfaceIndex)|$($_.NextHop)|$($_.RouteMetric)"
        }) | ConvertTo-Json -Compress -AsArray
}

function Invoke-FixtureProcess {
    param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds, [string]$WorkingDirectory)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    if ($WorkingDirectory) { $start.WorkingDirectory = $WorkingDirectory }
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            [void]$process.WaitForExit(5000)
            throw 'Fixture child exceeded its finite deadline.'
        }
        # Discard arbitrary vendor output: configurations/UAPI must never reach logs.
        [void]$stdout.GetAwaiter().GetResult()
        [void]$stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Fixture child failed with exit code $($process.ExitCode)." }
    }
    finally { $process.Dispose() }
}
function Read-FixtureBaseline {
    # Compare physical DNS and effective profile policy after cleanup. No global
    # AntiLeak test is performed because that could sever the CI control channel.
    [ordered]@{
        dns = @(Get-DnsClientServerAddress | Where-Object InterfaceIndex -in @($adapters.InterfaceIndex) |
            Sort-Object InterfaceIndex, AddressFamily | ForEach-Object {
                "$($_.InterfaceIndex)|$($_.AddressFamily)|$($_.ServerAddresses -join ',')"
            })
        firewall = @(Get-NetFirewallProfile -PolicyStore ActiveStore | Sort-Object Name |
            ForEach-Object { "$($_.Name)|$($_.Enabled)|$($_.DefaultInboundAction)|$($_.DefaultOutboundAction)" })
        vex_rules = @(Get-NetFirewallRule -PolicyStore PersistentStore | Where-Object Group -eq 'VEX VPN AntiLeak' |
            Sort-Object Name | Select-Object -ExpandProperty Name)
    } | ConvertTo-Json -Compress -Depth 4
}
$baseline = Read-FixtureBaseline
$peer = $null
$vendorPath = $null
$runtimeOwned = $false
$hostAddress = $null
$nativeEndpointRoutes = $null
$failure = $null
$cleanupFailure = $null
$scriptResult = [ordered]@{
    schema = 'vex.windows-vpn-acceptance-wrapper.v1'
    runtime_version = '3.1.0'
    runtime_msi_sha256 = 'a1b48ea8699cd347832a3691d832004574ef8ad65bcf887611ac8acb99b7de8b'
    disposable_hosted_runner = $true
    anti_leak_enabled = $false
    vendor_service_removed = $false
    tunnel_adapter_removed = $false
    fixture_route_removed = $false
    native_endpoint_route_unchanged = $true
    physical_dns_and_firewall_unchanged = $false
    new_wintun_driver_removed = $false
    owned_vendor_log_removed = $false
    fixture_private_material_removed = $false
    passed = $false
    stage = 'runtime-download'
    cleanup_stage = 'not-started'
}
try {
    Write-Host 'Preparing pinned official AWG 3.1.0 runtime for isolated acceptance.'
    $msiPath = Join-Path $fixtureDirectory 'runtime.msi'
    Invoke-WebRequest -Uri 'https://github.com/amnezia-vpn/amneziawg-windows-client/releases/download/3.1.0/amneziawg-amd64-3.1.0.msi' `
        -OutFile $msiPath -MaximumRedirection 5 -TimeoutSec 90
    if ((Get-FileHash -LiteralPath $msiPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $scriptResult.runtime_msi_sha256) {
        throw 'Official AWG runtime MSI hash does not match the qualified 3.1.0 asset.'
    }
    $extraction = Join-Path $fixtureDirectory 'extracted'
    $scriptResult.stage = 'runtime-extraction'
    Invoke-FixtureProcess -FilePath "$env:SystemRoot/System32/msiexec.exe" `
        -Arguments @('/a', $msiPath, '/qn', "TARGETDIR=$extraction") -TimeoutSeconds 90
    $vendor = @(Get-ChildItem -LiteralPath $extraction -Filter 'amneziawg.exe' -File -Recurse)
    $wintun = @(Get-ChildItem -LiteralPath $extraction -Filter 'wintun.dll' -File -Recurse)
    if ($vendor.Count -ne 1 -or $wintun.Count -ne 1) { throw 'Qualified MSI runtime files are ambiguous or missing.' }
    $runtimeDirectory = Join-Path $fixtureDirectory 'runtime'
    New-Item -ItemType Directory -Path $runtimeDirectory | Out-Null
    $vendorPath = Join-Path $runtimeDirectory 'amneziawg.exe'
    Copy-Item -LiteralPath $vendor[0].FullName -Destination $vendorPath
    Copy-Item -LiteralPath $wintun[0].FullName -Destination (Join-Path $runtimeDirectory 'wintun.dll')
    foreach ($asset in @('amneziawg.exe', 'wintun.dll')) {
        $path = Join-Path $runtimeDirectory $asset
        Assert-WindowsPeArchitecture -Path $path -Architecture x64
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $scriptResult[$asset.Replace('.', '_') + '_sha256'] = $hash
        [IO.File]::WriteAllText((Join-Path $fixtureDirectory $(if($asset -eq 'amneziawg.exe'){'amneziawg-sha256'}else{'wintun-sha256'})), $hash)
    }
    $go = Resolve-FixtureTool -Name go
    $dotnet = Resolve-FixtureTool -Name dotnet
    $peerSource = Join-Path $PSScriptRoot 'vpn-fixture-peer'
    $scriptResult.stage = 'peer-build-and-test'
    Invoke-FixtureProcess -FilePath $go -Arguments @('mod', 'verify') -TimeoutSeconds 120 -WorkingDirectory $peerSource
    Invoke-FixtureProcess -FilePath $go -Arguments @('test', '-count=1', '-timeout=60s', './...') -TimeoutSeconds 90 -WorkingDirectory $peerSource
    $peerPath = Join-Path $fixtureDirectory 'vpn-fixture-peer.exe'
    Invoke-FixtureProcess -FilePath $go -Arguments @('build', '-trimpath', '-buildvcs=false', '-o', $peerPath, '.') `
        -TimeoutSeconds 180 -WorkingDirectory $peerSource
    $harnessDirectory = Join-Path $fixtureDirectory 'harness'
    $scriptResult.stage = 'harness-build'
    Invoke-FixtureProcess -FilePath $dotnet -Arguments @('publish',
        (Join-Path $PSScriptRoot 'Vex.Windows.VpnAcceptance/Vex.Windows.VpnAcceptance.csproj'),
        '-c', 'Debug', '-r', 'win-x64', '-p:Platform=x64', '--self-contained', 'true', '-o', $harnessDirectory, '--nologo') `
        -TimeoutSeconds 240 -WorkingDirectory $repositoryRoot
    $start = [Diagnostics.ProcessStartInfo]::new()
    $scriptResult.stage = 'peer-start'
    $hostAddress = Resolve-FixtureHostAddress
    $nativeEndpointRoutes = Read-FixtureEndpointRoutes -Address $hostAddress
    $start.FileName = $peerPath
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-directory', $fixtureDirectory, '-lifetime', '180s', '-endpoint-address', $hostAddress)) { $start.ArgumentList.Add($argument) }
    $peer = [Diagnostics.Process]::Start($start)
    $peerStdout = $peer.StandardOutput.ReadToEndAsync()
    $peerStderr = $peer.StandardError.ReadToEndAsync()
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath (Join-Path $fixtureDirectory 'manifest.json'))) {
        if ($peer.HasExited -or [DateTime]::UtcNow -ge $deadline) { throw 'Isolated peer did not become ready.' }
        Start-Sleep -Milliseconds 100
    }
    # Ownership is authorized only after all preflight/build stages succeeded and
    # before VEX can create its one previously absent vendor tunnel service.
    $runtimeOwned = $true
    $scriptResult.stage = 'runtime-acceptance'
    Invoke-FixtureProcess -FilePath (Join-Path $harnessDirectory 'Vex.Windows.VpnAcceptance.exe') `
        -Arguments @('--disposable-runner', $fixtureDirectory, $runtimeDirectory, $ResultPath) -TimeoutSeconds 160
    $harnessResult = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json
    if (-not $harnessResult.passed) { throw 'Actual VEX tunnel fixture did not pass.' }
}
catch { $failure = $_.Exception.GetType().FullName }
finally {
    try {
        $scriptResult.cleanup_stage = 'vendor-service'
        if ($runtimeOwned -and (Get-Service -Name 'AmneziaWGTunnel$vex' -ErrorAction SilentlyContinue)) {
            # Only this exact service was absent at preflight and created by our
            # fixture. Never delete/stop any other service or arbitrary adapter.
            $ownedService = @(Get-CimInstance Win32_Service | Where-Object Name -ceq 'AmneziaWGTunnel$vex')
            $ownedConfiguration = [IO.Path]::GetFullPath((Join-Path $fixtureDirectory 'service-state/Private/vex.conf'))
            if ($ownedService.Count -ne 1 -or
                -not $ownedService[0].PathName.Contains($vendorPath, [StringComparison]::OrdinalIgnoreCase) -or
                -not $ownedService[0].PathName.Contains($ownedConfiguration, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Vendor service no longer points to this owned fixture; refusing to uninstall it.'
            }
            Invoke-FixtureProcess -FilePath $vendorPath -Arguments @('/uninstalltunnelservice', 'vex') -TimeoutSeconds 45
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        do {
            $remaining = Get-Service -Name 'AmneziaWGTunnel$vex' -ErrorAction SilentlyContinue
            if (-not $remaining) { break }
            Start-Sleep -Milliseconds 200
        } while ([DateTime]::UtcNow -lt $deadline)
        $scriptResult.vendor_service_removed = -not [bool]$remaining
        $scriptResult.cleanup_stage = 'adapter-route-dns-firewall'
        $scriptResult.tunnel_adapter_removed = -not [bool](Get-NetAdapter -IncludeHidden | Where-Object Name -ieq 'vex')
        $scriptResult.fixture_route_removed = @(Get-NetRoute | Where-Object DestinationPrefix -eq '10.253.253.1/32').Count -eq 0
        if ($null -ne $hostAddress) {
            $scriptResult.native_endpoint_route_unchanged = (Read-FixtureEndpointRoutes -Address $hostAddress) -ceq $nativeEndpointRoutes
        }
        $scriptResult.physical_dns_and_firewall_unchanged = (Read-FixtureBaseline) -ceq $baseline
        if (-not $scriptResult.vendor_service_removed -or -not $scriptResult.tunnel_adapter_removed -or
            -not $scriptResult.fixture_route_removed -or -not $scriptResult.native_endpoint_route_unchanged -or
            -not $scriptResult.physical_dns_and_firewall_unchanged) {
            throw 'Fixture-owned state did not fully clean up or physical DNS/firewall changed.'
        }
        $scriptResult.cleanup_stage = 'wintun-driver'
        if ($runtimeOwned -and @(Get-FixtureWintunDrivers).Count -gt 0) {
            if (@(Get-NetAdapter -IncludeHidden | Where-Object InterfaceDescription -match '(?i)wintun').Count -ne 0) {
                throw 'A Wintun adapter remains; refusing driver removal.'
            }
            if (-not ('Vex.Windows.Fixture.DeleteDriver' -as [type])) {
                Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
namespace Vex.Windows.Fixture {
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public delegate bool DeleteDriver();
}
'@
            }
            # The official Wintun API removes its driver only when no adapters
            # use it. Preflight proved that no prior Wintun package existed.
            $library = [Runtime.InteropServices.NativeLibrary]::Load((Join-Path $runtimeDirectory 'wintun.dll'))
            try {
                $entry = [Runtime.InteropServices.NativeLibrary]::GetExport($library, 'WintunDeleteDriver')
                $delete = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($entry, [Vex.Windows.Fixture.DeleteDriver])
                if (-not $delete.Invoke()) { throw 'The fixture Wintun driver did not uninstall.' }
            }
            finally { [Runtime.InteropServices.NativeLibrary]::Free($library) }
        }
        $scriptResult.new_wintun_driver_removed = @(Get-FixtureWintunDrivers).Count -eq 0
        if (-not $scriptResult.new_wintun_driver_removed) { throw 'The fixture Wintun package remains installed.' }
        $scriptResult.cleanup_stage = 'vendor-log'
        if (Test-Path -LiteralPath $vendorStateDirectory) {
            if (-not $runtimeOwned) { throw 'Unexpected vendor data appeared before the fixture runtime.' }
            $data = Join-Path $vendorStateDirectory 'Data'
            $log = Join-Path $data 'log.bin'
            if (((Get-Item -LiteralPath $vendorStateDirectory).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                ((Test-Path -LiteralPath $data) -and
                    (((Get-Item -LiteralPath $data).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0))) {
                throw 'Vendor state was redirected; refusing deletion.'
            }
            $unexpected = @(Get-ChildItem -LiteralPath $vendorStateDirectory -Force | Where-Object Name -cne 'Data')
            if (Test-Path -LiteralPath $data) {
                $unexpected += @(Get-ChildItem -LiteralPath $data -Force | Where-Object Name -cne 'log.bin')
            }
            if ($unexpected.Count -ne 0) {
                throw 'Vendor directory contains unexpected or redirected state; refusing recursive deletion.'
            }
            if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
            if (Test-Path -LiteralPath $data) { Remove-Item -LiteralPath $data -Force }
            Remove-Item -LiteralPath $vendorStateDirectory -Force
        }
        $scriptResult.owned_vendor_log_removed = -not (Test-Path -LiteralPath $vendorStateDirectory)
        $scriptResult.cleanup_stage = 'completed'
    }
    catch { $cleanupFailure = $_.Exception.GetType().FullName }
    finally {
        if ($null -ne $peer) {
            if (-not $peer.HasExited) { $peer.Kill($true); [void]$peer.WaitForExit(5000) }
            [void]$peerStdout.GetAwaiter().GetResult()
            [void]$peerStderr.GetAwaiter().GetResult()
            $peer.Dispose()
        }
        if (-not $cleanupFailure) {
            Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force
            $scriptResult.fixture_private_material_removed = -not (Test-Path -LiteralPath $fixtureDirectory)
        }
        $scriptResult.passed = -not $failure -and -not $cleanupFailure -and $scriptResult.fixture_private_material_removed
        if ($scriptResult.passed) { $scriptResult.stage = 'completed' }
        if ($failure) { $scriptResult.failure_type = $failure }
        if ($cleanupFailure) { $scriptResult.cleanup_failure_type = $cleanupFailure }
        $resultDirectory = Split-Path -Parent $ResultPath
        New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null
        $scriptResult | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$ResultPath.cleanup.json" -Encoding utf8
    }
}
if (-not $scriptResult.passed) { throw 'Isolated Windows VPN acceptance failed; inspect sanitized acceptance JSON.' }
Write-Host 'Real VEX signed AWG3.1 profile, fresh UAPI handshake, tunneled DNS/HTTPS and fixture cleanup passed.'
