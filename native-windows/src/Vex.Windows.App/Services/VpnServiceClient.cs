using System.IO.Pipes;
using System.Text;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
using Vex.Windows.Core.Vpn;
using Vex.Windows.Core.Vpn.Ipc;
using Vex.Windows.Client.Session;

namespace Vex.Windows.App.Services;

public sealed class VpnServiceClient : IVpnControlClient
{
    private readonly VpnNamedPipeTransport _transport;

    public VpnServiceClient(ProtectedAuthorizationStore authorizationStore)
    {
        // Production always uses the fixed service pipe and mandatory signed
        // SCM server attestation. Fixture transport dependencies cannot enter here.
        _transport = new VpnNamedPipeTransport(VpnServiceProtocol.PipeName,
            VpnServiceServerAttestor.Attest, authorizationStore.Read);
    }

    public Task<VpnServiceResponse> GetStatusAsync(
        CancellationToken cancellationToken) =>
        SendAsync(
            VpnServiceRequest.Status(NewRequestId()),
            cancellationToken);

    public Task<VpnServiceResponse> ConnectAsync(
        VpnProfileAuthorization profileAuthorization,
        string localPrivateKey,
        CancellationToken cancellationToken) =>
        ConnectAsync(
            profileAuthorization,
            localPrivateKey,
            antiLeakEnabled: true,
            cancellationToken);

    public Task<VpnServiceResponse> ConnectAsync(
        VpnProfileAuthorization profileAuthorization,
        string localPrivateKey,
        bool antiLeakEnabled,
        CancellationToken cancellationToken) =>
        SendAsync(
            VpnServiceRequest.TrustedConnect(
                NewRequestId(),
                profileAuthorization,
                localPrivateKey,
                antiLeakEnabled),
            cancellationToken);

    public Task<VpnServiceResponse> DisconnectAsync(
        CancellationToken cancellationToken) =>
        SendAsync(
            VpnServiceRequest.Disconnect(NewRequestId()),
            cancellationToken);

    public Task<VpnServiceResponse> GetDiagnosticsAsync(
        CancellationToken cancellationToken) =>
        SendAsync(
            VpnServiceRequest.Diagnostics(NewRequestId()),
            cancellationToken);

    public Task<VpnServiceResponse> SetAntiLeakAsync(
        bool enabled,
        CancellationToken cancellationToken) =>
        SendAsync(
            VpnServiceRequest.SetAntiLeak(NewRequestId(), enabled),
            cancellationToken);

    private async Task<VpnServiceResponse> SendAsync(
        VpnServiceRequest request,
        CancellationToken cancellationToken)
    {
        if (UiPreviewContext.IsEnabled)
            return UiPreviewFixtures.ServiceResponse(request);
        try
        {
            return await _transport.SendAsync(request, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            VpnServiceServerAttestor.LogFailure(
                new InvalidOperationException(
                    $"VPN IPC failed with {error.GetType().Name}: {error.Message}",
                    error));
            throw;
        }
    }

    private static string NewRequestId() =>
        Guid.NewGuid().ToString("N");
}

internal static class VpnServiceServerAttestor
{
    private const string ServiceName = "VEX VPN Service";
    private const string ServiceExecutableName = "Vex.Windows.Service.exe";
    private const uint ScManagerConnect = 0x0001;
    private const uint ServiceQueryConfig = 0x0001;
    private const uint ServiceQueryStatus = 0x0004;
    private const uint ProcessQueryLimitedInformation = 0x1000;
    private const int ScStatusProcessInfo = 0;
    private const uint ServiceRunning = 4;
    private static readonly Guid WinTrustActionGenericVerifyV2 =
        new("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");

    public static void LogFailure(Exception error)
    {
        try
        {
            var directory = Path.Combine(
                Environment.GetFolderPath(
                    Environment.SpecialFolder.LocalApplicationData),
                "VEX",
                "VPN");
            Directory.CreateDirectory(directory);
            File.WriteAllText(
                Path.Combine(directory, "service-attestation.log"),
                $"{DateTimeOffset.UtcNow:O} " +
                $"{error.GetType().Name}: {error.Message}");
        }
        catch
        {
            // Diagnostics must never hide the original attestation failure.
        }
    }

    public static void Attest(NamedPipeClientStream pipe)
    {
        if (!OperatingSystem.IsWindows() ||
            !GetNamedPipeServerProcessId(pipe.SafePipeHandle, out var processId))
        {
            throw new UnauthorizedAccessException(
                "The VPN service identity could not be established.");
        }

        using var manager = OpenSCManager(null, null, ScManagerConnect);
        using var service = manager.IsInvalid
            ? throw new UnauthorizedAccessException("The registered VPN service could not be queried.")
            : OpenService(manager, ServiceName, ServiceQueryStatus | ServiceQueryConfig);
        if (service.IsInvalid)
        {
            throw new UnauthorizedAccessException("The registered VPN service could not be queried.");
        }
        using var process = OpenProcess(ProcessQueryLimitedInformation, false, processId);
        if (process.IsInvalid)
        {
            throw new UnauthorizedAccessException("The VPN service process image could not be established.");
        }
        var actualImage = ReadProcessImage(process);
        var expectedImage = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, ServiceExecutableName));
        if (!VpnServiceImageIdentity.HasExpectedPaths(ReadRegisteredService(service), processId,
            expectedImage, actualImage))
        {
            throw new UnauthorizedAccessException(
                "The VPN pipe is not owned by the installed service image.");
        }

