namespace Vex.Windows.Core.Vpn;

public interface IVpnTunnelRuntime
{
    Task<VpnTunnelStatus> GetStatusAsync(CancellationToken cancellationToken);

    Task<VpnTunnelStatus> GetDiagnosticsAsync(
        CancellationToken cancellationToken) =>
        GetStatusAsync(cancellationToken);

    Task<VpnTunnelStatus> SetAntiLeakAsync(
        bool enabled,
        CancellationToken cancellationToken) =>
        GetStatusAsync(cancellationToken);

    Task<VpnTunnelStatus> ConnectAsync(
        string locationId,
        string tunnelConfig,
        DateTimeOffset? authorizationExpiresAt,
        CancellationToken cancellationToken);

    Task<VpnTunnelStatus> ConnectAsync(
        string locationId,
        string tunnelConfig,
        DateTimeOffset? authorizationExpiresAt,
        bool antiLeakEnabled,
        CancellationToken cancellationToken) =>
        ConnectAsync(
            locationId,
            tunnelConfig,
            authorizationExpiresAt,
            cancellationToken);

    Task<VpnTunnelStatus> DisconnectAsync(CancellationToken cancellationToken);
}

public sealed record VpnTunnelStatus
{
    public VpnTunnelStatus(
        VpnConnectionPhase phase,
        string? locationId,
        string? errorCode,
        VpnTunnelDiagnostics? diagnostics = null)
    {
        if (phase is VpnConnectionPhase.Connecting
            or VpnConnectionPhase.Connected
            or VpnConnectionPhase.Disconnecting)
        {
            ArgumentException.ThrowIfNullOrWhiteSpace(locationId);
        }

        if (phase == VpnConnectionPhase.Disconnected && locationId is not null)
        {
            throw new ArgumentException(
                "A disconnected tunnel cannot retain a location.",
                nameof(locationId));
        }

        if (phase == VpnConnectionPhase.Error)
        {
            ArgumentException.ThrowIfNullOrWhiteSpace(errorCode);
        }
        else if (errorCode is not null)
        {
            throw new ArgumentException(
                "Only an error tunnel status can include an error code.",
                nameof(errorCode));
        }

        Phase = phase;
        LocationId = locationId;
        ErrorCode = errorCode;
        Diagnostics = diagnostics;
    }

    public VpnConnectionPhase Phase { get; }

    public string? LocationId { get; }

    public string? ErrorCode { get; }

    public VpnTunnelDiagnostics? Diagnostics { get; }

    public static VpnTunnelStatus Disconnected() =>
        new(VpnConnectionPhase.Disconnected, null, null);
}

public sealed class VpnTunnelException : Exception
{
    public VpnTunnelException(string code)
        : base("The VPN tunnel runtime rejected the operation.")
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(code);
        Code = code;
    }

    public string Code { get; }
}
