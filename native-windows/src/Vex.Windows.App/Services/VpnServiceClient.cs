using System.IO.Pipes;
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
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(50);

    private readonly ProtectedAuthorizationStore _authorizationStore;

    public VpnServiceClient(ProtectedAuthorizationStore authorizationStore)
    {
        _authorizationStore = authorizationStore;
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
        var stage = "initialize";
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        timeout.CancelAfter(RequestTimeout);

        try
        {
            await using var pipe = new NamedPipeClientStream(
                ".",
                VpnServiceProtocol.PipeName,
                PipeDirection.InOut,
                PipeOptions.Asynchronous | PipeOptions.WriteThrough,
                TokenImpersonationLevel.Identification);
            stage = "pipe_connect";
            await pipe.ConnectAsync(timeout.Token).ConfigureAwait(false);
            stage = "server_attestation";
            VpnServiceServerAttestor.Attest(pipe);
            stage = "authorization_read";
            var envelope = new VpnIpcRequestEnvelope(
                _authorizationStore.Read(),
                request);
            stage = "request_write";
            await VpnIpcFrameCodec.WriteRequestAsync(
                pipe,
                envelope,
                timeout.Token).ConfigureAwait(false);
            stage = "response_read";
            return await VpnIpcFrameCodec.ReadResponseAsync(
                pipe,
                timeout.Token).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            VpnServiceServerAttestor.LogFailure(
                new InvalidOperationException(
                    $"stage={stage}; {error.GetType().Name}: {error.Message}",
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
    private const uint ServiceQueryStatus = 0x0004;
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

        var expectedPath = Path.GetFullPath(
            Path.Combine(AppContext.BaseDirectory, ServiceExecutableName));
        if (!IsTrustedService(processId))
        {
            throw new UnauthorizedAccessException(
                "The VPN pipe is not owned by the registered service process.");
        }

        if (!HasValidAuthenticodeSignature(expectedPath))
        {
            throw new UnauthorizedAccessException(
                "The VPN service Authenticode signature is not valid.");
        }

        if (!HasPinnedAuthenticodeCertificate(expectedPath))
        {
            throw new UnauthorizedAccessException(
                "The VPN service signer certificate is not trusted.");
        }
    }

    private static bool IsTrustedService(uint processId)
    {
        using var manager = OpenSCManager(
            machineName: null,
            databaseName: null,
            ScManagerConnect);
        if (manager.IsInvalid)
        {
            return false;
        }

        using var service = OpenService(
            manager,
            ServiceName,
            ServiceQueryStatus);
        return !service.IsInvalid &&
            QueryServiceStatusEx(
                service,
                ScStatusProcessInfo,
                out var status,
                Marshal.SizeOf<ServiceStatusProcess>(),
                out _) &&
            status.ProcessId == processId &&
            status.CurrentState == ServiceRunning;
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

        // The full executable SHA-256 is verified separately. Reading the
        // embedded signer here avoids the ARM64 WinVerifyTrust marshaling
        // failure while preserving both binary and signer pinning.
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
        try
        {
            Marshal.StructureToPtr(fileInfo, fileInfoPointer, false);
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
            Marshal.FreeHGlobal(fileInfoPointer);
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeServerProcessId(
        SafePipeHandle pipe,
        out uint serverProcessId);

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
