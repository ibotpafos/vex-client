namespace Vex.Windows.Core.Vpn;

public static class VpnVendorServiceIdentity
{
    public const uint OwnProcess = 16;
    public const uint AutomaticStart = 2;
    public const uint DemandStart = 3;
    public const uint UnrestrictedServiceSid = 1;

    public static bool Matches(IReadOnlyList<string> commandLine, string vendorExecutable,
        string configurationPath, uint serviceType, uint startType, string serviceAccount,
        IReadOnlyList<string> dependencies, uint serviceSidType) =>
        commandLine.Count == 3 &&
        string.Equals(commandLine[0], vendorExecutable, StringComparison.OrdinalIgnoreCase) &&
        commandLine[1] == "/tunnelservice" &&
        string.Equals(commandLine[2], configurationPath, StringComparison.OrdinalIgnoreCase) &&
        serviceType == OwnProcess && startType is AutomaticStart or DemandStart &&
        string.Equals(serviceAccount, "LocalSystem", StringComparison.OrdinalIgnoreCase) &&
        dependencies.Count == 2 && dependencies.ToHashSet(StringComparer.OrdinalIgnoreCase).SetEquals(["Nsi", "TcpIp"]) &&
        serviceSidType == UnrestrictedServiceSid;
}
