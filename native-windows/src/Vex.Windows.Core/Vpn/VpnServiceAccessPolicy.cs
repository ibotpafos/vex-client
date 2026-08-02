namespace Vex.Windows.Core.Vpn;

public static class VpnServiceAccessPolicy
{
    public static bool IsAuthorized(VpnServiceRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);

        return request.Operation != VpnServiceOperation.Connect ||
            request.ProfileAuthorization is not null &&
            !string.IsNullOrWhiteSpace(request.LocalPrivateKey) &&
            request.LocationId is null &&
            request.TunnelConfig is null;
    }
}
