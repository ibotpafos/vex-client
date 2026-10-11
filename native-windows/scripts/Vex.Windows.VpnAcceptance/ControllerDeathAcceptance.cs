using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;
using Vex.Windows.Core.Vpn;
using Vex.Windows.Core.Vpn.Ipc;

namespace Vex.Windows.VpnAcceptance;

internal static class ControllerDeathAcceptance
{
    internal static async Task RunAsync(string directory, string runtimeDirectory, IPAddress outside,
        IPAddress? physicalDns, IPAddress source, int index, Dictionary<string, object?> result, CancellationToken token)
    {
        var nonce = Guid.NewGuid().ToString("N");
        var readyPath = Path.Combine(directory, "active-controller-" + nonce + ".json");
        Require(!File.Exists(readyPath) && !File.Exists(readyPath + ".tmp"), "fixture_active_receipt_collision");
        var executable = Path.GetFullPath(Environment.ProcessPath!);
        var imageHash = Convert.ToHexString(SHA256.HashData(await File.ReadAllBytesAsync(executable, token)));
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true };
        foreach (var argument in new[] { "--active-controller-child", directory, runtimeDirectory,
            nonce, outside.ToString(), physicalDns?.ToString() ?? "none" }) start.ArgumentList.Add(argument);
        result["stage"] = "full-active-controller-start";
        using var child = Process.Start(start) ?? throw new Program.FixtureException("fixture_active_child_missing");
        var startTicks = child.StartTime.ToUniversalTime().Ticks;
        ScmIpcFixture.ControllerDeathObservation? observation = null;
        try
        {
            using var readyDeadline = CancellationTokenSource.CreateLinkedTokenSource(token);
            readyDeadline.CancelAfter(TimeSpan.FromSeconds(50));
            while (!File.Exists(readyPath))
            {
                Require(!child.HasExited, "fixture_active_child_exited_before_ready");
                await Task.Delay(50, readyDeadline.Token);
            }
            var receipt = await ReadReceiptAsync(readyPath, nonce, child.Id, startTicks,
                imageHash, physicalDns is not null, readyDeadline.Token);
            // Capture and attest ownership while the child is alive. Never
            // reconstruct a process by PID after death or kill a service PID.
            observation = ScmIpcFixture.CaptureControllerDeathObservation(directory, child, startTicks, imageHash);
            result["full_active_controller_connected_verified"] = true;
            result["full_active_controller_uapi_rx_delta"] = receipt.uapi_rx_delta;
            result["full_active_controller_uapi_tx_delta"] = receipt.uapi_tx_delta;
            result["stage"] = "full-active-controller-abrupt-death";
            using var autonomous = CancellationTokenSource.CreateLinkedTokenSource(token);
            autonomous.CancelAfter(ControllerDeathReceipt.ObservationBudget);
            child.Kill(); // Exact Process.Start handle attested above, not its SCM or vendor process.
            await child.WaitForExitAsync(autonomous.Token);
            // No IPC status, Disconnect, SCM Stop, or parent runtime is used in
            // this interval. The fixture death monitor reaches production StopAsync.
            await observation.ObserveAutonomousCleanupAsync(autonomous.Token);
            Require(DateTimeOffset.UtcNow < receipt.authorization_expires_at_utc,
                "fixture_active_cleanup_reached_lease_expiry");
            result["full_active_controller_death_cleanup_verified"] = true;
            result["full_active_controller_lease_not_expired_verified"] = true;
            FullTunnelAcceptance.VerifyPhysicalRoute(source, index, outside);
            Require(await FullTunnelAcceptance.TcpReachableAsync(source, index, outside,
                TimeSpan.FromSeconds(8), autonomous.Token), "fixture_active_physical_tcp_not_restored");
            if (physicalDns is not null)
                Require(await FullTunnelAcceptance.PhysicalDnsReachableAsync(source, index, physicalDns,
                    TimeSpan.FromSeconds(3), autonomous.Token), "fixture_active_physical_dns_not_restored");
            Require(DateTimeOffset.UtcNow < receipt.authorization_expires_at_utc,
                "fixture_active_network_restore_reached_lease_expiry");
            result["full_active_controller_network_restored_verified"] = true;
        }
        finally
        {
            // Failure cleanup cannot set any autonomous success flag. The outer
            // PowerShell wrapper retains its independent owned cleanup as well.
            if (!child.HasExited)
            {
                ScmIpcFixture.AssertOwnedControllerProcess(directory, child, startTicks, imageHash);
                child.Kill();
                using var childCleanup = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                await child.WaitForExitAsync(childCleanup.Token);
            }
            observation ??= ScmIpcFixture.TryCaptureStoppedControllerObservation(directory, child.Id, startTicks, imageHash);
            if (observation is not null)
            {
                using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(95));
                await observation.CleanupAfterObservationAsync(cleanup.Token);
            }
            File.Delete(readyPath);
            File.Delete(readyPath + ".tmp");
        }
    }

    internal static async Task<int> RunChildAsync(string directory, string runtimeDirectory,
        string nonce, string outsideText, string dnsText)
    {
        try
        {
            Require(OperatingSystem.IsWindows() && Environment.GetEnvironmentVariable("GITHUB_ACTIONS") == "true" &&
                Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") == "github-hosted" &&
                Guid.TryParseExact(nonce, "N", out var request) && request != Guid.Empty && request.ToString("N") == nonce &&
                outsideText is "1.1.1.1" or "8.8.8.8", "fixture_active_child_arguments_invalid");
            directory = Path.GetFullPath(directory);
            runtimeDirectory = Path.GetFullPath(runtimeDirectory);
            using var self = Process.GetCurrentProcess();
            ScmIpcFixture.AssertOwnedControllerProcess(directory, self,
                self.StartTime.ToUniversalTime().Ticks,
                Convert.ToHexString(SHA256.HashData(await File.ReadAllBytesAsync(Environment.ProcessPath!))));
            var manifest = JsonSerializer.Deserialize<Program.Manifest>(
                await File.ReadAllTextAsync(Path.Combine(directory, "manifest.json")))
                ?? throw new Program.FixtureException("fixture_active_manifest_missing");
            var source = IPEndPoint.Parse(manifest.Endpoint).Address;
            var nic = NetworkInterface.GetAllNetworkInterfaces().Single(adapter =>
                adapter.OperationalStatus == OperationalStatus.Up && !adapter.Name.Equals("vex", StringComparison.OrdinalIgnoreCase) &&
                adapter.GetIPProperties().UnicastAddresses.Any(address => address.Address.Equals(source)));
            var index = nic.GetIPProperties().GetIPv4Properties()?.Index ?? 0;
            var outside = IPAddress.Parse(outsideText);
            var dns = dnsText == "none" ? null : IPAddress.Parse(dnsText);
            Require(index > 0 && (dns is null || nic.GetIPProperties().DnsAddresses.Contains(dns)),
                "fixture_active_physical_interface_invalid");
            using var profileKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
            var signer = new VpnProfileSigningKey("ci-fixture", VpnSignedProfileVerifier.SupportedAlgorithm,
                Convert.ToBase64String(profileKey.ExportSubjectPublicKeyInfo()));
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(140));
            await ScmIpcFixture.RunFullControllerAsync(directory, runtimeDirectory, manifest, signer, [],
                async (transport, options, token) =>
                {
                    var signed = Program.CreateSignedProfile(manifest, TimeSpan.FromSeconds(120), profileKey, fullTunnel: true);
                    var connected = await transport.SendAsync(VpnServiceRequest.TrustedConnect(Guid.NewGuid().ToString("N"),
                        signed.Authorization, manifest.ClientPrivateKey, antiLeakEnabled: true), token);
                    FullTunnelAcceptance.RequireProtected(connected);
                    var before = connected.Snapshot.Diagnostics!;
                    Require(before.AdapterIndex is > 0 && before.LatestHandshakeAt >= DateTimeOffset.UtcNow.AddMinutes(-1),
                        "fixture_active_handshake_missing");
                    await Program.ProbeTunnelDnsAsync(before.AdapterIndex!.Value, token);
                    await Program.ProbeTunnelHttpsAsync(before.AdapterIndex.Value, directory, token);
                    // Exclude admitted exceptions before a negative physical probe.
                    var snapshot = JsonSerializer.Deserialize<VpnControlPlaneAddressSnapshot>(await File.ReadAllTextAsync(
                        Path.Combine(options.DataDirectory, "control-plane-address-cache.json"), token));
                    var cache = new VpnControlPlaneAddressCache();
                    Require(cache.Restore(snapshot, options.ControlPlaneBypassHosts, DateTimeOffset.UtcNow),
                        "fixture_active_control_cache_invalid");
                    var admitted = cache.Get(manifest.Endpoint, manifest.ServerPublicKey, options.ControlPlaneBypassHosts,
                        signed.Profile.ExpiresAt, DateTimeOffset.UtcNow).Values.SelectMany(values => values).ToArray();
                    Require(!admitted.Contains(outside) && (dns is null || !admitted.Contains(dns)) && !outside.Equals(source),
                        "fixture_active_deny_target_admitted");
                    FullTunnelAcceptance.VerifyPhysicalRoute(source, index, outside);
                    Require(!await FullTunnelAcceptance.TcpReachableAsync(source, index, outside,
                        TimeSpan.FromSeconds(3), token), "fixture_active_physical_tcp_leaked");
                    if (dns is not null)
                        Require(!await FullTunnelAcceptance.PhysicalDnsReachableAsync(source, index, dns,
                            TimeSpan.FromSeconds(3), token), "fixture_active_physical_dns_leaked");
                    var after = await transport.SendAsync(VpnServiceRequest.Diagnostics(Guid.NewGuid().ToString("N")), token);
                    FullTunnelAcceptance.RequireProtected(after);
                    Require(after.Snapshot.Diagnostics!.RxBytes > before.RxBytes &&
                        after.Snapshot.Diagnostics.TxBytes > before.TxBytes, "fixture_active_encrypted_counters_not_increasing");
                    using var process = Process.GetCurrentProcess();
                    var receipt = new ControllerDeathReceipt(ControllerDeathReceipt.Schema, nonce, process.Id,
                        process.StartTime.ToUniversalTime().Ticks,
                        Convert.ToHexString(SHA256.HashData(await File.ReadAllBytesAsync(Environment.ProcessPath!, token))),
                        DateTimeOffset.UtcNow, signed.Profile.ExpiresAt, true, true,
                        after.Snapshot.Diagnostics.RxBytes - before.RxBytes, after.Snapshot.Diagnostics.TxBytes - before.TxBytes,
                        true, true, dns is not null, dns is not null);
                    var readyPath = Path.Combine(directory, "active-controller-" + nonce + ".json");
                    await using (var file = new FileStream(readyPath + ".tmp", FileMode.CreateNew, FileAccess.Write,
                        FileShare.None, 4096, FileOptions.WriteThrough))
                    {
                        await file.WriteAsync(JsonSerializer.SerializeToUtf8Bytes(receipt), token);
                        file.Flush(flushToDisk: true);
                    }
                    File.Move(readyPath + ".tmp", readyPath); // Immutable per nonce.
                    await Task.Delay(TimeSpan.FromSeconds(120), token); // Parent must kill while lease remains valid.
                    throw new Program.FixtureException("fixture_active_controller_not_killed");
                }, deadline.Token);
            return 1;
        }
        catch { return 1; } // Never print keys, config, account data or exception messages.
    }

    private static async Task<ControllerDeathReceipt> ReadReceiptAsync(string path, string nonce, int pid,
        long startTicks, string imageHash, bool dnsSupported, CancellationToken token)
    {
        Require((File.GetAttributes(path) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) == 0,
            "fixture_active_receipt_not_regular");
        await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        Require(file.Length is > 0 and <= 4096 &&
            (File.GetAttributes(file.SafeFileHandle) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) == 0,
            "fixture_active_receipt_invalid_size");
        var bytes = new byte[checked((int)file.Length)];
        await file.ReadExactlyAsync(bytes, token);
        return ControllerDeathReceipt.Parse(bytes, nonce, pid, startTicks, imageHash, dnsSupported, DateTimeOffset.UtcNow)
            ?? throw new Program.FixtureException("fixture_active_receipt_invalid");
    }

    private static void Require(bool condition, string code)
    {
        if (!condition) throw new Program.FixtureException(code);
    }
}

