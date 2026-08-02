using System.Security.Cryptography;
using System.Text;

namespace Vex.Windows.App.Services;

public sealed class ProtectedAuthorizationStore
{
    private static readonly byte[] Entropy =
        Encoding.UTF8.GetBytes("VEX VPN IPC v1");

    private readonly string _authorizationFile;

    public ProtectedAuthorizationStore()
    {
        var programData = Environment.GetFolderPath(
            Environment.SpecialFolder.CommonApplicationData);
        _authorizationFile = Path.Combine(
            programData,
            "VEX",
            "VPN",
            "ipc-token.bin");
    }

    public string Read()
    {
        var protectedToken = File.ReadAllBytes(_authorizationFile);
        var clearToken = ProtectedData.Unprotect(
            protectedToken,
            Entropy,
            DataProtectionScope.LocalMachine);
        try
        {
            return Convert.ToBase64String(clearToken);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clearToken);
        }
    }
}
