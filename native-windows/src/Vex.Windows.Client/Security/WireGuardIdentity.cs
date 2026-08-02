using NSec.Cryptography;
using System.Security.Cryptography;

namespace Vex.Windows.Client.Security;

public sealed record WireGuardIdentity(
    string PrivateKey,
    string PublicKey,
    int KeyEpoch)
{
    public static WireGuardIdentity Generate(int keyEpoch = 1)
    {
        if (keyEpoch < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(keyEpoch));
        }

        var algorithm = KeyAgreementAlgorithm.X25519;
        var creation = new KeyCreationParameters
        {
            ExportPolicy = KeyExportPolicies.AllowPlaintextExport,
        };
        using var key = new Key(algorithm, creation);
        var privateKey = key.Export(KeyBlobFormat.RawPrivateKey);
        try
        {
            var publicKey = key.PublicKey.Export(
                KeyBlobFormat.RawPublicKey);
            return new WireGuardIdentity(
                Convert.ToBase64String(privateKey),
                Convert.ToBase64String(publicKey),
                keyEpoch);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(privateKey);
        }
    }
}
