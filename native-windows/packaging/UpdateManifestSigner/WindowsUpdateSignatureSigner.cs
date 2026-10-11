using System.Security.Cryptography;

namespace Vex.Windows.Packaging;

internal static class WindowsUpdateSignatureSigner
{
    private const string P256Oid = "1.2.840.10045.3.1.7";

    internal static string SignBase64Payload(string payloadBase64, string privateKeyBase64,
        string shippingPublicKeyBase64)
    {
        byte[] privateKey = [];
        byte[] payload = [];
        byte[] publicKey = [];
        try
        {
            privateKey = Convert.FromBase64String(privateKeyBase64);
            payload = Convert.FromBase64String(payloadBase64);
            publicKey = Convert.FromBase64String(shippingPublicKeyBase64);
            return SignAndVerify(payload, privateKey, publicKey);
        }
        finally
        {
            // Also clear partially decoded input when a later Base64 field fails.
            CryptographicOperations.ZeroMemory(privateKey);
            CryptographicOperations.ZeroMemory(payload);
            CryptographicOperations.ZeroMemory(publicKey);
        }
    }

    // Takes ownership of the payload/private-key buffers and clears them on
    // both success and rejection. No signature is returned before verification.
    internal static string SignAndVerify(byte[] payload, byte[] privateKey, byte[] shippingPublicKey)
    {
        byte[] signature = [];
        try
        {
            using var signer = ECDsa.Create();
            int privateBytesRead;
            try
            {
                signer.ImportPkcs8PrivateKey(privateKey, out privateBytesRead);
            }
            catch (CryptographicException)
            {
                signer.ImportECPrivateKey(privateKey, out privateBytesRead);
            }
            if (privateBytesRead != privateKey.Length)
                throw new CryptographicException("The update private key contains trailing data.");
            RequireP256(signer);

            using var verifier = ECDsa.Create();
            verifier.ImportSubjectPublicKeyInfo(shippingPublicKey, out var publicBytesRead);
            if (publicBytesRead != shippingPublicKey.Length)
                throw new CryptographicException("The shipping update public key contains trailing data.");
            RequireP256(verifier);

            signature = signer.SignData(payload, HashAlgorithmName.SHA256,
                DSASignatureFormat.Rfc3279DerSequence);
            if (!verifier.VerifyData(payload, signature, HashAlgorithmName.SHA256,
                    DSASignatureFormat.Rfc3279DerSequence))
                throw new CryptographicException("The update private key does not match the shipping public key.");
            return Convert.ToBase64String(signature);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(privateKey);
            CryptographicOperations.ZeroMemory(payload);
            CryptographicOperations.ZeroMemory(signature);
        }
    }

    private static void RequireP256(ECDsa key)
    {
        var curve = key.ExportParameters(includePrivateParameters: false).Curve;
        if (!curve.IsNamed || !string.Equals(curve.Oid.Value, P256Oid, StringComparison.Ordinal))
            throw new CryptographicException("Windows update keys must use the named P-256 curve.");
    }
}
