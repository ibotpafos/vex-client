using System.Security.Cryptography;

if (args.Length != 1)
{
    return 2;
}

var privateKeyBase64 = Environment.GetEnvironmentVariable(
    "VEX_WINDOWS_UPDATE_PRIVATE_KEY_BASE64");
if (string.IsNullOrWhiteSpace(privateKeyBase64))
{
    return 3;
}

byte[] privateKey;
byte[] payload;
try
{
    privateKey = Convert.FromBase64String(privateKeyBase64);
    payload = Convert.FromBase64String(args[0]);
}
catch (FormatException)
{
    return 4;
}

using var ecdsa = ECDsa.Create();
try
{
    try
    {
        ecdsa.ImportPkcs8PrivateKey(privateKey, out _);
    }
    catch (CryptographicException)
    {
        ecdsa.ImportECPrivateKey(privateKey, out _);
    }

    var signature = ecdsa.SignData(
        payload,
        HashAlgorithmName.SHA256,
        DSASignatureFormat.Rfc3279DerSequence);
    Console.WriteLine(Convert.ToBase64String(signature));
    CryptographicOperations.ZeroMemory(signature);
    return 0;
}
finally
{
    CryptographicOperations.ZeroMemory(privateKey);
    CryptographicOperations.ZeroMemory(payload);
}
