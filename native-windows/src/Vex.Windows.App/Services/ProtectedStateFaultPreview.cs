#if DEBUG
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Security;
using Vex.Windows.Client.Session;

namespace Vex.Windows.App.Services;

// Runs the compiled application's real CurrentUser DPAPI adapter, not an
// injected decryptor. Only sanitized diagnostics leave its disposable root.
internal static class ProtectedStateFaultPreview
{
    private const string Unusable = "Сохраненная сессия повреждена или недоступна для этого пользователя Windows. Выполните вход заново.";
    private const string Unavailable = "Сохраненные данные VEX недоступны. Проверьте доступ к папке приложения и повторите запуск.";
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("VEX Windows client state v1");
    private static readonly string[] PreservedFiles = ["client-state.bin", "vpn-account-identities.bin",
        "device-state.bin", "device-identity.bin", "installation-id.bin"];
    private static readonly List<CaseResult> Cases = [];
    private static Dictionary<string, string>? _startupFiles;
    private static bool _startupCompleted;
    internal static string ReceiptPath => Path.Combine(Path.GetTempPath(),
        $"vex-ui-preview-protected-state-{Environment.ProcessId}.json");

    private sealed record CaseResult(string id, bool passed, string outcome,
        bool files_preserved, bool reopened, bool recovered);

