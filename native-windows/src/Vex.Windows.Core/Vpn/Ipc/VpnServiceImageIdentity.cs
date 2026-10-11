using System.Security.Cryptography;

namespace Vex.Windows.Core.Vpn.Ipc;

public sealed record VpnRegisteredServiceIdentity(
    uint ProcessId,
    uint CurrentState,
    uint ServiceType,
    string BinaryPath,
    string AccountName);

public static class VpnServiceImageIdentity
{
    public const string ExecutableName = "Vex.Windows.Service.exe";

    public static bool HasExpectedPaths(VpnRegisteredServiceIdentity service, uint pipeProcessId,
        string expectedPackageImage, string actualProcessImage)
    {
        // The privileged installer registers one LocalSystem own-process
        // executable, quoted with no arguments. A service from another package
        // must be repaired before the current application can send secrets.
        if (service is null || pipeProcessId == 0 || service.ProcessId != pipeProcessId ||
            service.CurrentState != 4 || service.ServiceType != 0x10 ||
            !string.Equals(service.AccountName, "LocalSystem", StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrWhiteSpace(service.BinaryPath) || string.IsNullOrWhiteSpace(expectedPackageImage) ||
            string.IsNullOrWhiteSpace(actualProcessImage)) { return false; }
        var command = service.BinaryPath.Trim();
        if (command.Length < 3 || command[0] != '"' || command[^1] != '"') { return false; }
        var registeredImage = command[1..^1];
        if (registeredImage.Contains('"') || registeredImage.Any(char.IsControl)) { return false; }
        try
        {
            if (!Path.IsPathFullyQualified(expectedPackageImage) ||
                !Path.IsPathFullyQualified(actualProcessImage) ||
                !Path.IsPathFullyQualified(registeredImage)) { return false; }
            var expected = Path.GetFullPath(expectedPackageImage);
            return Path.GetFileName(expected).Equals(ExecutableName, StringComparison.OrdinalIgnoreCase) &&
                expected.Equals(Path.GetFullPath(registeredImage), StringComparison.OrdinalIgnoreCase) &&
                expected.Equals(Path.GetFullPath(actualProcessImage), StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or IOException)
        {
            return false;
        }
    }

    public static bool HasExpectedHash(string? expectedSha256, ReadOnlySpan<byte> actualSha256)
    {
        if (expectedSha256 is not { Length: 64 } || actualSha256.Length != 32) { return false; }
        try
        {
            return CryptographicOperations.FixedTimeEquals(Convert.FromHexString(expectedSha256), actualSha256);
        }
        catch (FormatException) { return false; }
    }
}
