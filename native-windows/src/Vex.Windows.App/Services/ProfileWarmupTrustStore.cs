using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using Vex.Windows.Core.Vpn;

namespace Vex.Windows.App.Services;

public static class ProfileWarmupTrustStore
{
    public static VpnSignedProfileVerifier? Load(string? keyringPath = null, string? protectedPinPath = null)
    {
        try
        {
            keyringPath ??= Path.Combine(AppContext.BaseDirectory, "profile-signing-keys.json");
            protectedPinPath ??= Path.Combine(Environment.GetFolderPath(
                Environment.SpecialFolder.CommonApplicationData), "VEX", "VPN", "profile-signing-keys-sha256");
            var keyringFile = new FileInfo(keyringPath);
            var pinFile = new FileInfo(protectedPinPath);
            if (!keyringFile.Exists || keyringFile.Length is < 1 or > 64 * 1024 ||
                !pinFile.Exists || pinFile.Length is < 64 or > 128) return null;
            var payload = File.ReadAllBytes(keyringFile.FullName);
            var expected = Convert.FromHexString(File.ReadAllText(pinFile.FullName).Trim());
            if (expected.Length != 32 || !CryptographicOperations.FixedTimeEquals(expected, SHA256.HashData(payload))) return null;
            var document = JsonSerializer.Deserialize<KeyringDocument>(payload, new JsonSerializerOptions
            {
                UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
            });
            if (document?.Schema != "vex.profile-signing-keyring.v1" || document.Keys is not { Count: >= 1 and <= 8 } ||
                document.Keys.Any(key => key is null)) return null;
            return new VpnSignedProfileVerifier(document.Keys.Select(key =>
                new VpnProfileSigningKey(key.KeyId, key.Algorithm, key.SubjectPublicKeyInfoBase64)));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or
            FormatException or ArgumentException or InvalidOperationException or CryptographicException) { return null; }
    }

    private sealed record KeyringDocument(
        [property: JsonPropertyName("schema")] string Schema,
        [property: JsonPropertyName("keys")] IReadOnlyList<KeyDocument> Keys);

    private sealed record KeyDocument(
        [property: JsonPropertyName("key_id")] string KeyId,
        [property: JsonPropertyName("algorithm")] string Algorithm,
        [property: JsonPropertyName("subject_public_key_info_base64")] string SubjectPublicKeyInfoBase64);
}
