using System.Security.Cryptography;
using System.Text.Json;

namespace Vex.Windows.Core.Vpn;

// Installed by the elevated, verified bundle only. The current service image
// and router must both match this receipt; old installations omit it entirely.
public static class VpnRoutingCapability
{
    public static bool IsAvailable(string dataDirectory) {
        try {
            var path = Path.Combine(dataDirectory, "routing-capability.json");
            var info = new FileInfo(path);
            if (!info.Exists || info.Length > 4096 || info.Attributes.HasFlag(FileAttributes.ReparsePoint)) { return false; }
            var receipt = JsonSerializer.Deserialize<Receipt>(File.ReadAllBytes(path));
            if (receipt is null || receipt.Schema != "vex.native-routing.v2" || !Path.IsPathFullyQualified(receipt.InstallDirectory)) { return false; }
            return Matches(Path.Combine(receipt.InstallDirectory, "Vex.Windows.Service.exe"), receipt.ServiceSha256)
                && Matches(Path.Combine(receipt.InstallDirectory, "vex-awg.exe"), receipt.RouterSha256)
                && string.Equals(File.ReadAllText(Path.Combine(dataDirectory, "service-executable-sha256")).Trim(), receipt.ServiceSha256, StringComparison.OrdinalIgnoreCase)
                && string.Equals(File.ReadAllText(Path.Combine(dataDirectory, "router-sha256")).Trim(), receipt.RouterSha256, StringComparison.OrdinalIgnoreCase);
        } catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or ArgumentException) { return false; }
    }

    private static bool Matches(string path, string? expected) {
        var info = new FileInfo(path);
        if (!info.Exists || expected is not { Length: 64 } || info.Attributes.HasFlag(FileAttributes.ReparsePoint)) { return false; }
        using var file = File.OpenRead(path);
        return string.Equals(Convert.ToHexString(SHA256.HashData(file)), expected, StringComparison.OrdinalIgnoreCase);
    }

    public sealed record Receipt(string Schema, string InstallDirectory, string ServiceSha256, string RouterSha256);
}
