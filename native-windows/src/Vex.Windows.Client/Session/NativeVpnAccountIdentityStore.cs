using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text.Json;
using Vex.Windows.Client.Security;
using Vex.Windows.Core.Presentation;

namespace Vex.Windows.Client.Session;

public sealed record NativeVpnAccountIdentity(string UserId, string RegistrationId,
    string ExternalDeviceId, WireGuardIdentity Identity, string? DeviceId = null,
    string? LocationId = null, WireGuardIdentity? PendingIdentity = null,
    bool MigrationRotationPending = false, bool LegacyRegistration = false);

public interface IVpnAccountIdentityStore
{
    NativeVpnAccountIdentity? Load(string userId);
    NativeVpnAccountIdentity GetOrAdd(NativeVpnAccountIdentity identity, bool claimLegacyKey = false);
    void Replace(NativeVpnAccountIdentity expected, NativeVpnAccountIdentity replacement);
}

// The production DPAPI adapter and portable fixtures use the same strict,
// atomic file implementation. Missing is the only state allowing creation.
public sealed class NativeVpnAccountIdentityFileStore : IVpnAccountIdentityStore
{
    private sealed record Envelope(int Version, Dictionary<string, NativeVpnAccountIdentity> Accounts, string? LegacyKeyOwner = null);
    private static readonly ConcurrentDictionary<string, object> Locks = new(StringComparer.OrdinalIgnoreCase);
    private readonly string _path;
    private readonly object _gate;
    private readonly Func<byte[], byte[]> _protect;
    private readonly Func<byte[], byte[]> _unprotect;

    public NativeVpnAccountIdentityFileStore(string path, Func<byte[], byte[]> protect,
        Func<byte[], byte[]> unprotect)
    {
        _path = Path.GetFullPath(path);
        _gate = Locks.GetOrAdd(_path, _ => new object());
        _protect = protect;
        _unprotect = unprotect;
    }

    public NativeVpnAccountIdentity? Load(string userId)
    {
        lock (_gate) return Read().Accounts.GetValueOrDefault(userId);
    }

    public NativeVpnAccountIdentity GetOrAdd(NativeVpnAccountIdentity identity, bool claimLegacyKey = false)
    {
        Validate(identity);
        lock (_gate)
        {
            var envelope = Read();
            if (envelope.Accounts.TryGetValue(identity.UserId, out var existing)) return existing;
            if (claimLegacyKey)
            {
                if (envelope.LegacyKeyOwner is null) envelope = envelope with { LegacyKeyOwner = identity.UserId };
                else if (envelope.LegacyKeyOwner != identity.UserId)
                    identity = identity with { Identity = WireGuardIdentity.Generate(checked(identity.Identity.KeyEpoch + 1)),
                        MigrationRotationPending = true };
            }
            envelope.Accounts.Add(identity.UserId, identity);
            Write(envelope);
            return identity;
        }
    }

    public void Replace(NativeVpnAccountIdentity expected, NativeVpnAccountIdentity replacement)
    {
        Validate(replacement);
        if (expected.UserId != replacement.UserId) throw new InvalidOperationException("vpn_account_changed");
        lock (_gate)
        {
            var envelope = Read();
            if (envelope.Accounts.GetValueOrDefault(expected.UserId) != expected)
                throw new InvalidOperationException("vpn_identity_changed");
            envelope.Accounts[replacement.UserId] = replacement;
            Write(envelope);
        }
    }

    private Envelope Read()
    {
        var result = ProtectedStateFileReader.Read<Envelope>(_path, bytes =>
        {
            var clear = _unprotect(bytes);
            try
            {
                using var json = JsonDocument.Parse(clear);
                var root = json.RootElement;
                if (root.ValueKind != JsonValueKind.Object ||
                    root.EnumerateObject().GroupBy(property => property.Name, StringComparer.Ordinal).Any(group => group.Count() > 1) ||
                    root.TryGetProperty("Accounts", out var accounts) && accounts.ValueKind == JsonValueKind.Object &&
                    accounts.EnumerateObject().GroupBy(property => property.Name, StringComparer.Ordinal).Any(group => group.Count() > 1))
                    throw new JsonException("Duplicate or invalid account VPN map.");
                return clear;
            }
            catch { CryptographicOperations.ZeroMemory(clear); throw; }
        },
            validate: envelope => envelope.Version == 1 && envelope.Accounts is not null &&
                (envelope.LegacyKeyOwner is null || !string.IsNullOrWhiteSpace(envelope.LegacyKeyOwner) &&
                    envelope.LegacyKeyOwner.Length <= 256 && envelope.Accounts.ContainsKey(envelope.LegacyKeyOwner)) &&
                envelope.Accounts.All(entry => entry.Key == entry.Value?.UserId && IsValid(entry.Value)));
        if (result.Error is not null)
            System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(result.Error).Throw();
        return result.Value ?? new(1, new(StringComparer.Ordinal));
    }

