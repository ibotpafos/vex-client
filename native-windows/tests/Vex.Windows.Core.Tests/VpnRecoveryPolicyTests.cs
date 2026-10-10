using Vex.Windows.Core.Vpn;

internal static class VpnRecoveryPolicyTests
{
    public static void Run()
    {
        var now = DateTimeOffset.Parse("2026-10-10T12:00:00Z");
        var connected = new VpnConnectionSnapshot(VpnConnectionPhase.Connected, "de-1", 1, null)
        {
            Diagnostics = new VpnTunnelDiagnostics("VEX", 7, "192.0.2.1:443",
                2048, 1024, now.AddSeconds(-30), true, true, true, true,
                VpnLeakProtectionState.Armed, ["1.1.1.1"], []),
        };
        bool Recover(VpnConnectionSnapshot state, bool desired = true, bool enabled = true,
            bool available = true, DateTimeOffset? since = null, DateTimeOffset? last = null) =>
            VpnRecoveryPolicy.ShouldRecover(state, desired, enabled, available, now,
                since ?? now.AddMinutes(-5), last);

        Assert(!Recover(connected), "Healthy active tunnel must stay connected.");
        Assert(Recover(VpnConnectionSnapshot.Disconnected()), "Desired dropped connection must recover.");
        Assert(!Recover(VpnConnectionSnapshot.Disconnected(), desired: false), "Explicit disconnect must persist.");
        Assert(!Recover(VpnConnectionSnapshot.Disconnected(), enabled: false), "Recovery setting must be respected.");
        Assert(!Recover(VpnConnectionSnapshot.Disconnected(), available: false), "Locked session must not reconnect.");
        Assert(!Recover(VpnConnectionSnapshot.Disconnected(), last: now.AddSeconds(-10)), "Backoff must prevent a recovery storm.");
        Assert(Recover(VpnConnectionSnapshot.Disconnected(), last: now.AddSeconds(-30)), "Backoff boundary must permit retry.");
        Assert(!Recover(connected with { Phase = VpnConnectionPhase.Connecting }), "In-flight connect must not restart.");
        Assert(!Recover(connected with { Phase = VpnConnectionPhase.Disconnecting }), "In-flight disconnect must win.");
        Assert(Recover(connected with { Diagnostics = connected.Diagnostics! with { LatestHandshakeAt = now.AddMinutes(-4) } }),
            "An adapter and routes alone do not prove a healthy tunnel.");
        Assert(Recover(connected with { Diagnostics = connected.Diagnostics! with { LatestHandshakeAt = null } }),
            "Missing handshake must recover after grace.");
        Assert(!Recover(connected with { Diagnostics = connected.Diagnostics! with { LatestHandshakeAt = null } }, since: now.AddSeconds(-20)),
            "Fresh connection must receive handshake grace.");
        Assert(Recover(connected with { Diagnostics = connected.Diagnostics! with { LeakProtection = VpnLeakProtectionState.Blocking } }),
            "Leak-blocked tunnel must attempt safe recovery.");
        Assert(!Recover(connected with { Phase = VpnConnectionPhase.Error, ErrorCode = "vpn_entitlement_required" }),
            "Expired subscription must not trigger an endless reconnect loop.");
    }

    private static void Assert(bool value, string message)
    {
        if (!value) throw new InvalidOperationException(message);
    }
}
