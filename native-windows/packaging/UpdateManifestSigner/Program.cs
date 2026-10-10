using System.Security.Cryptography;
using Vex.Windows.Packaging;

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

var publicKeyBase64 = Environment.GetEnvironmentVariable("VEX_WINDOWS_UPDATE_PUBLIC_KEY_BASE64");
if (string.IsNullOrWhiteSpace(publicKeyBase64)) return 5;

try
{
    var signature = WindowsUpdateSignatureSigner.SignBase64Payload(
        args[0], privateKeyBase64, publicKeyBase64);
    Console.WriteLine(signature);
    return 0;
}
catch (FormatException)
{
    return 4;
}
catch (CryptographicException)
{
    Console.Error.WriteLine("Windows update signing requires matching P-256 keys with complete valid encodings.");
    return 6;
}
