namespace Vex.Windows.Core.Vpn;

public static class VpnRuntimeStatusPolicy
{
    public static VpnTunnelStatus FromServiceObservation(
        bool serviceRunning,
        bool serviceStartPending,
        string? locationId,
        VpnTunnelDiagnostics diagnostics)
    {
        ArgumentNullException.ThrowIfNull(diagnostics);
        if (serviceRunning)
        {
            // Foreground installation holds the runtime gate until validation.
            // A running vendor without its adapter is a degraded established
            // connection, not an indefinitely pending foreground connection.
            return diagnostics.IsUsable
                ? new VpnTunnelStatus(VpnConnectionPhase.Connected,
                    locationId ?? "unknown", null, diagnostics)
                : new VpnTunnelStatus(VpnConnectionPhase.Error,
                    locationId, "tunnel_network_degraded", diagnostics);
        }

        return serviceStartPending
            ? new VpnTunnelStatus(VpnConnectionPhase.Connecting,
                locationId ?? "unknown", null, diagnostics)
            : new VpnTunnelStatus(VpnConnectionPhase.Disconnected,
                null, null, diagnostics);
    }
}
