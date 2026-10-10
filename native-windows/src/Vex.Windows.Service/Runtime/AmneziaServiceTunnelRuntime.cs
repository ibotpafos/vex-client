using System.ComponentModel;
using System.Diagnostics;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.AccessControl;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text;
using System.Text.Json;
using Vex.Windows.Core.Vpn;

namespace Vex.Windows.Service.Runtime;

public sealed class AmneziaServiceTunnelRuntime : IVpnTunnelRuntime, IVpnRuntimeLifetime, IDisposable
{
    private static readonly TimeSpan OperationTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(250);
    private static readonly TimeSpan MaximumHandshakeAge = TimeSpan.FromSeconds(180);

    private readonly WindowsServiceOptions _options;
    private readonly string _privateDataDirectory;
    private readonly string _configurationPath;
    private readonly string _configurationHashPath;
    private readonly string _locationPath;
    private readonly string _authorizationExpiryPath;
    private readonly VpnDisconnectIntent _disconnectIntent;
    private readonly object _desireGate = new();
    private VpnRuntimeRepairAttempt? _repairAttempt;
    private readonly object _leaseGate = new();
    private readonly NetworkSafetyController _networkSafety;
    private readonly SemaphoreSlim _runtimeGate = new(1, 1);
    private readonly SemaphoreSlim _watchdogGate = new(1, 1);
    private readonly PeriodicTimer _watchdogTimer =
        new(TimeSpan.FromSeconds(15));
    private CancellationTokenSource? _leaseCancellation;
    private readonly VpnRuntimeBackgroundWork _backgroundWork = new();
    private int _watchdogSuppressed;
    private bool _connectionDesired;

    public AmneziaServiceTunnelRuntime(WindowsServiceOptions options)
    {
        _options = options;
        _networkSafety = new NetworkSafetyController(options);
        _privateDataDirectory = Path.Combine(options.DataDirectory, "Private");
        _configurationPath = Path.Combine(
            _privateDataDirectory,
            "vex.conf");
        _configurationHashPath = Path.Combine(
            options.DataDirectory,
            "vex.conf.sha256");
        _locationPath = Path.Combine(options.DataDirectory, "location");
        _authorizationExpiryPath = Path.Combine(
            options.DataDirectory,
            "authorization-expires-at");
        _disconnectIntent = new VpnDisconnectIntent(
            Path.Combine(_privateDataDirectory, "disconnect-intent"));
        _connectionDesired = !_disconnectIntent.IsRecorded &&
            ReadAuthorizationExpiry() is not null;
        RecoverAuthorizationLease();
        NetworkChange.NetworkAddressChanged += OnNetworkAddressChanged;
        _backgroundWork.Run(RunWatchdogAsync);
    }