internal static partial class ScmIpcFixture
{
    internal static void AssertOwnedControllerProcess(string directory, Process process, long startTicks, string imageHash)
    {
        using var owner = WindowsIdentity.GetCurrent();
        Require(owner.User is not null && !process.HasExited && process.StartTime.ToUniversalTime().Ticks == startTicks &&
            string.Equals(process.MainModule?.FileName, Environment.ProcessPath, StringComparison.OrdinalIgnoreCase) &&
            HashFile(Environment.ProcessPath!) == imageHash, "fixture_active_controller_identity_invalid");
        var runnerRoot = Path.GetFullPath(Environment.GetEnvironmentVariable("RUNNER_TEMP") ?? "missing")
            .TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        Require(Path.GetFullPath(directory).StartsWith(runnerRoot, StringComparison.OrdinalIgnoreCase),
            "fixture_active_directory_outside_runner_temp");
        AssertPrivateDirectory(directory, owner.User!.Value);
        _ = ReadFixtureId(directory);
        AssertChildPath(directory, Path.GetFullPath(Environment.ProcessPath!));
        Require(OpenProcessToken(process.SafeHandle, 8, out var processToken), "fixture_active_controller_owner_unavailable");
        using (processToken)
        using (var actual = new WindowsIdentity(processToken.DangerousGetHandle()))
            Require(actual.User?.Equals(owner.User) == true, "fixture_active_controller_owner_invalid");
    }

