namespace Vex.Windows.Core.Vpn;

public static class VpnConnectionActionPolicy
{
    public static bool ShouldDisconnect(VpnConnectionSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        return snapshot.Phase == VpnConnectionPhase.Connected ||
            snapshot.Phase == VpnConnectionPhase.Error &&
            VpnRecoveryPolicy.RequiresDisconnect(snapshot);
    }
}
