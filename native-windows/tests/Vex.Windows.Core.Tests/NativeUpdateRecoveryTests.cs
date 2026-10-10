using System.Security.Cryptography;
using System.Text.Json;
using Vex.Windows.App.Services;
using Vex.Windows.Client.Updates;

internal static class NativeUpdateRecoveryTests
{
    public static void Run()
    {
        foreach (var error in new Exception[]
        {
            new CryptographicException("Rollback ciphertext is corrupt."),
            new JsonException("Protected rollback JSON is malformed."),
            new InvalidOperationException("Persisted required version is invalid."),
            new UnauthorizedAccessException("Rollback record cannot be read."),
            new IOException("Rollback record is unavailable."),
        })
        {
            var configured = false;
            var recovery = NativeUpdateService.InitializeWithDurableRollback(() => throw error, _ =>
            {
                configured = true;
                return (null, NativeUpdateSnapshot.Configured("1.0.0.0", "stable", "x64"));
            }, "1.0.0.0", "stable", "x64");
            Require(!configured && recovery.Coordinator is null &&
                recovery.InitialSnapshot is
                {
                    State: "required_update_recovery", Required: true, UpdateAvailable: true,
                    Release: null, StagedPackagePath: null, RequiredVersionFloor: null, RequiredTargetVersion: null,
                } && recovery.InitialSnapshot.Message!.Contains("центр загрузок", StringComparison.Ordinal),
                "An unreadable durable record must retain a recovery/connect gate without manufacturing signed install authority.");
        }

        var missing = NativeUpdateService.InitializeWithDurableRollback(() => null, state =>
        {
            Require(state is null, "A first installation must not invent durable rollback state.");
            return (null, NativeUpdateSnapshot.Configured("1.0.0.0", "stable", "arm64"));
        }, "1.0.0.0", "stable", "arm64");
        Require(missing.InitialSnapshot is { State: "configured", Required: false, UpdateAvailable: false },
            "An absent record on first installation must leave the client usable.");

        var durable = new WindowsUpdateRollbackState(7, "2.0.0.0", "3.0.0.0");
        var known = NativeUpdateService.InitializeWithDurableRollback(() => durable,
            _ => throw new FormatException("Pinned keyring is malformed."), "1.0.0.0", "stable", "x64");
        Require(known.Coordinator is null && known.InitialSnapshot is
            {
                Required: true, UpdateAvailable: true, Release: null,
                RequiredVersionFloor: "2.0.0.0", RequiredTargetVersion: "3.0.0.0",
            }, "A trust configuration failure must preserve the successfully read mandatory floor and target.");

        var satisfied = NativeUpdateService.InitializeWithDurableRollback(() => durable,
            _ => throw new FormatException("Pinned keyring is malformed."), "3.0.0.0", "stable", "x64");
        Require(satisfied.InitialSnapshot is { State: "disabled", Required: false, UpdateAvailable: false },
            "An installed binary satisfying readable durable requirements must remain usable during a separate updater trust failure.");

        var unrelated = NativeUpdateService.InitializeWithDurableRollback(() => null,
            _ => throw new FormatException("Pinned keyring is malformed."), "1.0.0.0", "stable", "x64");
        Require(unrelated.InitialSnapshot is { State: "disabled", Required: false, UpdateAvailable: false },
            "A separate updater configuration failure with no durable requirement must not create a mandatory target.");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
