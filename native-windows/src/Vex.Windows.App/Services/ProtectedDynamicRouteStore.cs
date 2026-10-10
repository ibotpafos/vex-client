using System.Security.Cryptography;
using System.Text;
using Vex.Windows.Client.Api;

namespace Vex.Windows.App.Services;

public sealed class ProtectedDynamicRouteStore : IDynamicRouteStore
{
    private static readonly byte[] Entropy = "VEX.Windows.DynamicRoutes.v1"u8.ToArray();
    private readonly string _directory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VEX", "VPN");

    public string? Read(string key)
    {
        try
        {
            var path = GetPath(key);
            if (!File.Exists(path)) { return null; }
            var clearValue = ProtectedData.Unprotect(File.ReadAllBytes(path), Entropy, DataProtectionScope.CurrentUser);
            try { return Encoding.UTF8.GetString(clearValue); }
            finally { CryptographicOperations.ZeroMemory(clearValue); }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or CryptographicException)
        {
            return null;
        }
    }

    public void Write(string key, string value)
    {
        var clearValue = Encoding.UTF8.GetBytes(value);
        try
        {
            var protectedValue = ProtectedData.Protect(clearValue, Entropy, DataProtectionScope.CurrentUser);
            Directory.CreateDirectory(_directory);
            var path = GetPath(key);
            var temporaryPath = path + ".new";
            File.WriteAllBytes(temporaryPath, protectedValue);
            File.Move(temporaryPath, path, overwrite: true);
        }
        finally { CryptographicOperations.ZeroMemory(clearValue); }
    }

    private string GetPath(string key) => Path.Combine(_directory,
        "dynamic-route-" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(key))) + ".dpapi");
}
