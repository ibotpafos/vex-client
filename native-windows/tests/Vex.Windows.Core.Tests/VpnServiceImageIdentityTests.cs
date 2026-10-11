using System.Security.Cryptography;
using Vex.Windows.Core.Vpn.Ipc;

internal static class VpnServiceImageIdentityTests
{
    private static readonly string PackageImage = Path.GetFullPath(Path.Combine(
        Path.GetTempPath(), "VEX current package", VpnServiceImageIdentity.ExecutableName));
    private static readonly byte[] Digest = SHA256.HashData("installed-service-fixture"u8);

    public static readonly (string Name, Action Run)[] All =
    [
        ("Pipe server image attestation binds SCM and the actual PID image to the installed package", ActualServerImageMustMatch),
        ("A stale service package is rejected until verified upgrade repair", PreviousPackageIsRejected),
        ("Pipe server attestation rejects unquoted and argument-bearing SCM commands", AmbiguousScmCommandsAreRejected),
        ("Pipe server attestation requires the running LocalSystem own-process registration", ScmProcessScopeIsExact),
        ("Pipe server attestation rejects missing or malformed privileged service pins", InvalidHashesFailClosed),
        ("Pipe server attestation checks the actual image digest against the release pin", ActualImageDigestMustMatch),
        ("Revalidation rejects service image changes during signature verification", RegistrationChangesAreRejected),
    ];

    private static VpnRegisteredServiceIdentity InstalledService() =>
        new(314, 4, 0x10, '"' + PackageImage + '"', "LocalSystem");

    private static bool Matches(VpnRegisteredServiceIdentity service, string actualImage = "") =>
        VpnServiceImageIdentity.HasExpectedPaths(service, 314, PackageImage,
            actualImage.Length == 0 ? PackageImage : actualImage);

    private static void ActualServerImageMustMatch()
    {
        var service = InstalledService();
        Require(Matches(service), "The correctly provisioned installed server was rejected.");
        var foreignImage = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "foreign service", VpnServiceImageIdentity.ExecutableName));
        Require(!Matches(service, foreignImage), "A trusted companion file substituted for a different actual server image.");
        Require(!Matches(service with { BinaryPath = '"' + foreignImage + '"' }, foreignImage),
            "An unrelated SCM image substituted for the current package.");
        Require(!Matches(service, Path.Combine(Path.GetDirectoryName(PackageImage)!, "other.exe")),
            "An unrelated process in the package directory was admitted.");
    }

    private static void PreviousPackageIsRejected()
    {
        var previous = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "VEX previous package", VpnServiceImageIdentity.ExecutableName));
        var service = InstalledService() with { BinaryPath = '"' + previous + '"' };
        Require(!Matches(service, previous), "A previous package remained admitted after the UI package changed.");
        Require(Matches(InstalledService()), "Verified repair to the current package did not restore admission.");
    }

    private static void AmbiguousScmCommandsAreRejected()
    {
        foreach (var command in new[]
        {
            PackageImage,
            '"' + PackageImage + "\" --replacement",
            "\"relative\\Vex.Windows.Service.exe\"",
            "\"\"",
            "\"" + PackageImage + "\" \"ignored\"",
            "\"" + PackageImage + "\n\"",
        })
        {
            Require(!Matches(InstalledService() with { BinaryPath = command }),
                "An ambiguous or argument-bearing SCM image command was admitted.");
        }
        Require(Matches(InstalledService() with { BinaryPath = "  \"" + PackageImage + "\"  " }),
            "Harmless whitespace outside the exact quoted image changed its identity.");
    }

    private static void ScmProcessScopeIsExact()
    {
        var service = InstalledService();
        foreach (var changed in new[]
        {
            service with { ProcessId = 0 }, service with { ProcessId = 315 },
            service with { CurrentState = 3 }, service with { CurrentState = 1 },
            service with { ServiceType = 0x20 }, service with { ServiceType = 0x110 },
            service with { AccountName = "LocalService" }, service with { AccountName = "fixture-user" },
            service with { AccountName = "" }, service with { BinaryPath = "" },
        })
        {
            Require(!Matches(changed), "SCM process, state, account or service-type scope was not enforced.");
        }
        Require(!VpnServiceImageIdentity.HasExpectedPaths(service, 0, PackageImage, PackageImage),
            "An unavailable pipe server PID was admitted.");
    }

    private static void InvalidHashesFailClosed()
    {
        foreach (var pin in new string?[]
        {
            null, "", new('0', 63), new('0', 65), new('g', 64), " " + Convert.ToHexString(Digest),
        })
        {
            Require(!VpnServiceImageIdentity.HasExpectedHash(pin, Digest), "A missing or malformed privileged service hash was admitted.");
        }
        Require(!VpnServiceImageIdentity.HasExpectedHash(Convert.ToHexString(Digest), Digest.AsSpan(0, 31)) &&
            !VpnServiceImageIdentity.HasExpectedHash(Convert.ToHexString(Digest), [.. Digest, 0]),
            "A non-SHA256 actual digest was accepted.");
    }

    private static void ActualImageDigestMustMatch()
    {
        Require(VpnServiceImageIdentity.HasExpectedHash(Convert.ToHexString(Digest), Digest) &&
            VpnServiceImageIdentity.HasExpectedHash(Convert.ToHexString(Digest).ToLowerInvariant(), Digest),
            "The exact release hash could not be verified.");
        var changed = Digest.ToArray(); changed[^1] ^= 1;
        Require(!VpnServiceImageIdentity.HasExpectedHash(Convert.ToHexString(Digest), changed),
            "A changed actual process image was admitted by the companion release pin.");
    }

    private static void RegistrationChangesAreRejected()
    {
        var first = InstalledService();
        Require(Matches(first), "Initial fixture registration was not valid.");
        var other = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "replacement service", VpnServiceImageIdentity.ExecutableName));
        Require(!Matches(first with { ProcessId = 315 }) &&
            !Matches(first with { BinaryPath = '"' + other + '"' }) &&
            !Matches(first with { CurrentState = 3 }),
            "Revalidation accepted a PID, command or state change during signature verification.");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) { throw new InvalidOperationException(message); }
    }
}
