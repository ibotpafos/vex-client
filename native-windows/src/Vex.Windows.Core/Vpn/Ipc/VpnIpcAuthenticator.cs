using System.Security.Cryptography;
using System.Text;

namespace Vex.Windows.Core.Vpn.Ipc;

public sealed class VpnIpcAuthenticator
{
    private readonly byte[] _expectedHash;

    public VpnIpcAuthenticator(string expectedAuthorization)
    {
        VpnIpcRequestEnvelope.ValidateAuthorization(expectedAuthorization);
        _expectedHash = Hash(expectedAuthorization);
    }

    public bool Verify(string candidate)
    {
        try
        {
            VpnIpcRequestEnvelope.ValidateAuthorization(candidate);
        }
        catch (ArgumentException)
        {
            return false;
        }

        var candidateHash = Hash(candidate);
        return CryptographicOperations.FixedTimeEquals(
            _expectedHash,
            candidateHash);
    }

    private static byte[] Hash(string value) =>
        SHA256.HashData(Encoding.UTF8.GetBytes(value));
}
