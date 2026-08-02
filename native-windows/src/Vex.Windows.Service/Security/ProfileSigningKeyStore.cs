using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using Vex.Windows.Core.Vpn;

namespace Vex.Windows.Service.Security;

public sealed class ProfileSigningKeyStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    private readonly WindowsServiceOptions _options;

    public ProfileSigningKeyStore(WindowsServiceOptions options)
    {
        _options = options;
    }

    public VpnSignedProfileVerifier Load()
    {
        try
        {
            var keyringFile = new FileInfo(
                _options.ProfileSigningKeyringFile);
            if (!keyringFile.Exists ||
                keyringFile.Length is < 1 or > 64 * 1024)
            {
                throw InvalidKeyring();
            }

            var payload = File.ReadAllBytes(keyringFile.FullName);
            VerifyHash(payload);
            var document = JsonSerializer.Deserialize<KeyringDocument>(
                payload,
                JsonOptions) ?? throw InvalidKeyring();
            if (document.Schema != "vex.profile-signing-keyring.v1" ||
                document.Keys.Count is < 1 or > 8)
            {
                throw InvalidKeyring();
            }

            return new VpnSignedProfileVerifier(
                document.Keys.Select(key =>
                    new VpnProfileSigningKey(
                        key.KeyId,
                        key.Algorithm,
                        key.SubjectPublicKeyInfoBase64)));
        }
        catch (Exception error) when (
            error is IOException or
                UnauthorizedAccessException or
                JsonException or
                ArgumentException or
                CryptographicException)
        {
            throw InvalidKeyring(error);
        }
    }

    private void VerifyHash(byte[] payload)
    {
        try
        {
            var expected = Convert.FromHexString(
                File.ReadAllText(
                    _options.ProfileSigningKeyringSha256File).Trim());
            var actual = SHA256.HashData(payload);
            if (expected.Length != actual.Length ||
                !CryptographicOperations.FixedTimeEquals(expected, actual))
            {
                throw InvalidKeyring();
            }
        }
        catch (Exception error) when (
            error is IOException or FormatException)
        {
            throw InvalidKeyring(error);
        }
    }

    private static InvalidOperationException InvalidKeyring(
        Exception? innerException = null) =>
        new(
            "The pinned VPN profile signing keyring is invalid.",
            innerException);

    private sealed record KeyringDocument
    {
        [JsonPropertyName("schema")]
        public string Schema { get; init; } = string.Empty;

        [JsonPropertyName("keys")]
        public IReadOnlyList<KeyDocument> Keys { get; init; } = [];
    }

    private sealed record KeyDocument
    {
        [JsonPropertyName("key_id")]
        public string KeyId { get; init; } = string.Empty;

        [JsonPropertyName("algorithm")]
        public string Algorithm { get; init; } = string.Empty;

        [JsonPropertyName("subject_public_key_info_base64")]
        public string SubjectPublicKeyInfoBase64 { get; init; } =
            string.Empty;
    }
}
