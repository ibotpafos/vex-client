namespace Vex.Windows.Service;

public sealed record WindowsServiceOptions(
    string DataDirectory,
    string InstallDirectory,
    string AuthorizationFile,
    string ClientCertificateSha256File,
    string OwnerSidFile,
    string AmneziaExecutableSha256File,
    string WintunSha256File,
    string ProfileSigningKeyringFile,
    string ProfileSigningKeyringSha256File)
{
    public const string ServiceName = "VEX VPN Service";
    public const string VendorServiceName = "AmneziaWGTunnel$vex";

    public static WindowsServiceOptions Load()
    {
        var programData = Environment.GetFolderPath(
            Environment.SpecialFolder.CommonApplicationData);
        var dataDirectory = Path.Combine(programData, "VEX", "VPN");
        var installDirectory = AppContext.BaseDirectory;

        return new WindowsServiceOptions(
            dataDirectory,
            installDirectory,
            Path.Combine(dataDirectory, "ipc-token.bin"),
            Path.Combine(dataDirectory, "client-cert-sha256"),
            Path.Combine(dataDirectory, "owner-sid"),
            Path.Combine(dataDirectory, "amneziawg-sha256"),
            Path.Combine(dataDirectory, "wintun-sha256"),
            Path.Combine(installDirectory, "profile-signing-keys.json"),
            Path.Combine(dataDirectory, "profile-signing-keys-sha256"));
    }
}
