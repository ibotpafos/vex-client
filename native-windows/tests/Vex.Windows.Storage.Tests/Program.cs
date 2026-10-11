using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Vex.Windows.App.Services;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Security;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Presentation;

if (!OperatingSystem.IsWindows())
{
    Console.WriteLine("SKIP: actual CurrentUser DPAPI storage acceptance requires Windows.");
    return 0;
}

var tests = new (string Name, Action Run)[]
{
    ("Pending rotation keys and owner survive sign-out and a fresh store", PendingRotationSurvivesSignOut),
    ("Auth-only state does not overwrite a separately recovered device key", AuthOnlySavePreservesRecoveredDevice),
    ("Confirmed rotation replaces the retained identity and clears its pending key", ConfirmedRotationClearsPendingKey),
    ("A failed session replacement retains the pending device key", PendingKeySurvivesFailedSessionReplacement),
    ("A failed session replacement retains the confirmed device key", ConfirmedKeySurvivesFailedSessionReplacement),
    ("A failed device replacement prevents a new session commit", FailedDeviceReplacementPreservesPreviousSession),
    ("Sign-out removes owned session remnants and preserves unrelated recovery files", SessionRemnantsAreCleared),
    ("A locked session remnant prevents a successful sign-out", LockedSessionRemnantPreventsLogout),
    ("Encrypted legacy device records remain readable without optional recovery fields", LegacyDeviceRecordIsReadable),
};

foreach (var test in tests)
{
    try
    {
        test.Run();
        Console.WriteLine($"PASS: {test.Name}");
    }
    catch (Exception error)
    {
        // Never print serialized state, key material, session tokens or a stack
        // trace. Assertion messages are fixed text; other failures name only
        // their type so CI can distinguish a filesystem failure from DPAPI.
        var detail = error is StorageAssertionException ? $": {error.Message}" : string.Empty;
        Console.Error.WriteLine($"FAIL: {test.Name} ({error.GetType().Name}){detail}");
        return 1;
    }
}

Console.WriteLine($"PASS: {tests.Length} actual Windows DPAPI storage acceptance groups.");
Console.WriteLine("Scope: local key durability and device-first commit ordering; no public VPN or two-file transaction attestation.");
return 0;

static void PendingRotationSurvivesSignOut()
{
    using var fixture = new StorageFixture();
    var pending = fixture.State with { PendingIdentity = fixture.IdentityB };
    var store = fixture.Open();
    store.Save(pending);
    Check(store.Load() == pending, "The encrypted authenticated state must round-trip before sign-out.");
    CheckRetained(store.LoadDevice(), pending);

    store.Clear();
    var reopened = fixture.Open();
    CheckSignedOut(reopened);
    CheckRetained(reopened.LoadDevice(), pending);
    Check(File.Exists(fixture.DevicePath), "Sign-out must preserve the independently encrypted device file.");
    Check(!File.Exists(fixture.SessionPath), "Sign-out must delete the encrypted session file.");
    reopened.Clear();
    CheckRetained(fixture.Open().LoadDevice(), pending);
}

static void AuthOnlySavePreservesRecoveredDevice()
{
    using var fixture = new StorageFixture();
    var pending = fixture.State with { PendingIdentity = fixture.IdentityB };
    var store = fixture.Open();
    store.Save(pending);
    store.Clear();
    var recovered = NativeDeviceState.FromClientState(fixture.State with { Identity = fixture.IdentityB });
    var reopened = fixture.Open();
    reopened.SaveDevice(recovered);
    CheckSignedOut(fixture.Open());
    Check(fixture.Open().LoadDevice() == recovered,
        "A separately acknowledged device key must be durable while no session exists.");

    var authOnly = fixture.State with
    {
        DeviceId = string.Empty,
        LocationId = string.Empty,
        VpnProvisioningPending = true,
    };
    reopened.Save(authOnly);
    var authReopened = fixture.Open();
    Check(authReopened.Load() == authOnly,
        "A resumed authentication session must remain explicitly unprovisioned.");
    Check(authReopened.LoadDevice() == recovered,
        "Saving authentication alone must not replace the recovered VPN device identity.");
    authReopened.Clear();
    CheckSignedOut(fixture.Open());
    Check(fixture.Open().LoadDevice() == recovered,
        "Clearing an unprovisioned authentication session must retain the recovered identity.");
}

static void ConfirmedRotationClearsPendingKey()
{
    using var fixture = new StorageFixture();
    var store = fixture.Open();
    store.Save(fixture.State with { PendingIdentity = fixture.IdentityB });
    var confirmed = fixture.State with { Identity = fixture.IdentityB, PendingIdentity = null };
    store.Save(confirmed);

    var reopened = fixture.Open();
    Check(reopened.Load() == confirmed, "The confirmed encrypted session must round-trip.");
    CheckRetained(reopened.LoadDevice(), confirmed);
    Check(reopened.LoadDevice()!.PendingIdentity is null,
        "A confirmed rotation must not retain the previous pending identity.");
    reopened.Clear();
    CheckSignedOut(fixture.Open());
    CheckRetained(fixture.Open().LoadDevice(), confirmed);
}