    internal static void Prepare(ProtectedClientStateStore startupStore)
    {
        Require(OperatingSystem.IsWindows() && UiPreviewContext.IsEnabled &&
            UiPreviewContext.IsProtectedStateFaultPreview && UiPreviewContext.StateDirectory is not null,
            "isolated-windows-mode-required");
        Require(!File.Exists(ReceiptPath) && !Directory.Exists(ReceiptPath), "receipt-already-exists");
        var root = UiPreviewContext.StateDirectory!;
        RunCase("dpapi-roundtrip", root, (store, state, directory) =>
        {
            var files = Snapshot(directory);
            Require(SameState(state, store.Load()) && SameState(state, NewStore(directory).Load()), "roundtrip-owner");
            Require(store.HasStoredSession && store.GetAccessState() == ClientStateAccessKind.Available &&
                store.StoredSessionError is null, "roundtrip-access");
            Require(Same(files, Snapshot(directory)), "roundtrip-files");
            return new("dpapi-roundtrip", true, "available", true, true, true);
        });
        ReadFault("invalid-ciphertext", root, (_, path) => File.WriteAllBytes(path, [1, 2, 3]));
        ReadFault("malformed-json", root, (_, path) => WriteClearMap(path, Encoding.UTF8.GetBytes("{")));
        ReadFault("invalid-owner-map", root, (_, path) => MutateMap(path, map =>
            map["Accounts"]!["fault-account-b"]!["UserId"] = "fault-account-a"));
        ReadFault("missing-map", root, (_, path) => File.Delete(path));
        ReadFault("missing-own-account", root, (_, path) => MutateMap(path, map =>
            map["Accounts"]!.AsObject().Remove("fault-account-b")));
        ReadFault("registration-mismatch", root, (_, path) => MutateMap(path, map =>
            map["Accounts"]!["fault-account-b"]!["RegistrationId"] = "different-registration"));
        ReadFault("external-id-mismatch", root, (_, path) => MutateMap(path, map =>
            map["Accounts"]!["fault-account-b"]!["ExternalDeviceId"] = "different-external"));
        ReadFault("map-sharing-violation", root, (_, _) => { }, unavailable: true, lockRead: true);
        ReadFault("map-path-is-directory", root, (_, path) =>
        {
            File.Delete(path);
            Directory.CreateDirectory(path);
        }, unavailable: true);
        RunCase("map-write-sharing-violation", root, (store, state, directory) =>
        {
            var files = Snapshot(directory);
            var rejected = false;
            using (var locked = new FileStream(MapPath(directory), FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                try { store.Save(state with { SelectionMode = "manual" }); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { rejected = true; }
            }
            Require(rejected && Same(files, Snapshot(directory)) &&
                !Directory.EnumerateFiles(directory, "*.new-*").Any(), "write-failure-preserved");
            Require(SameState(state, NewStore(directory).Load()), "write-failure-reopen");
            return new("map-write-sharing-violation", true, "write-unavailable", true, true, true);
        });
        RunCase("authoritative-key-restoration", root, (store, state, directory) =>
        {
            var existing = store.AccountVpnIdentities.Load(state.Session.User.Id)!;
            var replacement = WireGuardIdentity.Generate(2);
            store.AccountVpnIdentities.Replace(existing, existing with { Identity = replacement });
            var files = Snapshot(directory);
            foreach (var reopened in new[] { store, NewStore(directory) })
            {
                var restored = reopened.Load();
                Require(restored?.Session == state.Session && restored.Identity == replacement &&
                    restored.CachedProfileVersion is null && restored.CachedAuthorization is null &&
                    restored.CachedCandidateGrants is null && restored.CachedCandidatePolicyExpiresAt is null &&
                    restored.WarmedProfile is null, "authoritative-cache-restoration");
            }
            Require(Same(files, Snapshot(directory)), "authoritative-files");
            return new("authoritative-key-restoration", true, "authoritative", true, true, true);
        });

        // This is a separate store, never read after corruption. Its first
        // Load must come from actual AppServices/coordinator/window startup.
        Seed(startupStore);
        WriteClearMap(MapPath(root), Encoding.UTF8.GetBytes("{"));
        _startupFiles = Snapshot(root);
        WriteReceipt("matrix-completed", cleanupCompleted: false);
    }

    internal static void RecordStartup(AppServices services)
    {
        Require(services.MainWindow is not null && services.Coordinator.CurrentState is null &&
            services.Coordinator.CurrentStateAccess == ClientStateAccessKind.Missing &&
            services.StateStore.HasStoredSession && services.StateStore.StoredSessionError == Unusable &&
            Same(_startupFiles!, Snapshot(UiPreviewContext.StateDirectory!)), "corrupt-startup-fail-closed");
        _startupCompleted = true;
        WriteReceipt("startup-completed", cleanupCompleted: false);
    }

    internal static void RecordCleanup()
    {
        Require(_startupCompleted && !Directory.Exists(UiPreviewContext.StateDirectory), "owned-cleanup-incomplete");
        WriteReceipt("completed", cleanupCompleted: true);
    }

    private static void RunCase(string id, string root,
        Func<ProtectedClientStateStore, NativeClientState, string, CaseResult> check)
    {
        var directory = Path.Combine(root, "cases", id);
        var store = NewStore(directory);
        var state = Seed(store);
        Cases.Add(check(store, state, directory));
    }

    private static void ReadFault(string id, string root, Action<ProtectedClientStateStore, string> inject,
        bool unavailable = false, bool lockRead = false)
    {
        RunCase(id, root, (store, state, directory) =>
        {
            var path = MapPath(directory);
            var original = File.ReadAllBytes(path);
            inject(store, path);
            var files = Snapshot(directory);
            using (var locked = lockRead
                ? new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None) : null)
            {
                foreach (var reopened in new[] { store, NewStore(directory) })
                {
                    Require(reopened.Load() is null && reopened.HasStoredSession &&
                        reopened.GetAccessState() == ClientStateAccessKind.Missing && reopened.Load() is null &&
                        reopened.StoredSessionError == (unavailable ? Unavailable : Unusable), id + "-fail-closed");
                }
            }
            Require(Same(files, Snapshot(directory)) &&
                !Directory.EnumerateFiles(directory, "*.new-*").Any(), id + "-files-preserved");
            if (Directory.Exists(path)) Directory.Delete(path);
            File.WriteAllBytes(path, original);
            Require(store.Load() is null && SameState(state, NewStore(directory).Load()), id + "-fresh-recovery");
            return new(id, true, unavailable ? "unavailable" : "unusable", true, true, true);
        });
    }

    private static NativeClientState Seed(ProtectedClientStateStore store)
    {
        var now = DateTimeOffset.UtcNow;
        var installation = store.GetOrCreateInstallationId();
        _ = store.GetOrCreateAsync(CancellationToken.None).GetAwaiter().GetResult();
        var legacy = WireGuardIdentity.Generate();
        store.Save(new(new(new("fault-account-a", "a@example.test", "active"), "offline-fault-token-a", now.AddDays(1)),
            installation, "legacy-device-a", "de-frankfurt", legacy));
        store.AccountVpnIdentities.GetOrAdd(new("fault-account-a", "registration-a", "external-a", legacy));
        var identity = WireGuardIdentity.Generate();
        store.AccountVpnIdentities.GetOrAdd(new("fault-account-b", "registration-b", "external-b", identity));
        var authorization = new ManagedVpnProfileAuthorization("offline-fixture", "Ed25519", "AA==", "AA==");
        var state = new NativeClientState(new(new("fault-account-b", "b@example.test", "active"),
            "offline-fault-token-b", now.AddDays(1)), installation, "device-b", "de-frankfurt", identity,
            CachedProfileVersion: 17, CachedAuthorization: authorization, CachedCandidateGrants: [],
            CachedCandidatePolicyExpiresAt: now.AddMinutes(5),
            WarmedProfile: new("fault-account-b", "device-b", "de-frankfurt", "full", null,
                identity.PublicKey, identity.KeyEpoch, 17, authorization, now.AddMinutes(5)),
            VpnRegistrationId: "registration-b", VpnExternalDeviceId: "external-b");
        store.Save(state);
        return state;
    }

    private static bool SameState(NativeClientState expected, NativeClientState? actual) =>
        actual is not null && JsonSerializer.Serialize(expected) == JsonSerializer.Serialize(actual);

    private static ProtectedClientStateStore NewStore(string directory) => new(stateDirectory: directory);
    private static string MapPath(string directory) => Path.Combine(directory, "vpn-account-identities.bin");

    private static void MutateMap(string path, Action<JsonNode> mutate)
    {
        var clear = ProtectedData.Unprotect(File.ReadAllBytes(path), Entropy, DataProtectionScope.CurrentUser);
        try
        {
            var map = JsonNode.Parse(clear)!;
            mutate(map);
            WriteClearMap(path, JsonSerializer.SerializeToUtf8Bytes(map));
        }
        finally { CryptographicOperations.ZeroMemory(clear); }
    }

    private static void WriteClearMap(string path, byte[] clear)
    {
        try { File.WriteAllBytes(path, ProtectedData.Protect(clear, Entropy, DataProtectionScope.CurrentUser)); }
        finally { CryptographicOperations.ZeroMemory(clear); }
    }

    private static Dictionary<string, string> Snapshot(string directory) => PreservedFiles.ToDictionary(name => name, name =>
    {
        var path = Path.Combine(directory, name);
        return Directory.Exists(path) ? "directory" : File.Exists(path)
            ? Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))) : "missing";
    }, StringComparer.Ordinal);

    private static bool Same(Dictionary<string, string> expected, Dictionary<string, string> actual) =>
        expected.Count == actual.Count && expected.All(pair => actual.GetValueOrDefault(pair.Key) == pair.Value);

    private static void WriteReceipt(string stage, bool cleanupCompleted)
    {
        var value = JsonSerializer.Serialize(new
        {
            schema = "vex.windows.protected-state-faults.v1",
            process_id = Environment.ProcessId,
            mode = "protected-state-fault",
            stage,
            cases = Cases,
            case_count = Cases.Count,
            real_current_user_dpapi = true,
            startup_completed = _startupCompleted,
            startup_access = _startupCompleted ? "Missing" : null,
            startup_has_stored_session = _startupCompleted,
            startup_error_reported = _startupCompleted,
            startup_files_preserved = _startupCompleted,
            owned_directory_removed = cleanupCompleted,
        });
        Require(Encoding.UTF8.GetByteCount(value) <= 32768, "receipt-too-large");
        File.WriteAllText(ReceiptPath + ".tmp", value);
        File.Move(ReceiptPath + ".tmp", ReceiptPath, overwrite: true);
    }

    private static void Require(bool condition, string id)
    {
        if (!condition) throw new InvalidOperationException("Protected-state fixture failed: " + id);
    }
}
#endif
