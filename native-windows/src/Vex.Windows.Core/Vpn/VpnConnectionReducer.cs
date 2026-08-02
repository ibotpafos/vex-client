namespace Vex.Windows.Core.Vpn;

public static class VpnConnectionReducer
{
    public static VpnConnectionSnapshot Reduce(
        VpnConnectionSnapshot current,
        VpnIntent intent) =>
        intent switch
        {
            VpnIntent.Connect connect => BeginConnect(current, connect.LocationId),
            VpnIntent.Disconnect => BeginDisconnect(current),
            VpnIntent.ServiceSnapshot snapshot => ApplyServiceSnapshot(current, snapshot),
            _ => throw new ArgumentOutOfRangeException(nameof(intent)),
        };

    private static VpnConnectionSnapshot BeginConnect(
        VpnConnectionSnapshot current,
        string locationId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(locationId);

        if (current.Phase == VpnConnectionPhase.Connected &&
            string.Equals(current.LocationId, locationId, StringComparison.Ordinal))
        {
            return current;
        }

        if (current.Phase is VpnConnectionPhase.Connecting or VpnConnectionPhase.Disconnecting)
        {
            return current;
        }

        return new VpnConnectionSnapshot(
            VpnConnectionPhase.Connecting,
            locationId,
            checked(current.Sequence + 1),
            ErrorCode: null);
    }

    private static VpnConnectionSnapshot BeginDisconnect(VpnConnectionSnapshot current)
    {
        if (current.Phase is VpnConnectionPhase.Disconnected or VpnConnectionPhase.Disconnecting)
        {
            return current;
        }

        return new VpnConnectionSnapshot(
            VpnConnectionPhase.Disconnecting,
            current.LocationId,
            checked(current.Sequence + 1),
            ErrorCode: null);
    }

    private static VpnConnectionSnapshot ApplyServiceSnapshot(
        VpnConnectionSnapshot current,
        VpnIntent.ServiceSnapshot snapshot)
    {
        if (snapshot.Sequence <= current.Sequence)
        {
            return current;
        }

        if (current.Phase == VpnConnectionPhase.Disconnecting &&
            snapshot.Phase is VpnConnectionPhase.Connecting or VpnConnectionPhase.Connected)
        {
            return current;
        }

        if (snapshot.Phase == VpnConnectionPhase.Error)
        {
            ArgumentException.ThrowIfNullOrWhiteSpace(snapshot.ErrorCode);
        }

        if (snapshot.Phase is VpnConnectionPhase.Connecting
            or VpnConnectionPhase.Connected
            or VpnConnectionPhase.Disconnecting)
        {
            ArgumentException.ThrowIfNullOrWhiteSpace(snapshot.LocationId);
        }

        var locationId = snapshot.Phase == VpnConnectionPhase.Disconnected
            ? null
            : snapshot.LocationId;
        var errorCode = snapshot.Phase == VpnConnectionPhase.Error
            ? snapshot.ErrorCode
            : null;

        return new VpnConnectionSnapshot(
            snapshot.Phase,
            locationId,
            snapshot.Sequence,
            errorCode);
    }
}
