using System.Diagnostics;

namespace Vex.Windows.Core.Vpn;

public static class VpnServiceProtocol
{
    public const int CurrentVersion = 2;
    public const string PipeName = "VexVpn.Service.v2";
}

public enum VpnServiceOperation
{
    Status,
    Connect,
    Disconnect,
    Diagnostics,
    SetAntiLeak,
}

[DebuggerDisplay("{Operation} {RequestId} protocol={ProtocolVersion}")]
public sealed record VpnServiceRequest
{
    public VpnServiceRequest(
        string requestId,
        int protocolVersion,
        VpnServiceOperation operation,
        string? locationId,
        string? tunnelConfig,
        VpnProfileAuthorization? profileAuthorization,
        string? localPrivateKey,
        DateTimeOffset? authorizationExpiresAt = null,
        bool? antiLeakEnabled = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(requestId);
        if (protocolVersion != VpnServiceProtocol.CurrentVersion)
        {
            throw new ArgumentOutOfRangeException(
                nameof(protocolVersion),
                protocolVersion,
                $"Only VPN service protocol {VpnServiceProtocol.CurrentVersion} is supported.");
        }

        if (operation == VpnServiceOperation.Connect)
        {
            var hasMaterializedProfile =
                !string.IsNullOrWhiteSpace(locationId) &&
                !string.IsNullOrWhiteSpace(tunnelConfig) &&
                profileAuthorization is null &&
                localPrivateKey is null;
            var hasSignedProfile =
                locationId is null &&
                tunnelConfig is null &&
                profileAuthorization is not null &&
                !string.IsNullOrWhiteSpace(localPrivateKey);
            if (!hasMaterializedProfile && !hasSignedProfile)
            {
                throw new ArgumentException(
                    "Connect requires exactly one trusted profile representation.");
            }
        }
        else if (operation == VpnServiceOperation.SetAntiLeak)
        {
            if (antiLeakEnabled is null ||
                locationId is not null ||
                tunnelConfig is not null ||
                profileAuthorization is not null ||
                localPrivateKey is not null ||
                authorizationExpiresAt is not null)
            {
                throw new ArgumentException(
                    "SetAntiLeak requires only the enabled flag.");
            }
        }
        else if (locationId is not null ||
                 tunnelConfig is not null ||
                 profileAuthorization is not null ||
                 localPrivateKey is not null ||
                 authorizationExpiresAt is not null ||
                 antiLeakEnabled is not null)
        {
            throw new ArgumentException(
                $"{operation} requests cannot include VPN profile material.");
        }

        RequestId = requestId;
        ProtocolVersion = protocolVersion;
        Operation = operation;
        LocationId = locationId;
        TunnelConfig = tunnelConfig;
        ProfileAuthorization = profileAuthorization;
        LocalPrivateKey = localPrivateKey;
        AuthorizationExpiresAt = authorizationExpiresAt;
        AntiLeakEnabled = antiLeakEnabled;
    }

    public string RequestId { get; }

    public int ProtocolVersion { get; }

    public VpnServiceOperation Operation { get; }

    public string? LocationId { get; }

    public string? TunnelConfig { get; }

    public VpnProfileAuthorization? ProfileAuthorization { get; }

    public string? LocalPrivateKey { get; }

    public DateTimeOffset? AuthorizationExpiresAt { get; }

    public bool? AntiLeakEnabled { get; }

    public static VpnServiceRequest Connect(
        string requestId,
        string locationId,
        string tunnelConfig,
        DateTimeOffset? authorizationExpiresAt = null,
        bool antiLeakEnabled = true)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(requestId);
        ArgumentException.ThrowIfNullOrWhiteSpace(locationId);
        ArgumentException.ThrowIfNullOrWhiteSpace(tunnelConfig);

        return new VpnServiceRequest(
            requestId,
            VpnServiceProtocol.CurrentVersion,
            VpnServiceOperation.Connect,
            locationId,
            tunnelConfig,
            profileAuthorization: null,
            localPrivateKey: null,
            authorizationExpiresAt,
            antiLeakEnabled);
    }

    public static VpnServiceRequest TrustedConnect(
        string requestId,
        VpnProfileAuthorization profileAuthorization,
        string localPrivateKey,
        bool antiLeakEnabled = true) =>
        new(
            requestId,
            VpnServiceProtocol.CurrentVersion,
            VpnServiceOperation.Connect,
            locationId: null,
            tunnelConfig: null,
            profileAuthorization,
            localPrivateKey,
            authorizationExpiresAt: null,
            antiLeakEnabled);

    public static VpnServiceRequest Status(string requestId) =>
        WithoutPayload(requestId, VpnServiceOperation.Status);

    public static VpnServiceRequest Disconnect(string requestId) =>
        WithoutPayload(requestId, VpnServiceOperation.Disconnect);

    public static VpnServiceRequest Diagnostics(string requestId) =>
        WithoutPayload(requestId, VpnServiceOperation.Diagnostics);

    public static VpnServiceRequest SetAntiLeak(
        string requestId,
        bool enabled) =>
        new(
            requestId,
            VpnServiceProtocol.CurrentVersion,
            VpnServiceOperation.SetAntiLeak,
            locationId: null,
            tunnelConfig: null,
            profileAuthorization: null,
            localPrivateKey: null,
            authorizationExpiresAt: null,
            antiLeakEnabled: enabled);

    public override string ToString() =>
        $"{nameof(VpnServiceRequest)} {{ RequestId = {RequestId}, " +
        $"ProtocolVersion = {ProtocolVersion}, Operation = {Operation}, " +
        $"LocationId = {LocationId}, TunnelConfig = <redacted>, " +
        $"ProfileAuthorization = <redacted>, LocalPrivateKey = <redacted> }}";

    private static VpnServiceRequest WithoutPayload(
        string requestId,
        VpnServiceOperation operation) =>
        new(
            requestId,
            VpnServiceProtocol.CurrentVersion,
            operation,
            locationId: null,
            tunnelConfig: null,
            profileAuthorization: null,
            localPrivateKey: null);
}

public sealed record VpnServiceResponse
{
    public VpnServiceResponse(
        string requestId,
        bool success,
        VpnConnectionSnapshot snapshot,
        string? errorCode)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(requestId);
        ArgumentNullException.ThrowIfNull(snapshot);

        if (success && errorCode is not null)
        {
            throw new ArgumentException(
                "A successful VPN service response cannot include an error code.",
                nameof(errorCode));
        }

        if (!success)
        {
            ArgumentException.ThrowIfNullOrWhiteSpace(errorCode);
        }

        RequestId = requestId;
        Success = success;
        Snapshot = snapshot;
        ErrorCode = errorCode;
    }

    public string RequestId { get; }

    public bool Success { get; }

    public VpnConnectionSnapshot Snapshot { get; }

    public string? ErrorCode { get; }

    public VpnTunnelDiagnostics? Diagnostics => Snapshot.Diagnostics;
}
