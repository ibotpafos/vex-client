using System.Security.Cryptography;
using System.Text;

namespace Vex.Windows.Service.Security;

public sealed class ProtectedAuthorizationStore
{
    private static readonly byte[] Entropy =
        Encoding.UTF8.GetBytes("VEX VPN IPC v1");

    private readonly string _path;

    public ProtectedAuthorizationStore(WindowsServiceOptions options)
    {
        _path = options.AuthorizationFile;
    }

    public string Read()
    {
        if (!File.Exists(_path))
        {
            throw new InvalidOperationException(
                "The provisioned VPN IPC authorization file is missing.");
        }

        var protectedBytes = File.ReadAllBytes(_path);
        var clearBytes = ProtectedData.Unprotect(
            protectedBytes,
            Entropy,
            DataProtectionScope.LocalMachine);
        try
        {
            return Convert.ToBase64String(clearBytes);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clearBytes);
        }
    }
}
