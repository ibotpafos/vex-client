using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Vex.Windows.Setup;

internal static class WindowsPathGuard
{
    internal static void AssertDirectory(string path)
    {
        DirectoryInfo? current = new(Path.GetFullPath(path));
        while (current is not null)
        {
            if (!current.Exists || (current.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException("Setup inputs must be ordinary local paths.");
            current = current.Parent;
        }
    }

    internal static void AssertFile(string path)
    {
        var full = Path.GetFullPath(path);
        AssertDirectory(Path.GetDirectoryName(full)!);
        var attributes = File.GetAttributes(full);
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
            throw new InvalidDataException("Setup artifact must be an ordinary file.");
        using var stream = File.Open(full, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (!GetFileInformationByHandle(stream.SafeFileHandle, out var information))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        if (information.NumberOfLinks != 1) throw new InvalidDataException("Setup artifacts cannot be hard linked.");
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation information);

    [StructLayout(LayoutKind.Sequential)]
    private struct FileInformation
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }
}
