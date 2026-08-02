using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Vex.Windows.Client.Auth;

namespace Vex.Windows.App.Auth;

public sealed class ProtectedPkceStateStore
{
    private static readonly byte[] Entropy =
        Encoding.UTF8.GetBytes("VEX Windows PKCE v1");

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = false,
    };

    private readonly string _stateFile;

    public ProtectedPkceStateStore()
    {
        var localData = Environment.GetFolderPath(
            Environment.SpecialFolder.LocalApplicationData);
        _stateFile = Path.Combine(
            localData,
            "VEX",
            "VPN",
            "pkce-state.bin");
    }

    public PendingPkceChallenge? Load()
    {
        if (!File.Exists(_stateFile))
        {
            return null;
        }

        var protectedValue = File.ReadAllBytes(_stateFile);
        var clearValue = ProtectedData.Unprotect(
            protectedValue,
            Entropy,
            DataProtectionScope.CurrentUser);
        try
        {
            return JsonSerializer.Deserialize<PendingPkceChallenge>(
                clearValue,
                JsonOptions);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clearValue);
        }
    }

    public void Save(PendingPkceChallenge pendingChallenge)
    {
        ArgumentNullException.ThrowIfNull(pendingChallenge);
        var clearValue = JsonSerializer.SerializeToUtf8Bytes(
            pendingChallenge,
            JsonOptions);
        try
        {
            var protectedValue = ProtectedData.Protect(
                clearValue,
                Entropy,
                DataProtectionScope.CurrentUser);
            Directory.CreateDirectory(Path.GetDirectoryName(_stateFile)!);
            File.WriteAllBytes(_stateFile, protectedValue);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clearValue);
        }
    }

    public void Clear()
    {
        if (File.Exists(_stateFile))
        {
            File.Delete(_stateFile);
        }
    }
}
