using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using Vex.Windows.Core.Vpn;

namespace Vex.Windows.Service.Runtime;

// Mirror the pinned vendor installer's own-process/LocalSystem/Nsi+TcpIp/SID
// contract, with demand start and no implicit Start. A user stop or expired
// authorization must never be resurrected by SCM before the VEX controller.
internal static class OwnedVendorServiceRegistration
{
    private const uint ScManagerConnect = 1;
    private const uint ScManagerCreateService = 2;
    private const uint ServiceQueryConfig = 1;
    private const uint ServiceChangeConfig = 2;
    private const uint ServiceAllAccess = 0xF01FF;
    private const uint ServiceNoChange = uint.MaxValue;
    private const uint ServiceErrorNormal = 1;
    private const uint ServiceConfigServiceSidInfo = 5;
    private const int ErrorServiceDoesNotExist = 1060;

    internal static void Install(string executable, string configuration)
    {
        AssertSafePath(executable);
        AssertSafePath(configuration);
        using var manager = OpenSCManager(null, null, ScManagerConnect | ScManagerCreateService);
        RequireHandle(manager);
        using var service = CreateService(manager, WindowsServiceOptions.VendorServiceName,
            "AmneziaWG Tunnel: vex", ServiceAllAccess, VpnVendorServiceIdentity.OwnProcess,
            VpnVendorServiceIdentity.DemandStart, ServiceErrorNormal,
            $"\"{executable}\" /tunnelservice \"{configuration}\"", null, IntPtr.Zero,
            "Nsi\0TcpIp\0\0", null, null);
        RequireHandle(service);
        try
        {
            var sid = new ServiceSidInfo { SidType = VpnVendorServiceIdentity.UnrestrictedServiceSid };
            if (!ChangeServiceConfig2(service, ServiceConfigServiceSidInfo, ref sid)) { ThrowNative(); }
            AssertOwnedAndDemand(service, executable, configuration);
        }
        catch
        {
            // This handle belongs to our just-created, never-started Demand
            // service. Failure cannot leave an unqualified boot registration.
            _ = DeleteService(service);
            throw;
        }
    }

    internal static bool QualifyIfPresent(string executable, string configuration)
    {
        using var manager = OpenSCManager(null, null, ScManagerConnect);
        RequireHandle(manager);
        using var service = OpenService(manager, WindowsServiceOptions.VendorServiceName,
            ServiceQueryConfig | ServiceChangeConfig);
        if (service.IsInvalid)
        {
            if (Marshal.GetLastWin32Error() == ErrorServiceDoesNotExist) { return false; }
            ThrowNative();
        }
        AssertOwnedAndDemand(service, executable, configuration);
        return true;
    }

    private static void AssertOwnedAndDemand(ServiceHandle service, string executable, string configuration)
    {
        var current = Read(service);
        if (!VpnVendorServiceIdentity.Matches(ParseCommandLine(current.ImagePath), executable, configuration,
            current.ServiceType, current.StartType, current.Account, current.Dependencies, current.SidType))
        {
            throw new VpnTunnelException("tunnel_runtime_integrity_failure");
        }
        if (current.StartType != VpnVendorServiceIdentity.DemandStart)
        {
            if (!ChangeServiceConfig(service, ServiceNoChange, VpnVendorServiceIdentity.DemandStart,
                ServiceNoChange, null, null, IntPtr.Zero, null, null, null, null)) { ThrowNative(); }
            current = Read(service);
            if (current.StartType != VpnVendorServiceIdentity.DemandStart ||
                !VpnVendorServiceIdentity.Matches(ParseCommandLine(current.ImagePath), executable, configuration,
                    current.ServiceType, current.StartType, current.Account, current.Dependencies, current.SidType))
            {
                throw new VpnTunnelException("tunnel_runtime_integrity_failure");
            }
        }
    }