    public async Task<VpnTunnelStatus> GetStatusAsync(
        CancellationToken cancellationToken)
    {
        using var operation = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken, _backgroundWork.Token);
        cancellationToken = operation.Token;
        await _runtimeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return await GetStatusCoreAsync(cancellationToken).ConfigureAwait(false); }
        finally { _runtimeGate.Release(); }
    }

    private async Task<VpnTunnelStatus> GetStatusCoreAsync(
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var serviceStatus = ReadServiceStatus();
        if (!_connectionDesired || _disconnectIntent.IsRecorded || AuthorizationExpired() ||
            serviceStatus == ServiceControllerStatus.Running && ReadAuthorizationExpiry() is null)
        {
            return await DisconnectCoreAsync(cancellationToken).ConfigureAwait(false);
        }

        var locationId = ReadLocation();
        var diagnostics = await CaptureDiagnosticsAsync(cancellationToken).ConfigureAwait(false);
        if (AuthorizationExpired())
        {
            return await DisconnectCoreAsync(cancellationToken).ConfigureAwait(false);
        }

        return VpnRuntimeStatusPolicy.FromServiceObservation(
            serviceStatus == ServiceControllerStatus.Running,
            serviceStatus == ServiceControllerStatus.StartPending,
            locationId,
            diagnostics);
    }

    public Task<VpnTunnelStatus> GetDiagnosticsAsync(
        CancellationToken cancellationToken) =>
        GetStatusAsync(cancellationToken);

    public async Task<VpnTunnelStatus> SetAntiLeakAsync(
        bool enabled,
        CancellationToken cancellationToken)
    {
        using var operation = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken, _backgroundWork.Token);
        cancellationToken = operation.Token;
        await _runtimeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return await SetAntiLeakCoreAsync(enabled, cancellationToken).ConfigureAwait(false); }
        finally { _runtimeGate.Release(); }
    }

    private async Task<VpnTunnelStatus> SetAntiLeakCoreAsync(
        bool enabled,
        CancellationToken cancellationToken)
    {
        if (_disconnectIntent.IsRecorded || !_connectionDesired || AuthorizationExpired())
        {
            return await GetStatusCoreAsync(cancellationToken).ConfigureAwait(false);
        }
        var config = ReadConfiguration() ??
            throw new VpnTunnelException("tunnel_configuration_missing");
        var endpoint = ReadConfigValue(config, "Endpoint") ??
            throw new VpnTunnelException("invalid_tunnel_configuration");
        if (enabled)
        {
            var adapter = FindTunnelAdapter() ??
                throw new VpnTunnelException("tunnel_adapter_missing");
            await _networkSafety.ApplyControlPlaneBypassAsync(
                endpoint,
                cancellationToken,
                ReadConfigValue(config, "PublicKey"),
                ReadAuthorizationExpiry()).ConfigureAwait(false);
            await _networkSafety.ArmFirewallAsync(
                adapter.Name,
                endpoint,
                cancellationToken,
                ReadConfigValue(config, "PublicKey"),
                ReadAuthorizationExpiry()).ConfigureAwait(false);
        }
        else
        {
            await _networkSafety.DisarmFirewallOnlyAsync(cancellationToken)
                .ConfigureAwait(false);
        }

        return await GetStatusCoreAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task<VpnTunnelStatus> ConnectAsync(
        string locationId,
        string tunnelConfig,
        DateTimeOffset? authorizationExpiresAt,
        CancellationToken cancellationToken) =>
        await ConnectAsync(
            locationId,
            tunnelConfig,
            authorizationExpiresAt,
            antiLeakEnabled: true,
            cancellationToken).ConfigureAwait(false);

    public async Task<VpnTunnelStatus> ConnectAsync(
        string locationId,
        string tunnelConfig,
        DateTimeOffset? authorizationExpiresAt,
        bool antiLeakEnabled,
        CancellationToken cancellationToken)
    {
        var callerToken = cancellationToken;
        using var operation = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken, _backgroundWork.Token);
        using var authorization = new VpnAuthorizationDeadline(
            authorizationExpiresAt ?? throw new VpnTunnelException("profile_expired"), operation.Token);
        authorization.ThrowIfExpired();
        cancellationToken = authorization.Token;
        try
        {
            await _runtimeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                return await ConnectCoreAsync(locationId, tunnelConfig,
                    authorizationExpiresAt, antiLeakEnabled, cancellationToken, authorization).ConfigureAwait(false);
            }
            finally { _runtimeGate.Release(); }
        }
        catch (OperationCanceledException) when (authorization.IsExpired &&
            !callerToken.IsCancellationRequested && !_backgroundWork.Token.IsCancellationRequested)
        {
            throw new VpnTunnelException("profile_expired");
        }
    }

    private async Task<VpnTunnelStatus> ConnectCoreAsync(
        string locationId,
        string tunnelConfig,
        DateTimeOffset? authorizationExpiresAt,
        bool antiLeakEnabled,
        CancellationToken cancellationToken,
        VpnAuthorizationDeadline authorization)
    {
        Interlocked.Increment(ref _watchdogSuppressed);
        try
        {
            if (authorizationExpiresAt is null ||
                authorizationExpiresAt <= DateTimeOffset.UtcNow)
            {
                throw new VpnTunnelException("profile_expired");
            }

            ValidateConnectInput(locationId, tunnelConfig);
            EnsureRuntimeFilesExist();
            Directory.CreateDirectory(_options.DataDirectory);
            EnsurePrivateDataDirectory();

            var configurationHash = ComputeHash(tunnelConfig);
            var endpoint = ReadConfigValue(tunnelConfig, "Endpoint") ??
                throw new VpnTunnelException("invalid_tunnel_configuration");
            // A process crash during connection must not turn a newly written
            // authorization lease into permission to resurrect a partial setup.
            var connectionRevision = RecordDisconnectIntent();
            var transactionStarted = false;
            VpnTunnelDiagnostics? verifiedDiagnostics = null;
            try
            {
                transactionStarted = true;
                await _networkSafety.ApplyControlPlaneBypassAsync(
                    endpoint,
                    cancellationToken,
                    ReadConfigValue(tunnelConfig, "PublicKey"),
                    authorizationExpiresAt).ConfigureAwait(false);
                var requiresInstall =
                    !HasInstalledConfiguration(configurationHash);
                var minimumHandshakeAt = requiresInstall ||
                    ReadServiceStatus() != ServiceControllerStatus.Running
                    ? DateTimeOffset.UtcNow.AddSeconds(-2)
                    : DateTimeOffset.UtcNow - MaximumHandshakeAge;
                if (requiresInstall)
                {
                    await ReplaceTunnelAsync(cancellationToken)
                        .ConfigureAwait(false);
                    WriteConfiguration(
                        tunnelConfig,
                        configurationHash,
                        locationId);
                    await RunVendorAsync(
                        "/installtunnelservice",
                        _configurationPath,
                        cancellationToken).ConfigureAwait(false);
                }
                else
                {
                    WriteAtomic(_locationPath, locationId);
                }

                WriteAtomic(
                    _authorizationExpiryPath,
                    authorizationExpiresAt.Value.ToString("O"));
                ArmAuthorizationLease(authorizationExpiresAt.Value);
                await StartVendorServiceAsync(cancellationToken)
                    .ConfigureAwait(false);
                await WaitForConnectedAsync(cancellationToken)
                    .ConfigureAwait(false);
                var adapter = FindTunnelAdapter() ??
                    throw new VpnTunnelException("tunnel_adapter_timeout");
                if (antiLeakEnabled)
                {
                    await _networkSafety.ArmFirewallAsync(
                        adapter.Name,
                        endpoint,
                        cancellationToken,
                        ReadConfigValue(tunnelConfig, "PublicKey"),
                        authorizationExpiresAt).ConfigureAwait(false);
                }
                else
                {
                    await _networkSafety.DisarmFirewallOnlyAsync(
                        cancellationToken).ConfigureAwait(false);
                }
                verifiedDiagnostics = await WaitForNetworkSafetyAsync(cancellationToken, minimumHandshakeAt)
                    .ConfigureAwait(false);
                lock (_desireGate)
                {
                    authorization.ThrowIfExpired();
                    cancellationToken.ThrowIfCancellationRequested();
                    _backgroundWork.Token.ThrowIfCancellationRequested();
                    _disconnectIntent.ClearForVerifiedConnection(connectionRevision);
                    _connectionDesired = true;
                }
            }
            catch
            {
                _connectionDesired = false;
                if (transactionStarted && !_backgroundWork.IsStopping)
                {
                    await RollbackFailedConnectAsync().ConfigureAwait(false);
                }
                throw;
            }

            return new VpnTunnelStatus(
                VpnConnectionPhase.Connected,
                locationId,
                errorCode: null,
                verifiedDiagnostics ?? throw new VpnTunnelException("tunnel_network_degraded"));
        }
        finally
        {
            Interlocked.Decrement(ref _watchdogSuppressed);
        }
    }

    public async Task<VpnTunnelStatus> DisconnectAsync(
        CancellationToken cancellationToken)
    {
        // Persist the user's intent even if a connect currently owns the gate
        // and the IPC request is cancelled before cleanup can acquire it.
        TryRecordDisconnectIntent();
        await _runtimeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return await DisconnectCoreAsync(cancellationToken).ConfigureAwait(false); }
        finally { _runtimeGate.Release(); }
    }

    private async Task<VpnTunnelStatus> DisconnectCoreAsync(
        CancellationToken cancellationToken)
    {
        TryRecordDisconnectIntent();
        Interlocked.Increment(ref _watchdogSuppressed);
        try
        {
            await CleanupStoppedTunnelAsync(cancellationToken).ConfigureAwait(false);
            return VpnTunnelStatus.Disconnected();
        }
        finally
        {
            Interlocked.Decrement(ref _watchdogSuppressed);
        }
    }

    private async Task RollbackFailedConnectAsync()
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(_backgroundWork.Token);
        timeout.CancelAfter(VpnRuntimeLifetimePolicy.CleanupTimeout);
        try
        {
            await CleanupStoppedTunnelAsync(timeout.Token).ConfigureAwait(false);
        }
        catch (Exception error) when (error is VpnTunnelException or IOException
            or UnauthorizedAccessException or OperationCanceledException)
        {
            throw new VpnTunnelException("tunnel_cleanup_incomplete");
        }
    }

    private Task CleanupStoppedTunnelAsync(CancellationToken cancellationToken) =>
        VpnRuntimeLifetimePolicy.StopAndRestoreAsync(
            StopVendorServiceAsync,
            _networkSafety.RollbackAsync,
            _networkSafety.CleanupVerified,
            ClearAuthorizationLease,
            cancellationToken);

    private long RecordDisconnectIntent()
    {
        lock (_desireGate)
        {
            _repairAttempt?.Supersede();
            _connectionDesired = false;
            return _disconnectIntent.Record(() =>
            {
                Directory.CreateDirectory(_options.DataDirectory);
                EnsurePrivateDataDirectory();
            });
        }
    }

    private void TryRecordDisconnectIntent()
    {
        try { RecordDisconnectIntent(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // Storage failure must never prevent stopping the vendor. A
            // confirmed cleanup removes the lease and prevents resurrection;
            // an unconfirmed cleanup still reports failure and retains protection.
        }
    }

    public void BeginShutdown()
    {
        // Reject new work before taking the desired-state lock. A connect that
        // was already verifying its network cannot clear the durable stop intent.
        _backgroundWork.Stop();
        NetworkChange.NetworkAddressChanged -= OnNetworkAddressChanged;
        _watchdogTimer.Dispose();
        TryRecordDisconnectIntent();
    }

    public async Task QuiesceAsync(CancellationToken cancellationToken)
    {
        BeginShutdown();
        await _backgroundWork.DrainAsync(cancellationToken).ConfigureAwait(false);
        // Also drain a public operation which was using the same cancellation
        // token. The host has stopped accepting IPC before crossing this barrier.
        await _runtimeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        _runtimeGate.Release();
    }

    public void Dispose()
    {
        NetworkChange.NetworkAddressChanged -= OnNetworkAddressChanged;
        _backgroundWork.Stop();
        _watchdogTimer.Dispose();
        // Callbacks may still be releasing their gates during synchronous host
        // disposal. Let their managed semaphores be collected after completion.
        lock (_leaseGate)
        {
            _leaseCancellation?.Cancel();
            _leaseCancellation?.Dispose();
            _leaseCancellation = null;
        }
    }

    private void RecoverAuthorizationLease()
    {
        var expiry = ReadAuthorizationExpiry();
        if (expiry is not null)
        {
            ArmAuthorizationLease(expiry.Value);
        }
    }

    private void ArmAuthorizationLease(DateTimeOffset expiresAt)
    {
        CancellationTokenSource cancellation;
        lock (_leaseGate)
        {
            _leaseCancellation?.Cancel();
            _leaseCancellation?.Dispose();
            cancellation = CancellationTokenSource.CreateLinkedTokenSource(_backgroundWork.Token);
            _leaseCancellation = cancellation;
        }

        var leaseToken = cancellation.Token;
        _backgroundWork.Run(async _ =>
        {
            try
            {
                var delay = expiresAt - DateTimeOffset.UtcNow;
                if (delay > TimeSpan.Zero)
                {
                    await Task.Delay(delay, leaseToken)
                        .ConfigureAwait(false);
                }

                await _runtimeGate.WaitAsync(leaseToken).ConfigureAwait(false);
                try
                {
                    // A renewed authorization can replace the lease while this
                    // callback is waiting for an in-flight connect to complete.
                    lock (_leaseGate)
                    {
                        if (!ReferenceEquals(_leaseCancellation, cancellation)) { return; }
                    }
                    leaseToken.ThrowIfCancellationRequested();
                    if (AuthorizationExpired())
                    {
                        await DisconnectCoreAsync(leaseToken).ConfigureAwait(false);
                    }
                }
                finally { _runtimeGate.Release(); }
            }
            catch (OperationCanceledException)
            {
            }
            catch (Exception error) when (error is VpnTunnelException or IOException
                or UnauthorizedAccessException)
            {
                // Keep the expired lease marker. The next status request
                // retries the fail-closed stop instead of treating it as valid.
            }
        });
    }

    private bool AuthorizationExpired()
    {
        var expiry = ReadAuthorizationExpiry();
        return expiry is not null &&
            expiry <= DateTimeOffset.UtcNow;
    }

    private DateTimeOffset? ReadAuthorizationExpiry()
    {
        try
        {
            var value = File.ReadAllText(_authorizationExpiryPath).Trim();
            return DateTimeOffset.TryParse(
                value,
                System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.RoundtripKind,
                out var expiry)
                ? expiry
                : DateTimeOffset.MinValue;
        }
        catch (FileNotFoundException)
        {
            return null;
        }
        catch (DirectoryNotFoundException)
        {
            return null;
        }
    }

    private void ClearAuthorizationLease()
    {
        lock (_leaseGate)
        {
            _leaseCancellation?.Cancel();
            _leaseCancellation?.Dispose();
            _leaseCancellation = null;
        }

        if (File.Exists(_authorizationExpiryPath))
        {
            File.Delete(_authorizationExpiryPath);
        }
    }

    private async Task ReplaceTunnelAsync(CancellationToken cancellationToken)
    {
        await StopVendorServiceAsync(cancellationToken).ConfigureAwait(false);
        if (!ServiceExists())
        {
            return;
        }

        await RunVendorAsync(
            "/uninstalltunnelservice",
            "vex",
            cancellationToken).ConfigureAwait(false);
        await WaitForServiceMissingAsync(cancellationToken).ConfigureAwait(false);
    }

    private async Task StartVendorServiceAsync(CancellationToken cancellationToken,
        VpnRuntimeRepairAttempt? repairAttempt = null)
    {
        cancellationToken.ThrowIfCancellationRequested();
        _backgroundWork.Token.ThrowIfCancellationRequested();
        try
        {
            using var service = OpenVendorService();
            void StartService()
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (ReadAuthorizationExpiry() is null || AuthorizationExpired())
                {
                    throw new VpnTunnelException("profile_expired");
                }
                service.Refresh();
                if (service.Status is not ServiceControllerStatus.Running
                    and not ServiceControllerStatus.StartPending)
                {
                    service.Start();
                }
            }

            if (repairAttempt is null) { StartService(); }
            else { repairAttempt.StartIfCurrent(StartService); }

            await WaitForServiceStatusAsync(
                service,
                ServiceControllerStatus.Running,
                cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error) when (IsServiceError(error))
        {
            throw new VpnTunnelException("tunnel_start_failed");
        }
    }

    private async Task StopVendorServiceAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!ServiceExists())
        {
            return;
        }

        try
        {
            using var service = OpenVendorService();
            service.Refresh();
            if (service.Status == ServiceControllerStatus.Stopped)
            {
                return;
            }

            if (service.Status != ServiceControllerStatus.StopPending)
            {
                service.Stop();
            }

            await WaitForServiceStatusAsync(
                service,
                ServiceControllerStatus.Stopped,
                cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error) when (IsMissingService(error))
        {
            // The service may have been removed concurrently. SCM confirms
            // absence; an access-denied/status error never counts as a stop.
        }
        catch (Exception error) when (IsServiceError(error))
        {
            throw new VpnTunnelException("tunnel_stop_failed");
        }
    }

    private async Task WaitForConnectedAsync(CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        timeout.CancelAfter(OperationTimeout);

        try
        {
            while (FindTunnelAdapter() is null)
            {
                await Task.Delay(PollInterval, timeout.Token).ConfigureAwait(false);
                if (ReadServiceStatus() != ServiceControllerStatus.Running)
                {
                    throw new VpnTunnelException("tunnel_start_failed");
                }
            }
        }
        catch (OperationCanceledException) when (
            !cancellationToken.IsCancellationRequested)
        {
            throw new VpnTunnelException("tunnel_adapter_timeout");
        }
    }

    private async Task<VpnTunnelDiagnostics> WaitForNetworkSafetyAsync(
        CancellationToken cancellationToken,
        DateTimeOffset? minimumHandshakeAt = null)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        timeout.CancelAfter(OperationTimeout);
        try
        {
            while (true)
            {
                var diagnostics = await CaptureDiagnosticsAsync(timeout.Token).ConfigureAwait(false);
                if (diagnostics.IsUsable &&
                    (minimumHandshakeAt is null || diagnostics.LatestHandshakeAt >= minimumHandshakeAt))
                {
                    return diagnostics;
                }
                await Task.Delay(PollInterval, timeout.Token).ConfigureAwait(false);
                if (ReadServiceStatus() != ServiceControllerStatus.Running)
                {
                    throw new VpnTunnelException("tunnel_network_degraded");
                }
            }
        }
        catch (OperationCanceledException) when (
            !cancellationToken.IsCancellationRequested)
        {
            throw new VpnTunnelException("tunnel_network_degraded");
        }
    }

    private static async Task WaitForServiceStatusAsync(
        ServiceController service,
        ServiceControllerStatus expected,
        CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        timeout.CancelAfter(OperationTimeout);

        try
        {
            while (true)
            {
                service.Refresh();
                if (service.Status == expected)
                {
                    return;
                }

                await Task.Delay(PollInterval, timeout.Token).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (
            !cancellationToken.IsCancellationRequested)
        {
            throw new VpnTunnelException("tunnel_service_timeout");
        }
    }

    private async Task WaitForServiceMissingAsync(
        CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        timeout.CancelAfter(OperationTimeout);

        try
        {
            while (ServiceExists())
            {
                await Task.Delay(PollInterval, timeout.Token).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (
            !cancellationToken.IsCancellationRequested)
        {
            throw new VpnTunnelException("tunnel_uninstall_timeout");
        }
    }

    private async Task RunVendorAsync(
        string operation,
        string argument,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var startInfo = new ProcessStartInfo
        {
            FileName = VendorExecutablePath(),
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        startInfo.ArgumentList.Add(operation);
        startInfo.ArgumentList.Add(argument);

        using var process = Process.Start(startInfo);
        if (process is null)
        {
            throw new VpnTunnelException("tunnel_runtime_launch_failed");
        }

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        timeout.CancelAfter(OperationTimeout);
        try
        {
            await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            TryTerminate(process);
            if (cancellationToken.IsCancellationRequested)
            {
                throw;
            }

            throw new VpnTunnelException("tunnel_runtime_timeout");
        }

        if (process.ExitCode != 0)
        {
            throw new VpnTunnelException("tunnel_runtime_failed");
        }
    }

    private static void TryTerminate(Process process)
    {
        try
        {
            process.Kill(entireProcessTree: true);
        }
        catch (Exception error) when (
            error is InvalidOperationException or Win32Exception)
        {
            // The process exited between cancellation and termination.
        }
    }

    private ServiceControllerStatus? ReadServiceStatus()
    {
        try
        {
            using var service = OpenVendorService();
            service.Refresh();
            return service.Status;
        }
        catch (Exception error) when (IsMissingService(error))
        {
            return null;
        }
        catch (Exception error) when (IsServiceError(error))
        {
            throw new VpnTunnelException("tunnel_service_status_unavailable");
        }
    }

    private bool ServiceExists() => ReadServiceStatus() is not null;

    private static NetworkInterface? FindTunnelAdapter() =>
        NetworkInterface.GetAllNetworkInterfaces().FirstOrDefault(adapter =>
            adapter.OperationalStatus == OperationalStatus.Up &&
            string.Equals(adapter.Name, "vex", StringComparison.OrdinalIgnoreCase));

    private async Task<VpnTunnelDiagnostics> CaptureDiagnosticsAsync(
        CancellationToken cancellationToken)
    {
        var config = ReadConfiguration();
        var endpoint = config is null
            ? null
            : ReadConfigValue(config, "Endpoint");
        var expectsIpv6 = config is not null &&
            ReadConfigValues(config, "Address")
                .Any(value => value.Contains(':'));
        var adapter = FindTunnelAdapter();
        var publicKey = config is null ? null : ReadConfigValue(config, "PublicKey");
        VpnPeerStatistics? peer = null;
        string? peerError = null;
        string? routeError = null;
        if (adapter is not null && publicKey is not null)
        {
            try
            {
                peer = await AmneziaPeerStatusClient.ReadAsync(publicKey, cancellationToken).ConfigureAwait(false);
                if (endpoint is not null && peer.HasFreshHandshake(DateTimeOffset.UtcNow, MaximumHandshakeAge))
                {
                    _networkSafety.ObserveSelectedPeerEndpoint(endpoint, publicKey, peer.Endpoint, ReadAuthorizationExpiry());
                }
            }
            catch (VpnTunnelException error) { peerError = error.Code; }
        }
        if (adapter is not null && endpoint is not null && publicKey is not null)
        {
            // On a cold controller or a newly observed peer IP, qualify the
            // known numeric address before reporting status. The controller
            // returns immediately for a prepared map; this does not resolve
            // DNS or rerun PowerShell on ordinary diagnostic polls.
            using var routingDeadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            routingDeadline.CancelAfter(TimeSpan.FromSeconds(10));
            try
            {
                await _networkSafety.EnsureKnownEndpointBypassAsync(endpoint, publicKey, routingDeadline.Token,
                    ReadAuthorizationExpiry())
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                routeError = "endpoint_bypass_verification_timeout";
            }
            catch (VpnTunnelException error) { routeError = error.Code; }
        }
        var diagnostics = _networkSafety.Capture(
            adapter,
            endpoint,
            expectsIpv6,
            config is null ? [] : ReadConfigValues(config, "AllowedIPs").ToArray(),
            config is null ? [] : ReadConfigValues(config, "DNS").ToArray(),
            publicKey);
        if (adapter is null || config is null) { return diagnostics; }
        var findings = diagnostics.Findings.ToList();
        if (routeError is not null) { findings.Add(routeError); }
        if (peer is null || peerError is not null)
        {
            findings.Add(peerError ?? "tunnel_peer_status_unavailable");
            return diagnostics with { Findings = findings };
        }
        if (peer.LatestHandshakeAt is null) { findings.Add("handshake_pending"); }
        else if (!peer.HasFreshHandshake(DateTimeOffset.UtcNow, MaximumHandshakeAge))
        {
            findings.Add("handshake_stale");
        }
        return diagnostics with
        {
            LatestHandshakeAt = peer.LatestHandshakeAt,
            RxBytes = peer.RxBytes,
            TxBytes = peer.TxBytes,
            Findings = findings,
        };
    }

    private string? ReadConfiguration()
    {
        try
        {
            return File.ReadAllText(_configurationPath);
        }
        catch (Exception error) when (
            error is FileNotFoundException or DirectoryNotFoundException)
        {
            return null;
        }
    }

    private static string? ReadConfigValue(string config, string key) =>
        ReadConfigValues(config, key).FirstOrDefault();

    private static IEnumerable<string> ReadConfigValues(
        string config,
        string key)
    {
        foreach (var line in config.Split('\n'))
        {
            var trimmed = line.Trim();
            if (trimmed.StartsWith('#') || trimmed.StartsWith('['))
            {
                continue;
            }

            var separator = trimmed.IndexOf('=');
            if (separator < 1 ||
                !string.Equals(
                    trimmed[..separator].Trim(),
                    key,
                    StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            foreach (var value in trimmed[(separator + 1)..]
                         .Split(',', StringSplitOptions.TrimEntries |
                            StringSplitOptions.RemoveEmptyEntries))
            {
                yield return value;
            }
        }
    }

    private void OnNetworkAddressChanged(object? sender, EventArgs args)
    {
        _backgroundWork.Run(RepairAfterNetworkChangeAsync);
    }

    private async Task RunWatchdogAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (await _watchdogTimer.WaitForNextTickAsync(cancellationToken)
                       .ConfigureAwait(false))
            {
                await RepairAfterNetworkChangeAsync(cancellationToken)
                    .ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (
            cancellationToken.IsCancellationRequested)
        {
        }
    }

    private async Task RepairAfterNetworkChangeAsync(
        CancellationToken cancellationToken)
    {
        if (_backgroundWork.IsStopping || Volatile.Read(ref _watchdogSuppressed) != 0)
        {
            return;
        }

        if (!await _watchdogGate.WaitAsync(0, cancellationToken)
                .ConfigureAwait(false))
        {
            return;
        }

        VpnRuntimeRepairAttempt? repairAttempt = null;
        VpnAuthorizationDeadline? authorization = null;
        try
        {
            if (!await _runtimeGate.WaitAsync(0, cancellationToken).ConfigureAwait(false))
            {
                return;
            }
            try
            {
                if (_disconnectIntent.IsRecorded || AuthorizationExpired() ||
                    ReadAuthorizationExpiry() is null || !_connectionDesired)
                {
                    await DisconnectCoreAsync(cancellationToken).ConfigureAwait(false);
                    return;
                }
                lock (_desireGate)
                {
                    // Disconnect records intent without waiting for this gate.
                    // Register the cancellable repair under the same intent lock
                    // before crossing any network or SCM await.
                    var expiresAt = ReadAuthorizationExpiry();
                    if (!_connectionDesired || _disconnectIntent.IsRecorded ||
                        expiresAt is null || expiresAt <= DateTimeOffset.UtcNow)
                    {
                        return;
                    }
                    authorization = new VpnAuthorizationDeadline(expiresAt.Value, cancellationToken);
                    repairAttempt = new VpnRuntimeRepairAttempt(authorization.Token);
                    _repairAttempt = repairAttempt;
                }
                cancellationToken = repairAttempt.Token;
                var config = ReadConfiguration();
                var endpoint = config is null ? null : ReadConfigValue(config, "Endpoint");
                if (endpoint is null) { return; }

                await _networkSafety.ApplyControlPlaneBypassAsync(endpoint, cancellationToken,
                    ReadConfigValue(config!, "PublicKey"), ReadAuthorizationExpiry()).ConfigureAwait(false);
                if (ReadServiceStatus() == ServiceControllerStatus.Running)
                {
                    await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken).ConfigureAwait(false);
                    if ((await CaptureDiagnosticsAsync(cancellationToken).ConfigureAwait(false)).IsUsable)
                    {
                        authorization.ThrowIfExpired();
                        return;
                    }
                }

                // Keep a valid desired connection retryable if the previous
                // restart failed after stopping its vendor service.
                var minimumHandshakeAt = DateTimeOffset.UtcNow.AddSeconds(-2);
                await StopVendorServiceAsync(cancellationToken).ConfigureAwait(false);
                await StartVendorServiceAsync(cancellationToken, repairAttempt).ConfigureAwait(false);
                await WaitForConnectedAsync(cancellationToken).ConfigureAwait(false);
                await WaitForNetworkSafetyAsync(cancellationToken, minimumHandshakeAt).ConfigureAwait(false);
                authorization.ThrowIfExpired();
            }
            finally { _runtimeGate.Release(); }
        }
        catch (OperationCanceledException) when (repairAttempt?.Token.IsCancellationRequested == true)
        {
            // An explicit disconnect cancels the current repair, not the
            // lifetime watchdog. Its next tick still enforces durable cleanup.
        }
        catch (Exception error) when (
            error is VpnTunnelException or SocketException or IOException or Win32Exception
                or UnauthorizedAccessException or JsonException)
        {
            // Status/diagnostics expose the degraded state. A bounded next
            // watchdog pass retries without crashing the LocalSystem service.
        }
        finally
        {
            lock (_desireGate)
            {
                if (ReferenceEquals(_repairAttempt, repairAttempt)) { _repairAttempt = null; }
                repairAttempt?.Dispose();
                authorization?.Dispose();
            }
            _watchdogGate.Release();
        }
    }

    private void WriteConfiguration(
        string tunnelConfig,
        string configurationHash,
        string locationId)
    {
        WriteAtomic(_configurationPath, tunnelConfig, restrictToSystem: true);
        WriteAtomic(_configurationHashPath, configurationHash);
        WriteAtomic(_locationPath, locationId);
    }

    private bool HasInstalledConfiguration(string configurationHash) =>
        ServiceExists() &&
        File.Exists(_configurationPath) &&
        string.Equals(
            ReadTrimmed(_configurationHashPath),
            configurationHash,
            StringComparison.Ordinal);

    private static string ComputeHash(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    private static void WriteAtomic(
        string path,
        string value,
        bool restrictToSystem = false)
    {
        var temporaryPath = $"{path}.{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllText(temporaryPath, value, new UTF8Encoding(false));
            if (restrictToSystem)
            {
                RestrictToSystem(temporaryPath);
            }

            File.Move(temporaryPath, path, overwrite: true);
        }
        finally
        {
            File.Delete(temporaryPath);
        }
    }

    private static void RestrictToSystem(string path)
    {
        var security = new FileSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            FileSystemRights.FullControl,
            AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier(
                WellKnownSidType.BuiltinAdministratorsSid,
                null),
            FileSystemRights.FullControl,
            AccessControlType.Allow));
        FileSystemAclExtensions.SetAccessControl(
            new FileInfo(path),
            security);
    }

    private void EnsurePrivateDataDirectory()
    {
        Directory.CreateDirectory(_privateDataDirectory);
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        var inheritance =
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            FileSystemRights.FullControl,
            inheritance,
            PropagationFlags.None,
            AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier(
                WellKnownSidType.BuiltinAdministratorsSid,
                null),
            FileSystemRights.FullControl,
            inheritance,
            PropagationFlags.None,
            AccessControlType.Allow));
        FileSystemAclExtensions.SetAccessControl(
            new DirectoryInfo(_privateDataDirectory),
            security);
    }

    private string? ReadLocation() => ReadTrimmed(_locationPath);

    private static string? ReadTrimmed(string path)
    {
        if (!File.Exists(path))
        {
            return null;
        }

        var value = File.ReadAllText(path).Trim();
        return value.Length == 0 ? null : value;
    }

    private void EnsureRuntimeFilesExist()
    {
        var vendorExecutable = VendorExecutablePath();
        var wintunLibrary = Path.Combine(
            _options.InstallDirectory,
            "wintun.dll");
        if (!File.Exists(vendorExecutable) ||
            !File.Exists(wintunLibrary))
        {
            throw new VpnTunnelException("tunnel_runtime_missing");
        }

        VerifyPinnedFile(
            vendorExecutable,
            _options.AmneziaExecutableSha256File);
        VerifyPinnedFile(wintunLibrary, _options.WintunSha256File);
    }

    private static void VerifyPinnedFile(string path, string hashFile)
    {
        try
        {
            var expected = Convert.FromHexString(
                File.ReadAllText(hashFile).Trim());
            var actual = SHA256.HashData(File.ReadAllBytes(path));
            if (expected.Length != actual.Length ||
                !CryptographicOperations.FixedTimeEquals(expected, actual))
            {
                throw new VpnTunnelException("tunnel_runtime_integrity_failure");
            }
        }
        catch (Exception error) when (
            error is IOException or FormatException)
        {
            throw new VpnTunnelException("tunnel_runtime_integrity_failure");
        }
    }

    private string VendorExecutablePath() =>
        Path.Combine(_options.InstallDirectory, "amneziawg.exe");

    private static void ValidateConnectInput(
        string locationId,
        string tunnelConfig)
    {
        if (locationId.Length > 128)
        {
            throw new VpnTunnelException("invalid_tunnel_configuration");
        }

        VpnTunnelConfigurationValidator.Validate(tunnelConfig);
    }

    private static bool IsServiceError(Exception error) =>
        error is InvalidOperationException or Win32Exception;

    private static bool IsMissingService(Exception error)
    {
        for (Exception? current = error; current is not null; current = current.InnerException)
        {
            if (current is Win32Exception { NativeErrorCode: 1060 }) { return true; }
        }
        return false;
    }

    private static ServiceController OpenVendorService() =>
        new(WindowsServiceOptions.VendorServiceName);
}
