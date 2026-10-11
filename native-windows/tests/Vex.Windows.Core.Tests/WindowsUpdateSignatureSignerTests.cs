using System.Security.Cryptography;
using System.Text;
using Vex.Windows.Packaging;

internal static class WindowsUpdateSignatureSignerTests
{
    public static void Run()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        using var differentKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        using var p384 = ECDsa.Create(ECCurve.NamedCurves.nistP384);
        var originalPayload = Encoding.UTF8.GetBytes("{\"schema\":\"vex.windows-update-manifest.v1\"}");
        foreach (var privateKey in new[] { key.ExportPkcs8PrivateKey(), key.ExportECPrivateKey() })
        {
            var payload = originalPayload.ToArray();
            var signature = Convert.FromBase64String(WindowsUpdateSignatureSigner.SignAndVerify(
                payload, privateKey, key.ExportSubjectPublicKeyInfo()));
            Require(key.VerifyData(originalPayload, signature, HashAlgorithmName.SHA256,
                DSASignatureFormat.Rfc3279DerSequence),
                "Both supported private-key formats must produce a DER SHA-256 signature verified by the shipping key.");
            RequireCleared(payload, privateKey);
            CryptographicOperations.ZeroMemory(signature);
        }

        Reject(key.ExportPkcs8PrivateKey(), differentKey.ExportSubjectPublicKeyInfo(), originalPayload,
            "A valid private key paired with a different valid shipping public key must be rejected.");
        Reject(p384.ExportPkcs8PrivateKey(), p384.ExportSubjectPublicKeyInfo(), originalPayload,
            "Even a matching P-384 key pair must be rejected by the P-256 release contract.");
        Reject(p384.ExportPkcs8PrivateKey(), key.ExportSubjectPublicKeyInfo(), originalPayload,
            "An unsupported private-key curve must be rejected.");
        Reject(key.ExportPkcs8PrivateKey(), p384.ExportSubjectPublicKeyInfo(), originalPayload,
            "An unsupported shipping public-key curve must be rejected.");

        foreach (var privateKey in new[] { key.ExportPkcs8PrivateKey(), key.ExportECPrivateKey() })
        {
            var trailingKey = new byte[privateKey.Length + 1];
            privateKey.CopyTo(trailingKey, 0);
            CryptographicOperations.ZeroMemory(privateKey);
            Reject(trailingKey, key.ExportSubjectPublicKeyInfo(), originalPayload,
                "A valid private-key encoding followed by trailing bytes must be rejected.");
        }
        var publicKey = key.ExportSubjectPublicKeyInfo();
        var trailingPublicKey = new byte[publicKey.Length + 1];
        publicKey.CopyTo(trailingPublicKey, 0);
        Reject(key.ExportPkcs8PrivateKey(), trailingPublicKey, originalPayload,
            "A valid SPKI encoding followed by trailing bytes must be rejected.");
        Reject([0x30, 0x01, 0x00], publicKey, originalPayload,
            "A malformed private key must be rejected without retaining input buffers.");
        Reject(key.ExportPkcs8PrivateKey(), [0x30, 0x01, 0x00], originalPayload,
            "A malformed SPKI public key must be rejected without retaining input buffers.");

        // secp256k1 has the same key size as P-256, but a different named curve.
        // Import rejection on providers that lack it is also a valid rejection.
        const string secp256k1Point =
            "79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798" +
            "483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8";
        var secp256k1PublicKey = Convert.FromHexString(
            "3056301006072A8648CE3D020106052B8104000A03420004" + secp256k1Point);
        Reject(key.ExportPkcs8PrivateKey(), secp256k1PublicKey, originalPayload,
            "A different 256-bit curve must not pass a size-only key check.");
        var secp256k1PrivateKey = Convert.FromHexString(
            "30740201010420" +
            "0000000000000000000000000000000000000000000000000000000000000001" +
            "A00706052B8104000AA14403420004" + secp256k1Point);
        Reject(secp256k1PrivateKey, secp256k1PublicKey, originalPayload,
            "Even a matching pair on another 256-bit curve must be rejected.");

        foreach (var field in new[] { "payload", "private", "public" })
        {
            var privateKey = key.ExportPkcs8PrivateKey();
            try
            {
                var rejected = false;
                try
                {
                    WindowsUpdateSignatureSigner.SignBase64Payload(
                        field == "payload" ? "invalid!" : Convert.ToBase64String(originalPayload),
                        field == "private" ? "invalid!" : Convert.ToBase64String(privateKey),
                        field == "public" ? "invalid!" : Convert.ToBase64String(publicKey));
                }
                catch (FormatException) { rejected = true; }
                Require(rejected, "Malformed Base64 in any signer input must be rejected.");
            }
            finally { CryptographicOperations.ZeroMemory(privateKey); }
        }
        CryptographicOperations.ZeroMemory(originalPayload);
    }

    private static void Reject(byte[] privateKey, byte[] publicKey, byte[] originalPayload, string message)
    {
        var payload = originalPayload.ToArray();
        var rejected = false;
        try { WindowsUpdateSignatureSigner.SignAndVerify(payload, privateKey, publicKey); }
        catch (CryptographicException) { rejected = true; }
        Require(rejected, message);
        RequireCleared(payload, privateKey);
    }

    private static void RequireCleared(byte[] payload, byte[] privateKey) =>
        Require(payload.All(value => value == 0) && privateKey.All(value => value == 0),
            "The signer must clear its payload/private-key buffers after success or rejection.");

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
