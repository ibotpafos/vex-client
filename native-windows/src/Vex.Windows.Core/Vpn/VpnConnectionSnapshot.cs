namespace Vex.Windows.Core.Vpn;

public enum VpnConnectionPhase
{
    Disconnected,
    Connecting,
    Connected,
    Disconnecting,
    Error,
}

public sealed record VpnConnectionSnapshot(
    VpnConnectionPhase Phase,
    string? LocationId,
    long Sequence,
    string? ErrorCode)
{
    public VpnTunnelDiagnostics? Diagnostics { get; init; }

    public static VpnConnectionSnapshot Disconnected(long sequence = 0) =>
        new(VpnConnectionPhase.Disconnected, null, sequence, null);

    public static VpnConnectionSnapshot ClientFailure(
        VpnConnectionSnapshot previous,
        string errorCode)
    {
        ArgumentNullException.ThrowIfNull(previous);
        ArgumentException.ThrowIfNullOrWhiteSpace(errorCode);
        return new VpnConnectionSnapshot(
            VpnConnectionPhase.Error,
            previous.LocationId,
            previous.Sequence,
            errorCode)
        {
            Diagnostics = previous.Diagnostics,
        };
    }
}

public abstract record VpnIntent
{
    private VpnIntent()
    {
    }

    public sealed record Connect(string LocationId) : VpnIntent;

    public sealed record Disconnect : VpnIntent;

    public sealed record ServiceSnapshot(
        VpnConnectionPhase Phase,
        string? LocationId,
        long Sequence,
        string? ErrorCode) : VpnIntent;
}