        // Keep the verified image open without write/delete sharing until all
        // signature and registration checks complete. Never authenticate a
        // companion file while a different process owns the actual pipe.
        using var executable = new FileStream(actualImage, FileMode.Open, FileAccess.Read, FileShare.Read);
        var actualHash = SHA256.HashData(executable);
        if (!VpnServiceImageIdentity.HasExpectedHash(
            ReadMachinePin("ServiceExecutableSha256", "service-executable-sha256"), actualHash))
        {
            throw new UnauthorizedAccessException("The VPN service image does not match its installed release.");
        }
        if (!HasValidAuthenticodeSignature(actualImage))
        {
            throw new UnauthorizedAccessException(
                "The VPN service Authenticode signature is not valid.");
        }

        if (!HasPinnedAuthenticodeCertificate(actualImage))
        {
            throw new UnauthorizedAccessException(
                "The VPN service signer certificate is not trusted.");
        }
        if (!GetNamedPipeServerProcessId(pipe.SafePipeHandle, out var currentProcessId) ||
            currentProcessId != processId ||
            !VpnServiceImageIdentity.HasExpectedPaths(ReadRegisteredService(service), processId,
                expectedImage, ReadProcessImage(process)) ||
            !VpnServiceImageIdentity.HasExpectedHash(
                ReadMachinePin("ServiceExecutableSha256", "service-executable-sha256"), actualHash))
        {
            throw new UnauthorizedAccessException("The VPN service identity changed during attestation.");
        }
    }

    private static string ReadProcessImage(SafeProcessHandle process)
    {
        var path = new StringBuilder(32768);
        var length = (uint)path.Capacity;
        if (!QueryFullProcessImageName(process, 0, path, ref length) || length == 0)
        {
            throw new UnauthorizedAccessException("The VPN service process image could not be established.");
        }
        return path.ToString();
    }

    private static VpnRegisteredServiceIdentity ReadRegisteredService(SafeServiceHandle service)
    {
        if (!QueryServiceStatusEx(service, ScStatusProcessInfo, out var status,
            Marshal.SizeOf<ServiceStatusProcess>(), out _) || status.CurrentState != ServiceRunning)
        {
            throw new UnauthorizedAccessException("The registered VPN service is not running.");
        }
        _ = QueryServiceConfig(service, IntPtr.Zero, 0, out var required);
        if (required is < 1 or > 64 * 1024)
        {
            throw new UnauthorizedAccessException("The registered VPN service configuration could not be queried.");
        }
        var buffer = Marshal.AllocHGlobal(checked((int)required));
        try
        {
            if (!QueryServiceConfig(service, buffer, required, out _))
            {
                throw new UnauthorizedAccessException("The registered VPN service configuration could not be queried.");
            }
            var configuration = Marshal.PtrToStructure<ServiceConfiguration>(buffer);
            if (configuration.ServiceType != status.ServiceType)
            {
                throw new UnauthorizedAccessException("The registered VPN service type changed during attestation.");
            }
            return new VpnRegisteredServiceIdentity(status.ProcessId, status.CurrentState, configuration.ServiceType,
                Marshal.PtrToStringUni(configuration.BinaryPathName) ?? string.Empty,
                Marshal.PtrToStringUni(configuration.ServiceStartName) ?? string.Empty);
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    private static bool HasPinnedAuthenticodeCertificate(string executable)
    {
        var expectedText = ReadMachinePin(
            "ClientCertificateSha256",
            "client-cert-sha256");
        if (expectedText.Length != 64)
        {
            return false;
        }

        byte[] expected;
        try
        {
            expected = Convert.FromHexString(expectedText);
        }
        catch (FormatException)
        {
            return false;
        }

        // Inspect the signer of the same process image whose release hash and
        // complete Authenticode signature were verified above.
#pragma warning disable SYSLIB0057
        using var certificate = new X509Certificate2(
            X509Certificate.CreateFromSignedFile(executable));
#pragma warning restore SYSLIB0057
        var actual = certificate.GetCertHash(HashAlgorithmName.SHA256);
        return CryptographicOperations.FixedTimeEquals(expected, actual);
    }

    private static string ReadMachinePin(
        string registryName,
        string legacyFileName)
    {
        using var localMachine = RegistryKey.OpenBaseKey(
            RegistryHive.LocalMachine,
            RegistryView.Registry64);
        using var key = localMachine.OpenSubKey(
            @"SOFTWARE\VEX\VPN",
            writable: false);
        if (key?.GetValue(registryName) is string registryValue &&
            !string.IsNullOrWhiteSpace(registryValue))
        {
            return registryValue.Trim();
        }

        var programData = Environment.GetFolderPath(
            Environment.SpecialFolder.CommonApplicationData);
        return File.ReadAllText(
            Path.Combine(
                programData,
                "VEX",
                "VPN",
                legacyFileName)).Trim();
    }

    private static bool HasValidAuthenticodeSignature(string executable)
    {
        var fileInfo = new WinTrustFileInfo(executable);
        var fileInfoPointer = Marshal.AllocHGlobal(Marshal.SizeOf(fileInfo));
        var marshalled = false;
        try
        {
            Marshal.StructureToPtr(fileInfo, fileInfoPointer, false);
            marshalled = true;
            var trustData = WinTrustData.ForFile(fileInfoPointer);
            var action = WinTrustActionGenericVerifyV2;
            var result = WinVerifyTrust(
                IntPtr.Zero,
                ref action,
                ref trustData);
            trustData.StateAction = WinTrustDataStateAction.Close;
            _ = WinVerifyTrust(IntPtr.Zero, ref action, ref trustData);
            return result == 0;
        }
        finally
        {
            if (marshalled) { Marshal.DestroyStructure<WinTrustFileInfo>(fileInfoPointer); }
            Marshal.FreeHGlobal(fileInfoPointer);
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeServerProcessId(
        SafePipeHandle pipe,
        out uint serverProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern SafeProcessHandle OpenProcess(uint desiredAccess,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandle, uint processId);

    [DllImport("kernel32.dll", EntryPoint = "QueryFullProcessImageNameW", CharSet = CharSet.Unicode,
        SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryFullProcessImageName(SafeProcessHandle process, uint flags,
        StringBuilder executableName, ref uint size);

    [DllImport(
        "advapi32.dll",
        EntryPoint = "OpenSCManagerW",
        CharSet = CharSet.Unicode,
        SetLastError = true)]
    private static extern SafeServiceHandle OpenSCManager(
        string? machineName,
        string? databaseName,
        uint desiredAccess);

    [DllImport(
        "advapi32.dll",
        EntryPoint = "OpenServiceW",
        CharSet = CharSet.Unicode,
        SetLastError = true)]
    private static extern SafeServiceHandle OpenService(
        SafeServiceHandle serviceControlManager,
        string serviceName,
        uint desiredAccess);

    [DllImport("advapi32.dll", EntryPoint = "QueryServiceConfigW", CharSet = CharSet.Unicode,
        SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryServiceConfig(SafeServiceHandle service, IntPtr configuration,
        uint bufferSize, out uint bytesNeeded);

    [DllImport(
        "advapi32.dll",
        EntryPoint = "QueryServiceStatusEx",
        SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryServiceStatusEx(
        SafeServiceHandle service,
        int infoLevel,
        out ServiceStatusProcess buffer,
        int bufferSize,
        out int bytesNeeded);

    [DllImport("advapi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseServiceHandle(IntPtr serviceHandle);

    [DllImport("wintrust.dll", ExactSpelling = true, PreserveSig = true)]
    private static extern int WinVerifyTrust(
        IntPtr windowHandle,
        ref Guid actionId,
        ref WinTrustData trustData);

    private sealed class SafeServiceHandle :
        SafeHandleZeroOrMinusOneIsInvalid
    {
        private SafeServiceHandle()
            : base(ownsHandle: true)
        {
        }

        protected override bool ReleaseHandle() =>
            CloseServiceHandle(handle);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceStatusProcess
    {
        public uint ServiceType;
        public uint CurrentState;
        public uint ControlsAccepted;
        public uint Win32ExitCode;
        public uint ServiceSpecificExitCode;
        public uint CheckPoint;
        public uint WaitHint;
        public uint ProcessId;
        public uint ServiceFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceConfiguration
    {
        public uint ServiceType;
        public uint StartType;
        public uint ErrorControl;
        public IntPtr BinaryPathName;
        public IntPtr LoadOrderGroup;
        public uint TagId;
        public IntPtr Dependencies;
        public IntPtr ServiceStartName;
        public IntPtr DisplayName;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private sealed class WinTrustFileInfo
    {
        public WinTrustFileInfo(string filePath)
        {
            Size = (uint)Marshal.SizeOf<WinTrustFileInfo>();
            FilePath = filePath;
        }

        public uint Size;
        public string FilePath;
        public IntPtr FileHandle;
        public IntPtr KnownSubject;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WinTrustData
    {
        public uint Size;
        public IntPtr PolicyCallbackData;
        public IntPtr SipClientData;
        public uint UiChoice;
        public uint RevocationChecks;
        public uint UnionChoice;
        public IntPtr FileInfo;
        public uint StateAction;
        public IntPtr StateData;
        public IntPtr UrlReference;
        public uint ProviderFlags;
        public uint UiContext;

        public static WinTrustData ForFile(IntPtr fileInfo) =>
            new()
            {
                Size = (uint)Marshal.SizeOf<WinTrustData>(),
                UiChoice = 2,
                RevocationChecks = 1,
                UnionChoice = 1,
                FileInfo = fileInfo,
                StateAction = WinTrustDataStateAction.Verify,
                ProviderFlags = 0x00000080,
            };
    }

    private static class WinTrustDataStateAction
    {
        public const uint Verify = 1;
        public const uint Close = 2;
    }
}
