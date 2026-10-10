namespace Vex.Windows.Core.Vpn;

/// <summary>Tracks an admitted connection independently of IPC observation sequences.</summary>
public sealed class VpnConnectionHealthTracker
{
    private (string? Location, string? Adapter, int? AdapterIndex, string? Endpoint)? _identity;

    public DateTimeOffset? ConnectedSince { get; private set; }

    public void Observe(VpnConnectionSnapshot snapshot, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (snapshot.Phase != VpnConnectionPhase.Connected)
        {
            ConnectedSince = null;
            _identity = null;
            return;
        }

        var identity = (snapshot.LocationId, snapshot.Diagnostics?.AdapterName,
            snapshot.Diagnostics?.AdapterIndex, snapshot.Diagnostics?.Endpoint);
        if (_identity != identity) ConnectedSince = now;
        _identity = identity;
    }
}
