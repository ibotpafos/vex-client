using System.Net;
using System.Security.Cryptography;
using System.Text;

namespace Vex.Windows.Core.Vpn;

// Preserve the signed hostname/configuration separately from the numeric
// vendor file. Cold startup must not need DNS through a stopped tunnel or
// silently accept an address admitted for another peer, port or lease.
public static class VpnVendorStartupConfiguration
{
    public static string Materialize(string configuration, string expectedSha256,
        VpnEndpointAddressSnapshot? admittedEndpoint, DateTimeOffset authorizationExpiresAt,
        DateTimeOffset now)
    {
        VpnTunnelConfigurationValidator.Validate(configuration);
        if (authorizationExpiresAt <= now) { throw new VpnTunnelException("profile_expired"); }
        var actual = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(configuration)));
        if (!string.Equals(actual, expectedSha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new VpnTunnelException("tunnel_runtime_integrity_failure");
        }
        var endpoint = Value(configuration, "Endpoint") ??
            throw new VpnTunnelException("invalid_tunnel_configuration");
        var peer = Value(configuration, "PublicKey") ??
            throw new VpnTunnelException("invalid_tunnel_configuration");
        if (!VpnEndpointAddressCache.TryParseEndpoint(endpoint, out var host, out var port))
        {
            throw new VpnTunnelException("endpoint_invalid");
        }
        IPAddress selected;
        if (IPAddress.TryParse(host, out var literal)) { selected = literal; }
        else
        {
            if (admittedEndpoint is null || admittedEndpoint.ValidUntil <= now ||
                admittedEndpoint.ValidUntil != authorizationExpiresAt ||
                admittedEndpoint.ValidUntil - now > TimeSpan.FromHours(24) ||
                !string.Equals(admittedEndpoint.Endpoint, endpoint, StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(admittedEndpoint.ServerPublicKey, peer, StringComparison.Ordinal) ||
                admittedEndpoint.Addresses is not { Count: > 0 and <= 16 } ||
                !IPAddress.TryParse(admittedEndpoint.Addresses[0], out selected!))
            {
                throw new VpnTunnelException("endpoint_resolution_failed");
            }
        }
        var numericEndpoint = new IPEndPoint(selected, port).ToString();
        var ipv6 = (Value(configuration, "Address") ?? "").Split(',').Any(value => value.Contains(':'));
        var allowed = (Value(configuration, "AllowedIPs") ?? "").Split(',', StringSplitOptions.TrimEntries);
        var routes = VpnWindowsRouteMaterializer.Materialize(allowed, ipv6);
        var lines = configuration.Split('\n').Select(line =>
        {
            var key = line.Split('=', 2)[0].Trim();
            return key switch
            {
                "Endpoint" => "Endpoint = " + numericEndpoint,
                "AllowedIPs" => "AllowedIPs = " + string.Join(", ", routes),
                _ => line,
            };
        });
        var materialized = string.Join('\n', lines);
        VpnTunnelConfigurationValidator.Validate(materialized);
        return materialized;
    }

    private static string? Value(string configuration, string key) => configuration.Split('\n')
        .Select(line => line.Split('=', 2)).Where(parts => parts.Length == 2 && parts[0].Trim() == key)
        .Select(parts => parts[1].Trim()).SingleOrDefault();
}