    private void Write(Envelope envelope)
    {
        var clear = JsonSerializer.SerializeToUtf8Bytes(envelope);
        try { ProtectedStateFileWriter.Write(_path, _protect(clear)); }
        finally { CryptographicOperations.ZeroMemory(clear); }
    }

    private static void Validate(NativeVpnAccountIdentity identity)
    {
        if (!IsValid(identity)) throw new JsonException("Invalid account VPN identity.");
    }

    private static bool IsValid(NativeVpnAccountIdentity? identity) => identity is not null &&
        !string.IsNullOrWhiteSpace(identity.UserId) && identity.UserId.Length <= 256 &&
        Identifier(identity.RegistrationId) && identity.ExternalDeviceId is not null &&
        identity.ExternalDeviceId.Split(':') is { Length: >= 1 and <= 2 } parts &&
        parts.All(Identifier) && Key(identity.Identity) &&
        (identity.PendingIdentity is null || Key(identity.PendingIdentity));

    private static bool Identifier(string? value) => !string.IsNullOrWhiteSpace(value) && value.Length <= 128 &&
        value.All(character => char.IsAsciiLetterOrDigit(character) || character is '-' or '_' or '.');
    private static bool Key(WireGuardIdentity? identity)
    {
        if (identity is null || identity.KeyEpoch < 1 || identity.PrivateKey is null || identity.PublicKey is null) return false;
        byte[]? privateKey = null;
        try
        {
            privateKey = Convert.FromBase64String(identity.PrivateKey);
            var publicKey = Convert.FromBase64String(identity.PublicKey);
            if (privateKey.Length != 32 || publicKey.Length != 32) return false;
            using var key = NSec.Cryptography.Key.Import(NSec.Cryptography.KeyAgreementAlgorithm.X25519,
                privateKey, NSec.Cryptography.KeyBlobFormat.RawPrivateKey);
            return CryptographicOperations.FixedTimeEquals(publicKey,
                key.PublicKey.Export(NSec.Cryptography.KeyBlobFormat.RawPublicKey));
        }
        catch (Exception error) when (error is FormatException or ArgumentException or CryptographicException) { return false; }
        finally { if (privateKey is not null) CryptographicOperations.ZeroMemory(privateKey); }
    }
}

public static class NativeVpnAccountIdentitySynchronization
{
    public static void Save(IVpnAccountIdentityStore store, NativeClientState state)
    {
        if (state.VpnProvisioningPending || state.VpnRegistrationId is null) return;
        var existing = store.Load(state.Session.User.Id) ?? throw new InvalidOperationException("vpn_identity_missing");
        if (existing.RegistrationId != state.VpnRegistrationId || existing.ExternalDeviceId != state.VpnExternalDeviceId)
            throw new InvalidOperationException("vpn_identity_changed");
        if (state.Identity != existing.Identity && state.Identity != existing.PendingIdentity)
            throw new InvalidOperationException("vpn_identity_changed");
        if (existing.PendingIdentity is not null && state.Identity != existing.PendingIdentity &&
            state.PendingIdentity != existing.PendingIdentity)
            throw new InvalidOperationException("vpn_identity_changed");
        store.Replace(existing, existing with { Identity = state.Identity, PendingIdentity = state.PendingIdentity,
            DeviceId = state.DeviceId, LocationId = state.LocationId });
    }

    public static NativeClientState Restore(IVpnAccountIdentityStore store, NativeClientState state)
    {
        if (state.VpnProvisioningPending || state.VpnRegistrationId is null) return state;
        var existing = store.Load(state.Session.User.Id) ?? throw new InvalidOperationException("vpn_identity_missing");
        if (existing.RegistrationId != state.VpnRegistrationId || existing.ExternalDeviceId != state.VpnExternalDeviceId)
            throw new InvalidOperationException("vpn_identity_changed");
        if (state.Identity == existing.Identity && state.PendingIdentity == existing.PendingIdentity) return state;
        return state with { Identity = existing.Identity, PendingIdentity = existing.PendingIdentity,
            CachedAuthorization = null, CachedProfileVersion = null, CachedCandidateGrants = null,
            CachedCandidatePolicyExpiresAt = null, WarmedProfile = null };
    }
}
