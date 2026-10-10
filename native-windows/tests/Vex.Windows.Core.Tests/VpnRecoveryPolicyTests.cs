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

        ObservationsDoNotRestartConnectionGrace(now, connected);
        UnwantedConnectionsRetryCleanupWithBackoff(now, connected);
    }

    private static void ObservationsDoNotRestartConnectionGrace(DateTimeOffset now, VpnConnectionSnapshot connected)
    {
        var tracker = new VpnConnectionHealthTracker();
        var pendingHandshake = connected with
        {
            Diagnostics = connected.Diagnostics! with { LatestHandshakeAt = null },
        };
        for (var poll = 0; poll <= 6; poll++)
            tracker.Observe(pendingHandshake with { Sequence = poll + 1 }, now.AddSeconds(poll * 10));
        Assert(tracker.ConnectedSince == now, "IPC status sequences must not restart handshake grace.");
        Assert(VpnRecoveryPolicy.ShouldRecover(pendingHandshake, true, true, true,
                now.AddSeconds(60), tracker.ConnectedSince, null),
            "Missing handshake must recover after grace despite repeated diagnostic observations.");

        var freshHandshake = pendingHandshake with
        {
            Diagnostics = pendingHandshake.Diagnostics! with { LatestHandshakeAt = now.AddSeconds(59) },
        };
        tracker.Observe(freshHandshake with { Sequence = 100 }, now.AddSeconds(60));
        Assert(!VpnRecoveryPolicy.ShouldRecover(freshHandshake, true, true, true,
                now.AddSeconds(60), tracker.ConnectedSince, null),
            "A verified recent service handshake must remain authoritative.");

        tracker.Observe(pendingHandshake with { LocationId = "fi-1" }, now.AddSeconds(70));
        Assert(tracker.ConnectedSince == now.AddSeconds(70), "A changed exit must receive its own grace period.");
        tracker.Observe(pendingHandshake with
        {
            LocationId = "fi-1",
            Diagnostics = pendingHandshake.Diagnostics! with { AdapterIndex = 8 },
        }, now.AddSeconds(80));
        Assert(tracker.ConnectedSince == now.AddSeconds(80), "A replaced adapter must receive its own grace period.");
        tracker.Observe(VpnConnectionSnapshot.Disconnected(), now.AddSeconds(90));
        tracker.Observe(pendingHandshake, now.AddSeconds(100));
        Assert(tracker.ConnectedSince == now.AddSeconds(100), "A real reconnect must restart connection grace.");
    }

    private static void UnwantedConnectionsRetryCleanupWithBackoff(DateTimeOffset now, VpnConnectionSnapshot connected)
    {
        bool Cleanup(VpnConnectionSnapshot snapshot, bool explicitIntent = true, bool desired = false,
            DateTimeOffset? attempted = null) => VpnRecoveryPolicy.ShouldEnforceDisconnect(
                snapshot, explicitIntent, desired, now, attempted);
        Assert(Cleanup(connected), "A failed explicit disconnect must be retried.");
        Assert(Cleanup(connected with { Phase = VpnConnectionPhase.Connecting }),
            "An unwanted pending connection must be canceled.");
        Assert(Cleanup(connected with { Phase = VpnConnectionPhase.Error }),
            "Degraded cleanup evidence must remain retryable after logout.");
        Assert(Cleanup(new VpnConnectionSnapshot(VpnConnectionPhase.Error, "de-1", 2, "tunnel_cleanup_incomplete")),
            "A failed service response without diagnostics must retain its active location as cleanup evidence.");
        Assert(Cleanup(new VpnConnectionSnapshot(VpnConnectionPhase.Error, null, 3, "firewall_unverified")
        {
            Diagnostics = VpnTunnelDiagnostics.Empty with { LeakProtection = VpnLeakProtectionState.Blocking },
        }), "Cleanup must retry an owned firewall left behind before adapter creation.");
        Assert(Cleanup(new VpnConnectionSnapshot(VpnConnectionPhase.Error, null, 4, "tunnel_cleanup_incomplete")),
            "A reported incomplete cleanup must remain retryable without adapter or location metadata.");
        Assert(!Cleanup(connected, desired: true), "A later explicit connect must stop forced cleanup.");
        Assert(!Cleanup(connected, explicitIntent: false), "An admitted locked-session tunnel must not be treated as unwanted.");
        Assert(!Cleanup(connected, attempted: now.AddSeconds(-29)), "Cleanup retries must back off after failure.");
        Assert(Cleanup(connected, attempted: now.AddSeconds(-30)), "Cleanup retries must resume at the backoff boundary.");
        Assert(!Cleanup(VpnConnectionSnapshot.Disconnected()), "Confirmed cleanup must stop retrying.");
    }

    private static void Assert(bool value, string message)
    {
        if (!value) throw new InvalidOperationException(message);
    }
}
