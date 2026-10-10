namespace Vex.Windows.Core.Vpn;

/// <summary>Shared watchdog decisions, independent of the current page or tray.</summary>
public static class VpnRecoveryPolicy
{
    public static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(10);
    public static readonly TimeSpan RecoveryBackoff = TimeSpan.FromSeconds(30);
    public static readonly TimeSpan HandshakeGrace = TimeSpan.FromSeconds(45);
    public static readonly TimeSpan MaximumHandshakeAge = TimeSpan.FromMinutes(3);

    public static bool IsTerminalError(string? code) => code is
        "vpn_entitlement_required" or "sign_in_required" or "windows_hello_required" or "required_update";

    public static bool ShouldRecover(
        VpnConnectionSnapshot snapshot,
        bool connectionDesired,
        bool recoveryEnabled,
        bool sessionAvailable,
        DateTimeOffset now,
        DateTimeOffset? connectedSince,
        DateTimeOffset? lastRecoveryAttempt)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (!connectionDesired || !recoveryEnabled || !sessionAvailable ||
            IsTerminalError(snapshot.ErrorCode) ||
            snapshot.Phase is VpnConnectionPhase.Connecting or VpnConnectionPhase.Disconnecting ||
            lastRecoveryAttempt is { } last && now - last < RecoveryBackoff)
        {
            return false;
        }

        if (snapshot.Phase is VpnConnectionPhase.Disconnected or VpnConnectionPhase.Error)
        {
            return true;
        }

        if (snapshot.Phase != VpnConnectionPhase.Connected ||
            connectedSince is not { } connected || now - connected < HandshakeGrace)
        {
            return false;
        }

        var diagnostics = snapshot.Diagnostics;
        return diagnostics is not null &&
            (!diagnostics.IsUsable ||
             diagnostics.LeakProtection is VpnLeakProtectionState.Blocking or VpnLeakProtectionState.Degraded ||
             diagnostics.LatestHandshakeAt is not { } handshake ||
             now - handshake > MaximumHandshakeAge);
    }
}
