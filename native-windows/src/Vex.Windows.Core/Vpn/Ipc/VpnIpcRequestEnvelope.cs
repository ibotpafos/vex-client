using System.Diagnostics;

namespace Vex.Windows.Core.Vpn.Ipc;

[DebuggerDisplay("{Request.Operation} {Request.RequestId}")]
public sealed record VpnIpcRequestEnvelope
{
    public VpnIpcRequestEnvelope(
        string authorization,
        VpnServiceRequest request)
    {
        ValidateAuthorization(authorization);
        ArgumentNullException.ThrowIfNull(request);

        Authorization = authorization;
        Request = request;
    }

    public string Authorization { get; }

    public VpnServiceRequest Request { get; }

    public override string ToString() =>
        $"{nameof(VpnIpcRequestEnvelope)} {{ Authorization = <redacted>, " +
        $"RequestId = {Request.RequestId}, Operation = {Request.Operation}, " +
        $"TunnelConfig = <redacted> }}";

    internal static void ValidateAuthorization(string value)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(value);
        if (value.Length is < 32 or > 128 ||
            value.Any(char.IsWhiteSpace))
        {
            throw new ArgumentException(
                "IPC authorization must contain 32-128 non-whitespace characters.",
                nameof(value));
        }
    }
}