static void PendingKeySurvivesFailedSessionReplacement()
{
    using var fixture = new StorageFixture();
    var pending = fixture.State with { PendingIdentity = fixture.IdentityB };
    AssertSessionReplacementFailure(fixture, fixture.State, pending);
}

static void ConfirmedKeySurvivesFailedSessionReplacement()
{
    using var fixture = new StorageFixture();
    var pending = fixture.State with { PendingIdentity = fixture.IdentityB };
    var confirmed = fixture.State with { Identity = fixture.IdentityB, PendingIdentity = null };
    AssertSessionReplacementFailure(fixture, pending, confirmed);
}

static void AssertSessionReplacementFailure(StorageFixture fixture,
    NativeClientState previous, NativeClientState attempted)
{
    var store = fixture.Open();
    store.Save(previous);
    // A real Windows file handle without FileShare.Delete blocks only the final
    // client-state.bin replacement. The device's separate atomic writer runs
    // first and is neither mocked nor intercepted.
    using (var lockedSession = new FileStream(fixture.SessionPath, FileMode.Open,
        FileAccess.Read, FileShare.Read))
    {
        CheckStorageWriteFails(() => store.Save(attempted));
        CheckRetained(fixture.Open().LoadDevice(), attempted);
    }

    var reopened = fixture.Open();
    Check(reopened.Load() == previous,
        "A failed session replacement must preserve the previous authenticated state.");
    Check(!Directory.EnumerateFiles(fixture.DirectoryPath, "client-state.bin.new*").Any(),
        "A failed session replacement must remove its encrypted authentication temporary file.");
    CheckRetained(reopened.LoadDevice(), attempted);
    reopened.Clear();
    var signedOut = fixture.Open();
    CheckSignedOut(signedOut);
    Check(!Directory.EnumerateFiles(fixture.DirectoryPath, "client-state.bin.new*").Any(),
        "Sign-out must not leave an encrypted authentication temporary file.");
    CheckRetained(signedOut.LoadDevice(), attempted);
}

static void SessionRemnantsAreCleared()
{
    using var fixture = new StorageFixture();
    var store = fixture.Open();
    store.Save(fixture.State with { PendingIdentity = fixture.IdentityB });
    _ = store.GetOrCreateAsync(CancellationToken.None).GetAwaiter().GetResult();
    var deviceIdentityPath = Path.Combine(fixture.DirectoryPath, "device-identity.bin");
    var deviceIdentityBytes = File.ReadAllBytes(deviceIdentityPath);
    var sessionBytes = File.ReadAllBytes(fixture.SessionPath);
    var legacy = fixture.SessionPath + ".new";
    var owned = fixture.SessionPath + ".new-" + Guid.NewGuid().ToString("N");
    var unrelated = fixture.SessionPath + ".new-unrelated";
    var deviceTemporary = fixture.DevicePath + ".new-" + Guid.NewGuid().ToString("N");
    foreach (var path in new[] { legacy, owned })
        File.WriteAllBytes(path, sessionBytes);
    File.WriteAllText(unrelated, "unrelated fixture file");
    File.WriteAllBytes(deviceTemporary, File.ReadAllBytes(fixture.DevicePath));

    store.Clear();
    CheckSignedOut(fixture.Open());
    Check(!File.Exists(legacy) && !File.Exists(owned) &&
        File.Exists(unrelated) && File.Exists(deviceTemporary),
        "Logout must remove only its exact legacy and GUID-owned session remnants.");
    CheckRetained(fixture.Open().LoadDevice(), fixture.State with { PendingIdentity = fixture.IdentityB });
    Check(File.ReadAllBytes(deviceIdentityPath).AsSpan().SequenceEqual(deviceIdentityBytes),
        "Logout must preserve the independently encrypted device-signing identity exactly.");
}

static void LockedSessionRemnantPreventsLogout()
{
    foreach (var suffix in new[] { ".new", ".new-" + Guid.NewGuid().ToString("N") })
    {
        using var fixture = new StorageFixture();
        var store = fixture.Open();
        store.Save(fixture.State);
        var remnant = fixture.SessionPath + suffix;
        File.WriteAllBytes(remnant, File.ReadAllBytes(fixture.SessionPath));
        using (var lockedRemnant = new FileStream(remnant, FileMode.Open,
            FileAccess.Read, FileShare.Read))
        {
            CheckStorageWriteFails(store.Clear);
            Check(fixture.Open().Load() == fixture.State && File.Exists(remnant),
                "A refused authentication-remnant cleanup must preserve the current session and surface failure.");
            CheckRetained(fixture.Open().LoadDevice(), fixture.State);
        }
        store.Clear();
        CheckSignedOut(fixture.Open());
        Check(!File.Exists(remnant), "Logout retry must remove the previously locked session remnant.");
        CheckRetained(fixture.Open().LoadDevice(), fixture.State);
    }
}