    private static Registration Read(ServiceHandle service)
    {
        _ = QueryServiceConfig(service, IntPtr.Zero, 0, out var needed);
        if (Marshal.GetLastWin32Error() != 122 || needed is < 1 or > 64 * 1024) { ThrowNative(); }
        var memory = Marshal.AllocHGlobal(checked((int)needed));
        try
        {
            if (!QueryServiceConfig(service, memory, needed, out _)) { ThrowNative(); }
            var value = Marshal.PtrToStructure<ServiceConfig>(memory);
            var dependencies = new List<string>();
            for (var offset = 0; ;)
            {
                var item = Marshal.PtrToStringUni(IntPtr.Add(value.Dependencies, offset));
                if (string.IsNullOrEmpty(item)) { break; }
                dependencies.Add(item);
                offset += checked((item.Length + 1) * 2);
                if (offset > needed) { throw new VpnTunnelException("tunnel_runtime_integrity_failure"); }
            }
            var sid = new ServiceSidInfo();
            if (!QueryServiceConfig2(service, ServiceConfigServiceSidInfo, ref sid,
                (uint)Marshal.SizeOf<ServiceSidInfo>(), out _)) { ThrowNative(); }
            return new Registration(Marshal.PtrToStringUni(value.BinaryPath) ?? "", value.ServiceType,
                value.StartType, Marshal.PtrToStringUni(value.Account) ?? "", dependencies, sid.SidType);
        }
        finally { Marshal.FreeHGlobal(memory); }
    }

    private static IReadOnlyList<string> ParseCommandLine(string commandLine)
    {
        if (commandLine.Length > 32 * 1024 || commandLine.Any(char.IsControl))
        { throw new VpnTunnelException("tunnel_runtime_integrity_failure"); }
        var arguments = CommandLineToArgv(commandLine, out var count);
        if (arguments == IntPtr.Zero) { ThrowNative(); }
        try
        {
            if (count != 3) { return []; }
            return Enumerable.Range(0, count).Select(index =>
                Marshal.PtrToStringUni(Marshal.ReadIntPtr(arguments, index * IntPtr.Size)) ?? "").ToArray();
        }
        finally { _ = LocalFree(arguments); }
    }

    private static void AssertSafePath(string path)
    {
        if (!Path.IsPathFullyQualified(path) || path.Contains('"') || path.Any(char.IsControl))
        { throw new VpnTunnelException("tunnel_runtime_integrity_failure"); }
    }

    private static void RequireHandle(ServiceHandle handle) { if (handle.IsInvalid) { ThrowNative(); } }
    private static void ThrowNative() => throw new Win32Exception(Marshal.GetLastWin32Error());
    private sealed record Registration(string ImagePath, uint ServiceType, uint StartType,
        string Account, IReadOnlyList<string> Dependencies, uint SidType);

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceConfig
    {
        public uint ServiceType, StartType, ErrorControl;
        public IntPtr BinaryPath, LoadOrderGroup;
        public uint TagId;
        public IntPtr Dependencies, Account, DisplayName;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceSidInfo { public uint SidType; }

    private sealed class ServiceHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public ServiceHandle() : base(true) { }
        protected override bool ReleaseHandle() => CloseServiceHandle(handle);
    }

    [DllImport("advapi32.dll", EntryPoint = "OpenSCManagerW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ServiceHandle OpenSCManager(string? machine, string? database, uint access);
    [DllImport("advapi32.dll", EntryPoint = "OpenServiceW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ServiceHandle OpenService(ServiceHandle manager, string name, uint access);
    [DllImport("advapi32.dll", EntryPoint = "CreateServiceW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ServiceHandle CreateService(ServiceHandle manager, string name, string displayName,
        uint access, uint serviceType, uint startType, uint errorControl, string binaryPath, string? loadOrderGroup,
        IntPtr tagId, string dependencies, string? account, string? password);
    [DllImport("advapi32.dll", EntryPoint = "ChangeServiceConfigW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ChangeServiceConfig(ServiceHandle service, uint serviceType, uint startType,
        uint errorControl, string? binaryPath, string? loadOrderGroup, IntPtr tagId, string? dependencies,
        string? account, string? password, string? displayName);
    [DllImport("advapi32.dll", EntryPoint = "ChangeServiceConfig2W", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ChangeServiceConfig2(ServiceHandle service, uint level, ref ServiceSidInfo info);
    [DllImport("advapi32.dll", EntryPoint = "QueryServiceConfigW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryServiceConfig(ServiceHandle service, IntPtr buffer, uint length, out uint needed);
    [DllImport("advapi32.dll", EntryPoint = "QueryServiceConfig2W", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryServiceConfig2(ServiceHandle service, uint level, ref ServiceSidInfo info,
        uint length, out uint needed);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseServiceHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteService(ServiceHandle handle);
    [DllImport("shell32.dll", EntryPoint = "CommandLineToArgvW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CommandLineToArgv(string commandLine, out int count);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
}
