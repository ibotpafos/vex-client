using System.Security.Cryptography;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Vpn;
using Vex.Windows.Core.Vpn.Ipc;

namespace Vex.Windows.App.Services;

/// <summary>Revalidates an admitted tunnel without applying stale account results.</summary>
public sealed class ActiveEntitlementMonitor
{
    private readonly NativeClientCoordinator _coordinator;
    private readonly VpnUiStateService _vpnState;
    private readonly Func<CancellationToken, Task<VpnServiceResponse>> _disconnect;
    private readonly Func<DateTimeOffset> _utcNow;
    private readonly TimeSpan _requestTimeout;
    private readonly object _checkSync = new();
    private DateTimeOffset? _lastCheck;

    public ActiveEntitlementMonitor(NativeClientCoordinator coordinator,
        VpnUiStateService vpnState,
        Func<CancellationToken, Task<VpnServiceResponse>> disconnect,
        Func<DateTimeOffset>? utcNow = null)
        : this(coordinator, vpnState, disconnect, utcNow, TimeSpan.FromSeconds(15)) { }

    internal ActiveEntitlementMonitor(NativeClientCoordinator coordinator,
        VpnUiStateService vpnState,
        Func<CancellationToken, Task<VpnServiceResponse>> disconnect,
        Func<DateTimeOffset>? utcNow, TimeSpan requestTimeout)
    {
        ArgumentNullException.ThrowIfNull(coordinator);
        ArgumentNullException.ThrowIfNull(vpnState);
        ArgumentNullException.ThrowIfNull(disconnect);
        if (requestTimeout <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(requestTimeout));
        _coordinator = coordinator;
        _vpnState = vpnState;
        _disconnect = disconnect;
        _utcNow = utcNow ?? (() => DateTimeOffset.UtcNow);
        _requestTimeout = requestTimeout;
    }

    public async Task CheckAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (_vpnState.Snapshot.Phase != VpnConnectionPhase.Connected ||
            _coordinator.CurrentStateAccess != ClientStateAccessKind.Available ||
            _coordinator.CurrentState?.Session.AccessToken is not { } expectedToken)
            return;
        var intentVersion = _vpnState.ConnectionIntentVersion;
        var now = _utcNow();
        lock (_checkSync)
        {
            if (_lastCheck is { } last && now - last < TimeSpan.FromMinutes(1)) return;
            _lastCheck = now;
        }

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_requestTimeout);
        try
        {
            await _coordinator.ValidateEntitlementAsync(timeout.Token, expectedToken).ConfigureAwait(false);
        }
        catch (NativeClientFlowException error) when (
            error.Code is "vpn_entitlement_required" or "sign_in_required")
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (timeout.IsCancellationRequested) return;
            using var cleanup = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            cleanup.CancelAfter(TimeSpan.FromSeconds(60));
            await _vpnState.RunAsync(async token =>
            {
                token.ThrowIfCancellationRequested();
                var current = _vpnState.Snapshot;
                var access = _coordinator.CurrentStateAccess;
                var sessionMatches = access == ClientStateAccessKind.Available &&
                    _coordinator.CurrentState?.Session.AccessToken == expectedToken;
                // An authoritative refresh rejection can clear the current
                // session. A Hello lock only hides it and never revokes a tunnel.
                var rejectedSessionCleared = error.Code == "sign_in_required" &&
                    access == ClientStateAccessKind.Missing;
                if (current.Phase != VpnConnectionPhase.Connected ||
                    (!sessionMatches && !rejectedSessionCleared) ||
                    !_vpnState.TryMarkConnectionUndesired(intentVersion))
                    return new VpnServiceResponse(Guid.NewGuid().ToString("N"), true, current, null);

                var response = await _disconnect(token).ConfigureAwait(false);
                if (response.Success && response.Snapshot.Phase == VpnConnectionPhase.Disconnected &&
                    !VpnRecoveryPolicy.RequiresDisconnect(response.Snapshot)) return response;
                return new VpnServiceResponse(response.RequestId, false,
                    VpnConnectionSnapshot.ClientFailure(current, "tunnel_cleanup_incomplete"),
                    "tunnel_cleanup_incomplete");
            }, cleanup.Token, recordCancellationFailure: false).ConfigureAwait(false);
        }
        catch (Exception error) when (IsExpectedFailure(error) && !cancellationToken.IsCancellationRequested)
        {
            // Outages, request deadlines, changed sessions, and Hello locks do
            // not revoke the admission of an otherwise working tunnel.
        }
    }

    private static bool IsExpectedFailure(Exception error) => error is
        IOException or UnauthorizedAccessException or CryptographicException or
        HttpRequestException or InvalidOperationException or NativeClientFlowException or
        VexApiException or VpnIpcProtocolException or OperationCanceledException;
}
