using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Vex.Windows.Client.Security;

public interface IDeviceIdentityProvider
{
    Task<DeviceIdentity?> GetOrCreateAsync(
        CancellationToken cancellationToken);
}

public sealed class DeviceIdentity
{
    public const string KeyTypeP256Jwk = "p256_jwk";
    public const string TrustLevelSoftwareSecureStore =
        "software_secure_store";
    private const string PayloadVersion = "vex-device-binding-v1";

    private readonly byte[] _d;
    private readonly byte[] _x;
    private readonly byte[] _y;

    public DeviceIdentity(
        string publicKey,
        string trustLevel,
        byte[] d,
        byte[] x,
        byte[] y)
    {
        PublicKey = string.IsNullOrWhiteSpace(publicKey)
            ? throw new ArgumentException(
                "The device identity public key is required.",
                nameof(publicKey))
            : publicKey;
        TrustLevel = string.IsNullOrWhiteSpace(trustLevel)
            ? throw new ArgumentException(
                "The device identity trust level is required.",
                nameof(trustLevel))
            : trustLevel;
        _d = d.Length == 32
            ? d.ToArray()
            : throw new ArgumentException(
                "The device identity private scalar must be 32 bytes.",
                nameof(d));
        _x = x.Length == 32
            ? x.ToArray()
            : throw new ArgumentException(
                "The device identity public X coordinate must be 32 bytes.",
                nameof(x));
        _y = y.Length == 32
            ? y.ToArray()
            : throw new ArgumentException(
                "The device identity public Y coordinate must be 32 bytes.",
                nameof(y));
    }

    public string KeyType => KeyTypeP256Jwk;

    public string TrustLevel { get; }

    public string PublicKey { get; }

    public Task<string> SignAsync(
        string payload,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ArgumentException.ThrowIfNullOrWhiteSpace(payload);
        using var ecdsa = ECDsa.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            D = _d.ToArray(),
            Q = new ECPoint
            {
                X = _x.ToArray(),
                Y = _y.ToArray(),
            },
        });
        var signature = ecdsa.SignData(
            Encoding.UTF8.GetBytes(payload),
            HashAlgorithmName.SHA256,
            DSASignatureFormat.Rfc3279DerSequence);
        try
        {
            return Task.FromResult(Base64UrlEncode(signature));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(signature);
        }
    }

    public static string SignaturePayload(
        string challengeId,
        string challengeNonce,
        string challengePurpose,
        string installationId,
        string identityPublicKey,
        string wireGuardPublicKey) =>
        string.Join(
            "\n",
            [
                PayloadVersion,
                challengeId.Trim(),
                challengeNonce.Trim(),
                challengePurpose.Trim(),
                installationId.Trim(),
                identityPublicKey.Trim(),
                wireGuardPublicKey.Trim(),
            ]);

    public static DeviceIdentity Generate()
    {
        using var ecdsa = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var parameters = ecdsa.ExportParameters(true);
        return new DeviceIdentity(
            StablePublicJwk(parameters.Q.X!, parameters.Q.Y!),
            TrustLevelSoftwareSecureStore,
            parameters.D!,
            parameters.Q.X!,
            parameters.Q.Y!);
    }

    public static string StablePublicJwk(
        byte[] x,
        byte[] y) =>
        JsonSerializer.Serialize(
            new
            {
                kty = "EC",
                crv = "P-256",
                x = Base64UrlEncode(x),
                y = Base64UrlEncode(y),
            });

    public byte[] ExportPrivateScalar() => _d.ToArray();

    public byte[] ExportPublicX() => _x.ToArray();

    public byte[] ExportPublicY() => _y.ToArray();

    private static string Base64UrlEncode(byte[] value) =>
        Convert.ToBase64String(value)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
}
