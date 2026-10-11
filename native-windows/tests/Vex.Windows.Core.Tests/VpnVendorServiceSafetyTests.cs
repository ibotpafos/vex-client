using System.Security.Cryptography;
using Vex.Windows.Core.Vpn;

internal static class VpnVendorServiceSafetyTests
{
    public static readonly (string Name, Action Run)[] All =
    [
        ("Owned vendor recovery and stop remain available with a missing runtime DLL", () => DamagedFilesDoNotPreventStop("missing-dll")),
        ("Owned vendor recovery and stop remain available with a changed vendor image", () => DamagedFilesDoNotPreventStop("changed-image")),
        ("Owned vendor recovery and stop remain available with a missing image pin", () => DamagedFilesDoNotPreventStop("missing-pin")),
        ("Vendor startup still requires pinned runtime integrity and exact ownership", StartupRemainsQualified),
        ("Foreign vendor registration cannot receive stop or network cleanup", ForeignRegistrationCannotBeStopped),
    ];

    private static void DamagedFilesDoNotPreventStop(string damage)
    {
        using var fixture = new Fixture();
        fixture.Damage(damage);
        Rejected(() => VpnVendorServiceSafetyPolicy.QualifyForStartup(fixture.VerifyFiles, fixture.QualifyRegistration));
        Require(fixture.RegistrationChecks == 0 && fixture.Running && fixture.AuthorizationRetained,
            "Failed startup validation altered a running tunnel or authorization.");
        // Recovery first requalifies SCM ownership and can arm the existing
        // expiry callback even when the package cannot support a fresh start.
        VpnVendorServiceSafetyPolicy.QualifyForRecoveryOrStop(fixture.QualifyRegistration);
        fixture.StopAndRestore();
        Require(!fixture.Running && !fixture.AuthorizationRetained && fixture.RegistrationChecks == 2 && fixture.NetworkRestores == 1,
            "Damaged disk files prevented the owned process stop or its verified cleanup.");
    }

    private static void StartupRemainsQualified()
    {
        using var fixture = new Fixture();
        VpnVendorServiceSafetyPolicy.QualifyForStartup(fixture.VerifyFiles, fixture.QualifyRegistration);
        Require(fixture.FileChecks == 1 && fixture.RegistrationChecks == 1, "Startup bypassed an integrity or ownership check.");
        fixture.Owned = false;
        Rejected(() => VpnVendorServiceSafetyPolicy.QualifyForStartup(fixture.VerifyFiles, fixture.QualifyRegistration));
        Require(fixture.FileChecks == 2 && fixture.RegistrationChecks == 2 && fixture.Running,
            "A foreign registration was adopted during startup qualification.");
    }

    private static void ForeignRegistrationCannotBeStopped()
    {
        using var fixture = new Fixture { Owned = false };
        Rejected(fixture.StopAndRestore);
        Require(fixture.Running && fixture.AuthorizationRetained && fixture.NetworkRestores == 0 && fixture.RegistrationChecks == 1,
            "An unowned service was stopped or received network cleanup.");
    }

    private sealed class Fixture : IDisposable
    {
        private readonly string _directory = Path.Combine(Path.GetTempPath(), "vex-vendor-stop-fixture-" + Guid.NewGuid().ToString("N"));
        private string Image => Path.Combine(_directory, "amneziawg.exe");
        private string Dll => Path.Combine(_directory, "wintun.dll");
        private string Pin => Path.Combine(_directory, "amneziawg.sha256");
        public bool Owned { get; set; } = true;
        public bool Running { get; private set; } = true;
        public bool AuthorizationRetained { get; private set; } = true;
        public int RegistrationChecks { get; private set; }
        public int FileChecks { get; private set; }
        public int NetworkRestores { get; private set; }

        public Fixture()
        {
            Directory.CreateDirectory(_directory);
            File.WriteAllBytes(Image, [1, 2, 3]);
            File.WriteAllBytes(Dll, [4, 5, 6]);
            File.WriteAllText(Pin, Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(Image))));
        }

        public void Damage(string damage)
        {
            switch (damage)
            {
                case "missing-dll": File.Delete(Dll); break;
                case "changed-image": File.WriteAllBytes(Image, [7, 8, 9]); break;
                case "missing-pin": File.Delete(Pin); break;
                default: throw new InvalidOperationException("Unknown fixture damage.");
            }
        }

        public void VerifyFiles()
        {
            FileChecks++;
            if (!File.Exists(Image) || !File.Exists(Dll) || !File.Exists(Pin) ||
                !CryptographicOperations.FixedTimeEquals(Convert.FromHexString(File.ReadAllText(Pin)), SHA256.HashData(File.ReadAllBytes(Image))))
            { throw new VpnTunnelException("tunnel_runtime_integrity_failure"); }
        }

        public void QualifyRegistration()
        {
            RegistrationChecks++;
            if (!VpnVendorServiceIdentity.Matches([Image, "/tunnelservice", Path.Combine(_directory, "vex.conf")],
                Image, Path.Combine(_directory, "vex.conf"), 16, 3, Owned ? "LocalSystem" : "foreign", ["Nsi", "TcpIp"], 1))
            { throw new VpnTunnelException("tunnel_runtime_integrity_failure"); }
        }

        public void StopAndRestore() => VpnRuntimeLifetimePolicy.StopAndRestoreAsync(
            _ =>
            {
                VpnVendorServiceSafetyPolicy.QualifyForRecoveryOrStop(QualifyRegistration);
                Running = false;
                return Task.CompletedTask;
            },
            _ => { NetworkRestores++; return Task.CompletedTask; },
            () => !Running && NetworkRestores == 1,
            () => AuthorizationRetained = false, CancellationToken.None).GetAwaiter().GetResult();

        public void Dispose() => Directory.Delete(_directory, recursive: true);
    }

    private static void Rejected(Action action)
    {
        try { action(); }
        catch (VpnTunnelException error) when (error.Code == "tunnel_runtime_integrity_failure") { return; }
        throw new InvalidOperationException("Expected vendor qualification failure.");
    }
    private static void Require(bool condition, string message) { if (!condition) { throw new InvalidOperationException(message); } }
}