    internal static ControllerDeathObservation CaptureControllerDeathObservation(string directory, Process child,
        long startTicks, string imageHash)
    {
        AssertOwnedControllerProcess(directory, child, startTicks, imageHash);
        var observation = TryCaptureStoppedControllerObservation(directory, child.Id, startTicks, imageHash);
        Require(observation is not null, "fixture_active_controller_settings_missing");
        observation!.AssertRunning();
        return observation;
    }

    internal static ControllerDeathObservation? TryCaptureStoppedControllerObservation(string directory, int pid,
        long startTicks, string imageHash)
    {
        var path = Path.Combine(directory, SettingsName);
        if (!File.Exists(path)) return null;
        AssertNotReparse(path);
        var settings = JsonSerializer.Deserialize<FixtureSettings>(File.ReadAllText(path));
        if (settings is null || settings.ControllerPid != pid || settings.ControllerStartTicks != startTicks) return null;
        Require(settings.FixtureId == ReadFixtureId(directory) && settings.HarnessSha256 == imageHash &&
            settings.FullTunnelChecks && HashFile(settings.HarnessPath) == imageHash,
            "fixture_active_controller_settings_invalid");
        using var owner = WindowsIdentity.GetCurrent();
        Require(settings.OwnerSid == owner.User?.Value, "fixture_active_controller_settings_owner_invalid");
        AssertPrivateDirectory(directory, settings.OwnerSid);
        AssertChildPath(directory, settings.HarnessPath);
        return new ControllerDeathObservation(directory, settings);
    }

    internal sealed class ControllerDeathObservation
    {
        private readonly string _directory;
        private readonly FixtureSettings _settings;
        internal ControllerDeathObservation(string directory, FixtureSettings settings)
        {
            _directory = directory;
            _settings = settings;
        }

        internal void AssertRunning() => _ = AssertServiceProcess(_directory, _settings);

        internal async Task ObserveAutonomousCleanupAsync(CancellationToken token)
        {
            await WaitServiceStateAsync(_directory, _settings, Stopped, ControllerDeathReceipt.ObservationBudget, token);
            await AssertTunnelStoppedAsync(Path.Combine(_directory, "service-state"), token);
        }

        internal async Task CleanupAfterObservationAsync(CancellationToken token)
        {
            await StopFixtureServiceAsync(_directory, _settings, token);
            await AssertTunnelStoppedAsync(Path.Combine(_directory, "service-state"), token);
            DeleteFixtureService(_directory, _settings);
            await WaitServiceDeletedAsync(_settings.ServiceName, token);
        }
    }
}