static void FailedDeviceReplacementPreservesPreviousSession()
{
    using var fixture = new StorageFixture();
    var store = fixture.Open();
    store.Save(fixture.State);
    var oldSessionBytes = File.ReadAllBytes(fixture.SessionPath);
    try
    {
        using (var lockedDevice = new FileStream(fixture.DevicePath, FileMode.Open,
            FileAccess.Read, FileShare.Read))
        {
            CheckStorageWriteFails(() => store.Save(
                fixture.State with { PendingIdentity = fixture.IdentityB }));
        }

        Check(File.ReadAllBytes(fixture.SessionPath).AsSpan().SequenceEqual(oldSessionBytes),
            "A failed retained-device write must leave the authenticated session ciphertext untouched.");
        var reopened = fixture.Open();
        Check(reopened.Load() == fixture.State,
            "The authenticated state must remain unchanged when the first durable write fails.");
        CheckRetained(reopened.LoadDevice(), fixture.State);
        Check(!Directory.EnumerateFiles(fixture.DirectoryPath, "device-state.bin.new-*").Any(),
            "The actual atomic device writer must remove its failed temporary file.");
    }
    finally
    {
        CryptographicOperations.ZeroMemory(oldSessionBytes);
    }
}

static void LegacyDeviceRecordIsReadable()
{
    using var fixture = new StorageFixture();
    // This is the original on-disk JSON shape before UserId and PendingIdentity
    // were added. Encrypt it with the real format's CurrentUser DPAPI entropy
    // and persist it with the actual durable writer, never with a cleartext file.
    var legacy = new
    {
        fixture.State.InstallationId,
        fixture.State.DeviceId,
        fixture.State.LocationId,
        fixture.State.Identity,
    };
    var clearBytes = JsonSerializer.SerializeToUtf8Bytes(legacy);
    try
    {
        var protectedBytes = ProtectedData.Protect(clearBytes,
            Encoding.UTF8.GetBytes("VEX Windows client state v1"), DataProtectionScope.CurrentUser);
        ProtectedStateFileWriter.Write(fixture.DevicePath, protectedBytes);
    }
    finally
    {
        CryptographicOperations.ZeroMemory(clearBytes);
    }

    var reopened = fixture.Open();
    CheckSignedOut(reopened);
    var retained = reopened.LoadDevice();
    Check(retained is not null && retained.InstallationId == fixture.State.InstallationId &&
        retained.DeviceId == fixture.State.DeviceId && retained.LocationId == fixture.State.LocationId &&
        retained.Identity == fixture.IdentityA && retained.UserId is null && retained.PendingIdentity is null,
        "An encrypted legacy device record must preserve its existing key without inventing an owner or pending rotation.");
}

static void CheckRetained(NativeDeviceState? actual, NativeClientState expected)
{
    Check(actual is not null && actual.InstallationId == expected.InstallationId &&
        actual.DeviceId == expected.DeviceId && actual.LocationId == expected.LocationId &&
        actual.UserId == expected.Session.User.Id && actual.Identity == expected.Identity &&
        actual.PendingIdentity == expected.PendingIdentity,
        "The retained device must preserve its installation, device, location, owner, current key and pending key exactly.");
}

static void CheckSignedOut(ProtectedClientStateStore store)
{
    Check(store.GetAccessState() == ClientStateAccessKind.Missing && store.Load() is null,
        "A freshly reopened signed-out store must expose no authenticated session.");
}

static void CheckStorageWriteFails(Action write)
{
    try
    {
        write();
    }
    catch (Exception error) when (error is IOException or UnauthorizedAccessException)
    {
        return;
    }
    throw new StorageAssertionException("The actual Windows file replacement must fail while its destination is locked.");
}

static void Check(bool condition, string message)
{
    if (!condition) throw new StorageAssertionException(message);
}

sealed class StorageAssertionException(string message) : Exception(message);

sealed class StorageFixture : IDisposable
{
    public string DirectoryPath { get; } = Path.Combine(Path.GetTempPath(),
        "VEX.Windows.StorageAcceptance-" + Guid.NewGuid().ToString("N"));
    public string SessionPath => Path.Combine(DirectoryPath, "client-state.bin");
    public string DevicePath => Path.Combine(DirectoryPath, "device-state.bin");
    public WireGuardIdentity IdentityA { get; } = WireGuardIdentity.Generate(1);
    public WireGuardIdentity IdentityB { get; } = WireGuardIdentity.Generate(2);
    public NativeClientState State { get; }

    public StorageFixture()
    {
        if (Directory.Exists(DirectoryPath))
            throw new StorageAssertionException("Each storage fixture must start in a new isolated temporary directory.");
        Directory.CreateDirectory(DirectoryPath);
        State = new NativeClientState(
            new VexAuthSession(new VexUser("storage-test-owner", "storage-test@example.invalid", "active"),
                "isolated-storage-test-" + Guid.NewGuid().ToString("N"), DateTimeOffset.UtcNow.AddHours(1)),
            "storage-test-installation", "storage-test-device", "fi-storage-test", IdentityA);
    }

    public ProtectedClientStateStore Open() => new(stateDirectory: DirectoryPath);

    public void Dispose()
    {
        // This fixture never points to LocalApplicationData or existing user
        // state. Cleanup failures fail the case and cannot silently leak files.
        Directory.Delete(DirectoryPath, recursive: true);
    }
}
