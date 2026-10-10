using Vex.Windows.Client.Session;

internal sealed class MemoryVpnAccountIdentityStore : IVpnAccountIdentityStore
{
    private string? _legacyOwner;
    private readonly Dictionary<string, NativeVpnAccountIdentity> _identities = new(StringComparer.Ordinal);
    public NativeVpnAccountIdentity? Load(string userId) { lock (_identities) return _identities.GetValueOrDefault(userId); }
    public NativeVpnAccountIdentity GetOrAdd(NativeVpnAccountIdentity identity, bool claimLegacyKey = false)
    {
        lock (_identities)
        {
            if (_identities.TryGetValue(identity.UserId, out var existing)) return existing;
            if (claimLegacyKey)
            {
                if (_legacyOwner is null) _legacyOwner = identity.UserId;
                else if (_legacyOwner != identity.UserId) identity = identity with {
                    Identity = Vex.Windows.Client.Security.WireGuardIdentity.Generate(checked(identity.Identity.KeyEpoch + 1)),
                    MigrationRotationPending = true };
            }
            _identities.Add(identity.UserId, identity);
            return identity;
        }
    }
    public void Replace(NativeVpnAccountIdentity expected, NativeVpnAccountIdentity replacement)
    {
        lock (_identities)
        {
            if (expected.UserId != replacement.UserId || _identities.GetValueOrDefault(expected.UserId) != expected)
                throw new InvalidOperationException("vpn_identity_changed");
            _identities[replacement.UserId] = replacement;
        }
    }
}
