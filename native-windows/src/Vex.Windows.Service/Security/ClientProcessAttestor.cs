using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.IO.Pipes;
using System.Security.Principal;
using Microsoft.Extensions.Logging;
using Microsoft.Win32.SafeHandles;

namespace Vex.Windows.Service.Security;

public sealed class ClientProcessAttestor
{
    private readonly string _installDirectory;
    private readonly byte[] _expectedCertificateHash;
    private readonly SecurityIdentifier _expectedOwnerSid;
    private readonly ILogger<ClientProcessAttestor> _logger;

    public ClientProcessAttestor(
        WindowsServiceOptions options,
        ILogger<ClientProcessAttestor> logger)
    {
        _installDirectory = Path.GetFullPath(options.InstallDirectory);
        _expectedCertificateHash = ReadCertificateHash(
            options.ClientCertificateSha256File);
        _expectedOwnerSid = new SecurityIdentifier(
            File.ReadAllText(options.OwnerSidFile).Trim());
        _logger = logger;
    }

    public bool IsAllowed(NamedPipeServerStream pipe)
    {
        if (!GetNamedPipeClientProcessId(
                pipe.SafePipeHandle,
                out var processId))
        {
            LogRejection("process_id_unavailable");
            return false;
        }

        try
        {
            using var process = Process.GetProcessById(checked((int)processId));
            if (!HasExpectedOwner(process))
            {
                LogRejection("owner_mismatch");
                return false;
            }
            var executable = process.MainModule?.FileName;
            if (executable is null)
            {
                LogRejection("process_path_unavailable");
                return false;
            }
            if (!IsApprovedPath(executable))
            {
                LogRejection("process_path_unapproved");
                return false;
            }
            if (!HasPinnedCertificate(executable))
            {
                LogRejection("signer_unapproved");
                return false;
            }

            return true;
        }
        catch (Exception error) when (
            error is ArgumentException
                or InvalidOperationException
                or System.ComponentModel.Win32Exception)
        {
            LogRejection("process_inspection_failed");
            return false;
        }
    }

    private void LogRejection(string reason) =>
        _logger.LogWarning(
            "VPN IPC client attestation failed with reason {Reason}.",
            reason);

    private bool HasExpectedOwner(Process process)
    {
        if (!OpenProcessToken(
                process.Handle,
                TokenAccessLevels.Query,
                out var token))
        {
            return false;
        }

        using (token)
        using (var identity = new WindowsIdentity(
            token.DangerousGetHandle()))
        {
            return identity.User is not null &&
                _expectedOwnerSid.Equals(identity.User);
        }
    }

    private bool IsApprovedPath(string executable)
    {
        var fullPath = Path.GetFullPath(executable);
        var relative = Path.GetRelativePath(_installDirectory, fullPath);
        return !Path.IsPathRooted(relative) &&
            !string.Equals(relative, "..", StringComparison.Ordinal) &&
            !relative.StartsWith(
                $"..{Path.DirectorySeparatorChar}",
                StringComparison.Ordinal) &&
            !relative.StartsWith(
                $"..{Path.AltDirectorySeparatorChar}",
                StringComparison.Ordinal) &&
            string.Equals(
                Path.GetFileName(fullPath),
                "Vex.Windows.App.exe",
                StringComparison.OrdinalIgnoreCase);
    }

    private bool HasPinnedCertificate(string executable)
    {
        try
        {
            if (!HasValidAuthenticodeSignature(executable))
            {
                return false;
            }

#pragma warning disable SYSLIB0057
            using var certificate = new X509Certificate2(
                X509Certificate.CreateFromSignedFile(executable));
#pragma warning restore SYSLIB0057
            var actualHash = certificate.GetCertHash(HashAlgorithmName.SHA256);
            return CryptographicOperations.FixedTimeEquals(
                _expectedCertificateHash,
                actualHash);
        }
        catch (CryptographicException)
        {
            return false;
        }
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

    private static byte[] ReadCertificateHash(string path)
    {
        var value = File.ReadAllText(path).Trim();
        if (value.Length != 64)
        {
            throw new InvalidOperationException(
                "The pinned client certificate SHA-256 is invalid.");
        }

        try
        {
            return Convert.FromHexString(value);
        }
        catch (FormatException error)
        {
            throw new InvalidOperationException(
                "The pinned client certificate SHA-256 is invalid.",
                error);
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeClientProcessId(
        SafePipeHandle pipe,
        out uint clientProcessId);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(
        IntPtr processHandle,
        TokenAccessLevels desiredAccess,
        out SafeAccessTokenHandle tokenHandle);

    private static Guid WinTrustActionGenericVerifyV2 =
        new("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");

    [DllImport("wintrust.dll", ExactSpelling = true, PreserveSig = true)]
    private static extern int WinVerifyTrust(
        IntPtr windowHandle,
        ref Guid actionId,
        ref WinTrustData trustData);

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
