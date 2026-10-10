using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Win32.SafeHandles;
using Vex.Windows.Core.Vpn;
using Vex.Windows.Core.Vpn.Ipc;
using Vex.Windows.Service;
using Vex.Windows.Service.Ipc;
using Vex.Windows.Service.Runtime;
using Vex.Windows.Service.Security;

namespace Vex.Windows.VpnAcceptance;

// A separate, private SCM registration exercises the real controller lifetime
// and IPC. Its unsigned process attestations exist only in this acceptance EXE;
// the production service still requires its signed app and fixed pipe.
internal static class ScmIpcFixture
{
    private const string SettingsName = "fixture-settings.json";
    private const uint Running = 4;
    private const uint Stopped = 1;
    private const uint ServiceQueryConfig = 1;
    private const uint ServiceQueryStatus = 4;
    private const int ServiceDoesNotExist = 1060;
    private const int ServiceMarkedForDelete = 1072;
    private static readonly SecurityIdentifier SystemSid = new(WellKnownSidType.LocalSystemSid, null);
    private static readonly SecurityIdentifier AdministratorsSid = new(WellKnownSidType.BuiltinAdministratorsSid, null);

    internal static async Task RunAsync(string directory, string runtimeDirectory,
        Dictionary<string, object?> result, CancellationToken token)
    {
        foreach (var key in new[] { "scm_private_pipe_authenticated", "scm_bad_token_rejected",
            "scm_raw_config_rejected", "scm_tampered_profile_rejected", "scm_signed_connect_verified",
            "scm_status_diagnostics_verified", "scm_crash_status_restored", "scm_disconnect_verified",
            "scm_disconnect_survived_restart", "scm_stop_cleanup_verified",
            "scm_graceful_stop_survived_restart", "scm_authorization_expiry_cleanup_verified",
            "scm_fixture_service_removed" })
        {
            result[key] = false;
        }

        using var identity = WindowsIdentity.GetCurrent();
        Require(OperatingSystem.IsWindows() && identity.User is not null &&
            new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator), "fixture_scm_requires_administrator");
        directory = Path.GetFullPath(directory);
        runtimeDirectory = Path.GetFullPath(runtimeDirectory);
        var fixtureId = ReadFixtureId(directory);
        var harnessPath = Path.GetFullPath(Environment.ProcessPath ?? string.Empty);
        var ownerSid = identity.User!.Value;
        AssertPrivateDirectory(directory, ownerSid);
        AssertChildPath(directory, runtimeDirectory);
        AssertChildPath(directory, harnessPath);
        var manifest = JsonSerializer.Deserialize<Program.Manifest>(File.ReadAllText(Path.Combine(directory, "manifest.json")))
            ?? throw new Program.FixtureException("fixture_scm_manifest_missing");
        using var profileKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var signedProfile = Program.CreateSignedProfile(manifest, profileKey: profileKey);
        using var controller = Process.GetCurrentProcess();
        var settings = new FixtureSettings(fixtureId, "VEX.CI." + fixtureId, "Vex.CI." + fixtureId,
            controller.Id, controller.StartTime.ToUniversalTime().Ticks, ownerSid, harnessPath,
            HashFile(harnessPath), runtimeDirectory, manifest.Endpoint, signedProfile.SigningKey);
        var options = Program.FixtureOptions(directory, runtimeDirectory, manifest.Endpoint);
        ProvisionAuthorization(options.AuthorizationFile);
        await File.WriteAllTextAsync(Path.Combine(directory, SettingsName), JsonSerializer.Serialize(settings), token);

        var owned = false;
        try
        {
            result["stage"] = "scm-install";
            CreateFixtureService(directory, settings);
            owned = true;
            await StartFixtureServiceAsync(directory, settings, token);
            var transport = CreateTransport(directory, settings, new ProtectedAuthorizationStore(options).Read);
            var status = await ReadStatusAsync(transport, VpnConnectionPhase.Disconnected, token);
            Require(status.Success, "fixture_scm_initial_status_failed");
            result["scm_private_pipe_authenticated"] = true;

            result["stage"] = "scm-admission";
            var unauthorized = await CreateTransport(directory, settings, () => Convert.ToBase64String(new byte[32]))
                .SendAsync(VpnServiceRequest.Status(RequestId()), token);
            Require(!unauthorized.Success && unauthorized.ErrorCode == "unauthorized", "fixture_scm_bad_token_admitted");
            result["scm_bad_token_rejected"] = true;
            var raw = await transport.SendAsync(VpnServiceRequest.Connect(RequestId(), signedProfile.Profile.LocationId,
                signedProfile.Profile.TunnelConfig, signedProfile.Profile.ExpiresAt, antiLeakEnabled: false), token);
            Require(!raw.Success && raw.ErrorCode == "trusted_profile_required", "fixture_scm_raw_config_admitted");
            result["scm_raw_config_rejected"] = true;
            var signature = Convert.FromBase64String(signedProfile.Authorization.SignatureBase64);
            signature[^1] ^= 1;
            var tampered = new VpnProfileAuthorization(signedProfile.Authorization.KeyId, signedProfile.Authorization.Algorithm,
                signedProfile.Authorization.PayloadBase64, Convert.ToBase64String(signature));
            var rejected = await transport.SendAsync(VpnServiceRequest.TrustedConnect(RequestId(), tampered,
                manifest.ClientPrivateKey, antiLeakEnabled: false), token);
            Require(!rejected.Success && rejected.ErrorCode == "profile_signature_invalid", "fixture_scm_tampered_profile_admitted");
            result["scm_tampered_profile_rejected"] = true;

            result["stage"] = "scm-signed-connect";
            await ConnectAsync(transport, signedProfile.Authorization, manifest.ClientPrivateKey, token);
            result["scm_signed_connect_verified"] = true;
            status = await ReadStatusAsync(transport, VpnConnectionPhase.Connected, token);
            var diagnostics = await transport.SendAsync(VpnServiceRequest.Diagnostics(RequestId()), token);
            Require(diagnostics.Success && diagnostics.Snapshot.Phase == VpnConnectionPhase.Connected &&
                diagnostics.Snapshot.Diagnostics is { IsUsable: true, LeakProtection: VpnLeakProtectionState.Off },
                "fixture_scm_diagnostics_failed");
            result["scm_status_diagnostics_verified"] = true;
            result["scm_connected_snapshot_sequence"] = status.Snapshot.Sequence;

            // Kill only the attested controller PID. The independently running
            // vendor tunnel and its authorization lease must survive this crash.
            result["stage"] = "scm-crash-restart";
            var crashedPid = AssertServiceProcess(directory, settings);
            using (var serviceProcess = Process.GetProcessById(checked((int)crashedPid)))
            {
                serviceProcess.Kill();
                await serviceProcess.WaitForExitAsync(token);
            }
            await WaitServiceStateAsync(directory, settings, Stopped, TimeSpan.FromSeconds(15), token);
            await StartFixtureServiceAsync(directory, settings, token);
            Require(AssertServiceProcess(directory, settings) != crashedPid, "fixture_scm_crash_pid_not_replaced");
            status = await ReadStatusAsync(transport, VpnConnectionPhase.Connected, token);
            Require(status.Snapshot.LocationId == signedProfile.Profile.LocationId &&
                status.Snapshot.Diagnostics is { IsUsable: true }, "fixture_scm_crash_status_not_restored");
            result["scm_crash_status_restored"] = true;

            result["stage"] = "scm-disconnect-restart";
            var disconnected = await transport.SendAsync(VpnServiceRequest.Disconnect(RequestId()), token);
            Require(disconnected.Success && disconnected.Snapshot.Phase == VpnConnectionPhase.Disconnected,
                "fixture_scm_disconnect_failed");
            await AssertTunnelStoppedAsync(options.DataDirectory, token);
            result["scm_disconnect_verified"] = true;
            await StopFixtureServiceAsync(directory, settings, token);
            await StartFixtureServiceAsync(directory, settings, token);
            await ReadStatusAsync(transport, VpnConnectionPhase.Disconnected, token);
            await AssertTunnelStoppedAsync(options.DataDirectory, token);
            result["scm_disconnect_survived_restart"] = true;

            // This stop reaches the production VpnBackgroundService.StopAsync,
            // rather than asking the in-process runtime to disconnect directly.
            result["stage"] = "scm-graceful-stop";
            await ConnectAsync(transport, signedProfile.Authorization, manifest.ClientPrivateKey, token);
            await StopFixtureServiceAsync(directory, settings, token);
            await AssertTunnelStoppedAsync(options.DataDirectory, token);
            result["scm_stop_cleanup_verified"] = true;

            result["stage"] = "scm-graceful-stop-restart";
            await StartFixtureServiceAsync(directory, settings, token);
            await ReadStatusAsync(transport, VpnConnectionPhase.Disconnected, token);
            await AssertTunnelStoppedAsync(options.DataDirectory, token);
            result["scm_graceful_stop_survived_restart"] = true;

            result["stage"] = "scm-autonomous-authorization-expiry";
            var expiringProfile = Program.CreateSignedProfile(manifest, TimeSpan.FromSeconds(15), profileKey);
            await ConnectAsync(transport, expiringProfile.Authorization, manifest.ClientPrivateKey, token);
            // Read only SCM, adapter and lease/journal state until cleanup is
            // complete. Status itself enforces expiry and must not make this
            // autonomous lease callback assertion pass.
            await AssertTunnelStoppedAsync(options.DataDirectory, token, TimeSpan.FromSeconds(60));
            await ReadStatusAsync(transport, VpnConnectionPhase.Disconnected, token);
            result["scm_authorization_expiry_cleanup_verified"] = true;
            await StopFixtureServiceAsync(directory, settings, token);
        }
        catch
        {
            ReadStartupFailure(directory, result);
            throw;
        }
        finally
        {
            if (owned)
            {
                using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(95));
                await StopFixtureServiceAsync(directory, settings, cleanup.Token);
                DeleteFixtureService(directory, settings);
                await WaitServiceDeletedAsync(settings.ServiceName, cleanup.Token);
                result["scm_fixture_service_removed"] = true;
            }
        }
    }

    internal static async Task RunFullControllerAsync(string directory, string runtimeDirectory,
        Program.Manifest manifest, VpnProfileSigningKey signingKey, Dictionary<string, object?> result,
        Func<VpnNamedPipeTransport, WindowsServiceOptions, CancellationToken, Task> checks, CancellationToken token)
    {
        using var identity = WindowsIdentity.GetCurrent();
        Require(OperatingSystem.IsWindows() && identity.User is not null &&
            new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator), "fixture_scm_requires_administrator");
        directory = Path.GetFullPath(directory);
        runtimeDirectory = Path.GetFullPath(runtimeDirectory);
        var fixtureId = ReadFixtureId(directory);
        var harnessPath = Path.GetFullPath(Environment.ProcessPath ?? string.Empty);
        AssertPrivateDirectory(directory, identity.User!.Value);
        AssertChildPath(directory, runtimeDirectory);
        AssertChildPath(directory, harnessPath);
        using var controller = Process.GetCurrentProcess();
        var settings = new FixtureSettings(fixtureId, "VEX.CI." + fixtureId, "Vex.CI." + fixtureId,
            controller.Id, controller.StartTime.ToUniversalTime().Ticks, identity.User.Value, harnessPath,
            HashFile(harnessPath), runtimeDirectory, manifest.Endpoint, signingKey, FullTunnelChecks: true);
        var options = Program.FixtureOptions(directory, runtimeDirectory, manifest.Endpoint, fullTunnel: true);
        ProvisionAuthorization(options.AuthorizationFile);
        await File.WriteAllTextAsync(Path.Combine(directory, SettingsName), JsonSerializer.Serialize(settings), token);
        var owned = false;
        try
        {
            CreateFixtureService(directory, settings);
            owned = true;
            await StartFixtureServiceAsync(directory, settings, token);
            var transport = CreateTransport(directory, settings, new ProtectedAuthorizationStore(options).Read);
            await ReadStatusAsync(transport, VpnConnectionPhase.Disconnected, token);
            await checks(transport, options, token);
        }
        catch { ReadStartupFailure(directory, result); throw; }
        finally
        {
            if (owned)
            {
                // This process is SCM-owned, outside the calling harness kill
                // tree. Its one-second controller-death monitor and signed
                // lease trigger the same independent production cleanup.
                using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(95));
                await StopFixtureServiceAsync(directory, settings, cleanup.Token);
                await AssertTunnelStoppedAsync(options.DataDirectory, cleanup.Token);
                DeleteFixtureService(directory, settings);
                await WaitServiceDeletedAsync(settings.ServiceName, cleanup.Token);
                result["full_owned_cleanup_verified"] = true;
            }
        }
    }

    internal static Task ObserveControllerDeathAsync(Process controller, CancellationTokenSource lifetime) =>
        MonitorControllerAsync(controller, lifetime);

    internal static void AssertVendorDemandStart()
    {
        using var scm = OpenManager(1);
        using var service = OpenService(scm, WindowsServiceOptions.VendorServiceName, ServiceQueryConfig | ServiceQueryStatus);
        Require(!service.IsInvalid && QueryStatus(service).CurrentState == Running, "fixture_full_vendor_not_running");
        QueryServiceConfig(service, IntPtr.Zero, 0, out var size);
        Require(size > 0 && size <= 64 * 1024, "fixture_full_vendor_config_size_invalid");
        var buffer = Marshal.AllocHGlobal(checked((int)size));
        try
        {
            Require(QueryServiceConfig(service, buffer, size, out _), "fixture_full_vendor_config_read_failed");
            var configuration = Marshal.PtrToStructure<ServiceConfiguration>(buffer);
            Require(configuration.ServiceType == VpnVendorServiceIdentity.OwnProcess &&
                configuration.StartType == VpnVendorServiceIdentity.DemandStart &&
                string.Equals(Marshal.PtrToStringUni(configuration.AccountName), "LocalSystem", StringComparison.OrdinalIgnoreCase),
                "fixture_full_vendor_not_demand_start");
            var sid = new ServiceSidInfo();
            Require(QueryServiceConfig2(service, 5, ref sid, (uint)Marshal.SizeOf<ServiceSidInfo>(), out _) &&
                sid.SidType == VpnVendorServiceIdentity.UnrestrictedServiceSid, "fixture_full_vendor_sid_invalid");
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    internal static async Task<int> RunServiceAsync(string[] args)
    {
        string? failureDirectory = null;
        try
        {
            Require(args.Length == 3 && args[0] == "--fixture-service" && OperatingSystem.IsWindows(),
                "fixture_scm_service_arguments_invalid");
            using var identity = WindowsIdentity.GetCurrent();
            Require(identity.User?.Equals(SystemSid) == true, "fixture_scm_service_not_local_system");
            var directory = Path.GetFullPath(args[1]);
            var runtimeDirectory = Path.GetFullPath(args[2]);
            var settingsPath = Path.Combine(directory, SettingsName);
            AssertNotReparse(directory);
            AssertNotReparse(settingsPath);
            var settings = JsonSerializer.Deserialize<FixtureSettings>(File.ReadAllText(settingsPath))
                ?? throw new Program.FixtureException("fixture_scm_settings_missing");
            Require(settings.FixtureId == ReadFixtureId(directory) && settings.ServiceName == "VEX.CI." + settings.FixtureId &&
                settings.PipeName == "Vex.CI." + settings.FixtureId &&
                string.Equals(settings.RuntimeDirectory, runtimeDirectory, StringComparison.OrdinalIgnoreCase),
                "fixture_scm_settings_invalid");
            AssertPrivateDirectory(directory, settings.OwnerSid);
            failureDirectory = directory;
            AssertChildPath(directory, runtimeDirectory);
            AssertChildPath(directory, settings.HarnessPath);
            Require(string.Equals(Path.GetFullPath(Environment.ProcessPath ?? string.Empty), settings.HarnessPath,
                StringComparison.OrdinalIgnoreCase) && HashFile(settings.HarnessPath) == settings.HarnessSha256,
                "fixture_scm_service_image_invalid");
            var state = ReadServiceState(directory, settings);
            Require(state.CurrentState is 2 or Running,
                "fixture_scm_service_registration_invalid");
            Require(IsExpectedProcess(settings.ControllerPid, settings, settings.OwnerSid, settings.ControllerStartTicks),
                "fixture_scm_controller_invalid");

            var options = Program.FixtureOptions(directory, runtimeDirectory, settings.Endpoint, settings.FullTunnelChecks);
            var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings { ContentRootPath = directory, Args = [] });
            builder.Services.AddWindowsService(service => service.ServiceName = settings.ServiceName);
            builder.Logging.ClearProviders();
            builder.Services.Configure<HostOptions>(host => host.ShutdownTimeout = VpnRuntimeLifetimePolicy.HostShutdownTimeout);
            builder.Services.AddSingleton(options);
            builder.Services.AddSingleton<ProtectedAuthorizationStore>();
            builder.Services.AddSingleton(new VpnSignedProfileVerifier([settings.SigningKey]));
            builder.Services.AddSingleton<IVpnTunnelRuntime, AmneziaServiceTunnelRuntime>();
            builder.Services.AddSingleton<VpnServiceCommandHandler>();
            builder.Services.AddSingleton(provider => new NamedPipeVpnServer(
                provider.GetRequiredService<VpnServiceCommandHandler>(),
                provider.GetRequiredService<ProtectedAuthorizationStore>().Read(),
                pipe => AttestClient(pipe, settings), provider.GetRequiredService<VpnSignedProfileVerifier>(),
                provider.GetRequiredService<ILogger<NamedPipeVpnServer>>(), settings.PipeName,
                new SecurityIdentifier(settings.OwnerSid)));
            builder.Services.AddHostedService<VpnBackgroundService>();
            using var host = builder.Build();
            using var lifetime = new CancellationTokenSource(TimeSpan.FromMinutes(5));
            using var controller = Process.GetProcessById(settings.ControllerPid);
            var monitor = MonitorControllerAsync(controller, lifetime);
            var started = false;
            var stopped = false;
            try
            {
                await host.StartAsync(lifetime.Token);
                started = true;
                // QueryServiceStatusEx documents a valid PID only once Running.
                // The exact registration was checked before dispatcher startup.
                await WaitServiceStateAsync(directory, settings, Running, TimeSpan.FromSeconds(15), lifetime.Token);
                Require(AssertServiceProcess(directory, settings) == Environment.ProcessId,
                    "fixture_scm_registered_pid_invalid");
                await host.WaitForShutdownAsync(lifetime.Token);
                stopped = true;
            }
            finally
            {
                lifetime.Cancel();
                await monitor;
                if (started && !stopped)
                {
                    using var cleanup = new CancellationTokenSource(VpnRuntimeLifetimePolicy.HostShutdownTimeout);
                    await host.StopAsync(cleanup.Token);
                }
            }
            return 0;
        }
        catch (Exception error)
        {
            // SCM observes only a finite nonzero exit. Never print private state
            // or an exception message from the fixture service process.
            if (failureDirectory is not null)
            {
                try
                {
                    var failure = new Dictionary<string, object?> { ["failure_type"] = error.GetType().FullName };
                    if (error is Program.FixtureException fixture) { failure["failure_code"] = fixture.Code; }
                    if (error is Win32Exception native) { failure["native_code"] = native.NativeErrorCode; }
                    await File.WriteAllTextAsync(Path.Combine(failureDirectory, "scm-startup-failure.json"),
                        JsonSerializer.Serialize(failure));
                }
                catch (Exception) { }
            }
            return 1;
        }
    }

    private static void ReadStartupFailure(string directory, Dictionary<string, object?> result)
    {
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(directory, "scm-startup-failure.json")));
            foreach (var field in new[] { "failure_type", "failure_code" })
            {
                if (document.RootElement.TryGetProperty(field, out var value) && value.ValueKind == JsonValueKind.String &&
                    value.GetString() is { Length: > 0 and <= 256 } text &&
                    text.All(character => char.IsAsciiLetterOrDigit(character) || character is '.' or '_' or '+'))
                {
                    result["scm_startup_" + field] = text;
                }
            }
            if (document.RootElement.TryGetProperty("native_code", out var code) && code.TryGetInt32(out var number))
            {
                result["scm_startup_native_code"] = number;
            }
        }
        catch (Exception) { }
    }

    private static async Task MonitorControllerAsync(Process controller, CancellationTokenSource lifetime)
    {
        try
        {
            while (!lifetime.IsCancellationRequested)
            {
                if (controller.HasExited) { lifetime.Cancel(); return; }
                await Task.Delay(TimeSpan.FromSeconds(1), lifetime.Token);
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
    }

    private static VpnNamedPipeTransport CreateTransport(string directory, FixtureSettings settings, Func<string> authorization) =>
        new(settings.PipeName, pipe =>
        {
            Require(GetNamedPipeServerProcessId(pipe.SafePipeHandle, out var pid) &&
                pid == AssertServiceProcess(directory, settings), "fixture_scm_server_attestation_failed");
        }, authorization);

    private static bool AttestClient(NamedPipeServerStream pipe, FixtureSettings settings)
    {
        try
        {
            return GetNamedPipeClientProcessId(pipe.SafePipeHandle, out var pid) && pid == settings.ControllerPid &&
                IsExpectedProcess(checked((int)pid), settings, settings.OwnerSid, settings.ControllerStartTicks);
        }
        catch (Exception) { return false; }
    }

    private static bool IsExpectedProcess(int pid, FixtureSettings settings, string ownerSid, long? startTicks = null)
    {
        using var process = Process.GetProcessById(pid);
        if (process.HasExited || !string.Equals(process.MainModule?.FileName, settings.HarnessPath, StringComparison.OrdinalIgnoreCase) ||
            startTicks is not null && process.StartTime.ToUniversalTime().Ticks != startTicks ||
            HashFile(settings.HarnessPath) != settings.HarnessSha256)
        {
            return false;
        }
        if (!OpenProcessToken(process.SafeHandle, 8 /* TOKEN_QUERY */, out var token)) { return false; }
        using (token)
        using (var identity = new WindowsIdentity(token.DangerousGetHandle()))
        {
            return identity.User?.Value == ownerSid;
        }
    }

    private static uint AssertServiceProcess(string directory, FixtureSettings settings)
    {
        var status = ReadServiceState(directory, settings);
        Require(status.CurrentState == Running && status.ProcessId > 0 &&
            IsExpectedProcess(checked((int)status.ProcessId), settings, SystemSid.Value),
            "fixture_scm_service_process_invalid");
        return status.ProcessId;
    }

    private static async Task ConnectAsync(VpnNamedPipeTransport transport, VpnProfileAuthorization authorization,
        string privateKey, CancellationToken token)
    {
        var response = await transport.SendAsync(VpnServiceRequest.TrustedConnect(RequestId(), authorization, privateKey,
            antiLeakEnabled: false), token);
        Require(response.Success && response.Snapshot.Phase == VpnConnectionPhase.Connected &&
            response.Snapshot.Diagnostics is { IsUsable: true, LeakProtection: VpnLeakProtectionState.Off },
            "fixture_scm_signed_connect_failed");
    }

    private static async Task<VpnServiceResponse> ReadStatusAsync(VpnNamedPipeTransport transport,
        VpnConnectionPhase expected, CancellationToken token)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        try
        {
            while (true)
            {
                try
                {
                    var status = await transport.SendAsync(VpnServiceRequest.Status(RequestId()), timeout.Token);
                    if (status.Success && status.Snapshot.Phase == expected) { return status; }
                }
                catch (IOException) { }
                await Task.Delay(250, timeout.Token);
            }
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        {
            throw new Program.FixtureException("fixture_scm_status_timeout");
        }
    }

    private static async Task AssertTunnelStoppedAsync(string dataDirectory, CancellationToken token,
        TimeSpan? budget = null)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(budget ?? TimeSpan.FromSeconds(10));
        try
        {
            while (true)
            {
                using var scm = OpenManager(1);
                using var vendor = OpenService(scm, WindowsServiceOptions.VendorServiceName, ServiceQueryStatus);
                var vendorStopped = vendor.IsInvalid
                    ? Marshal.GetLastWin32Error() == ServiceDoesNotExist
                    : QueryStatus(vendor).CurrentState == Stopped;
                var adapterGone = !NetworkInterface.GetAllNetworkInterfaces().Any(adapter =>
                    adapter.Name.Equals("vex", StringComparison.OrdinalIgnoreCase));
                var journalsGone = new[] { "firewall-rollback.json", "bypass-routes.json", "authorization-expires-at" }
                    .All(name => !File.Exists(Path.Combine(dataDirectory, name)));
                if (vendorStopped && adapterGone && journalsGone) { return; }
                await Task.Delay(200, timeout.Token);
            }
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        {
            throw new Program.FixtureException("fixture_scm_tunnel_cleanup_incomplete");
        }
    }

    private static void ProvisionAuthorization(string path)
    {
        var clear = RandomNumberGenerator.GetBytes(32);
        try
        {
            File.WriteAllBytes(path, ProtectedData.Protect(clear, Encoding.UTF8.GetBytes("VEX VPN IPC v1"),
                DataProtectionScope.LocalMachine));
        }
        finally { CryptographicOperations.ZeroMemory(clear); }
    }

    private static void CreateFixtureService(string directory, FixtureSettings settings)
    {
        using var scm = OpenManager(3 /* CONNECT | CREATE_SERVICE */);
        using (var existing = OpenService(scm, settings.ServiceName, ServiceQueryStatus))
        {
            Require(existing.IsInvalid && Marshal.GetLastWin32Error() == ServiceDoesNotExist,
                "fixture_scm_service_collision");
        }
        using var service = CreateService(scm, settings.ServiceName, settings.ServiceName, 0xF01FF,
            0x10 /* OWN_PROCESS */, 3 /* DEMAND_START */, 1, BinaryPath(directory, settings), null,
            IntPtr.Zero, null, "LocalSystem", null);
        Require(!service.IsInvalid, "fixture_scm_create_failed");
    }

    private static async Task StartFixtureServiceAsync(string directory, FixtureSettings settings, CancellationToken token)
    {
        Require(ReadServiceState(directory, settings).CurrentState == Stopped, "fixture_scm_start_state_invalid");
        using (var controller = new ServiceController(settings.ServiceName)) { controller.Start(); }
        await WaitServiceStateAsync(directory, settings, Running, TimeSpan.FromSeconds(20), token);
        AssertServiceProcess(directory, settings);
    }

    private static async Task StopFixtureServiceAsync(string directory, FixtureSettings settings, CancellationToken token)
    {
        var status = ReadServiceState(directory, settings);
        if (status.CurrentState == Stopped) { return; }
        if (status.CurrentState == 2 /* START_PENDING */)
        {
            await WaitServiceStateAsync(directory, settings, Running, TimeSpan.FromSeconds(20), token);
            status = ReadServiceState(directory, settings);
        }
        if (status.CurrentState == Running)
        {
            AssertServiceProcess(directory, settings);
            using var controller = new ServiceController(settings.ServiceName);
            controller.Stop();
        }
        await WaitServiceStateAsync(directory, settings, Stopped,
            VpnRuntimeLifetimePolicy.HostShutdownTimeout + TimeSpan.FromSeconds(5), token);
    }

    private static async Task WaitServiceStateAsync(string directory, FixtureSettings settings, uint expected,
        TimeSpan limit, CancellationToken token)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(limit);
        try
        {
            while (ReadServiceState(directory, settings).CurrentState != expected) { await Task.Delay(200, timeout.Token); }
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        {
            throw new Program.FixtureException("fixture_scm_state_timeout");
        }
    }

    private static ServiceStatusProcess ReadServiceState(string directory, FixtureSettings settings)
    {
        using var scm = OpenManager(1);
        using var service = OpenService(scm, settings.ServiceName, ServiceQueryConfig | ServiceQueryStatus);
        Require(!service.IsInvalid, "fixture_scm_service_missing");
        QueryServiceConfig(service, IntPtr.Zero, 0, out var bytesNeeded);
        Require(bytesNeeded > 0 && bytesNeeded <= 64 * 1024, "fixture_scm_config_size_invalid");
        var buffer = Marshal.AllocHGlobal(checked((int)bytesNeeded));
        try
        {
            Require(QueryServiceConfig(service, buffer, bytesNeeded, out _), "fixture_scm_config_read_failed");
            var configuration = Marshal.PtrToStructure<ServiceConfiguration>(buffer);
            Require(configuration.ServiceType == 0x10 && configuration.StartType == 3 &&
                string.Equals(Marshal.PtrToStringUni(configuration.BinaryPath), BinaryPath(directory, settings),
                    StringComparison.OrdinalIgnoreCase) &&
                string.Equals(Marshal.PtrToStringUni(configuration.AccountName), "LocalSystem", StringComparison.OrdinalIgnoreCase),
                "fixture_scm_registration_changed");
        }
        finally { Marshal.FreeHGlobal(buffer); }
        return QueryStatus(service);
    }

    private static ServiceStatusProcess QueryStatus(ServiceHandle service)
    {
        Require(QueryServiceStatusEx(service, 0, out var status, (uint)Marshal.SizeOf<ServiceStatusProcess>(), out _),
            "fixture_scm_status_read_failed");
        return status;
    }

    private static void DeleteFixtureService(string directory, FixtureSettings settings)
    {
        Require(settings.FixtureId == ReadFixtureId(directory) && settings.ServiceName == "VEX.CI." + settings.FixtureId &&
            HashFile(settings.HarnessPath) == settings.HarnessSha256, "fixture_scm_delete_ownership_changed");
        Require(ReadServiceState(directory, settings).CurrentState == Stopped, "fixture_scm_delete_running_service");
        using var scm = OpenManager(1);
        using var service = OpenService(scm, settings.ServiceName, 0x10000 /* DELETE */);
        Require(!service.IsInvalid && DeleteService(service), "fixture_scm_delete_failed");
    }

    private static async Task WaitServiceDeletedAsync(string serviceName, CancellationToken token)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        try
        {
            while (true)
            {
                var deleted = false;
                using (var scm = OpenManager(1))
                using (var service = OpenService(scm, serviceName, ServiceQueryStatus))
                {
                    var error = Marshal.GetLastWin32Error();
                    if (service.IsInvalid && error == ServiceDoesNotExist) { deleted = true; }
                    else { Require(!service.IsInvalid || error == ServiceMarkedForDelete, "fixture_scm_delete_status_failed"); }
                }
                if (deleted) { return; }
                await Task.Delay(200, timeout.Token);
            }
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        {
            throw new Program.FixtureException("fixture_scm_delete_timeout");
        }
    }

    private static ServiceHandle OpenManager(uint access)
    {
        var handle = OpenSCManager(null, null, access);
        if (!handle.IsInvalid) { return handle; }
        handle.Dispose();
        throw new Program.FixtureException("fixture_scm_manager_unavailable");
    }

    private static string BinaryPath(string directory, FixtureSettings settings)
    {
        Require(new[] { directory, settings.RuntimeDirectory, settings.HarnessPath }
            .All(path => !path.Contains('"') && !path.Any(char.IsControl)), "fixture_scm_path_not_quotable");
        return $"\"{settings.HarnessPath}\" --fixture-service \"{directory}\" \"{settings.RuntimeDirectory}\"";
    }

    private static string ReadFixtureId(string directory)
    {
        AssertNotReparse(Path.Combine(directory, "owned-fixture"));
        var value = File.ReadAllText(Path.Combine(directory, "owned-fixture")).Trim();
        Require(Guid.TryParseExact(value, "N", out var id) && id.ToString("N") == value &&
            Path.GetFileName(directory).Equals("vex-vpn-acceptance-" + value, StringComparison.Ordinal),
            "fixture_scm_owned_directory_invalid");
        return value;
    }

    private static void AssertPrivateDirectory(string directory, string ownerSid)
    {
        AssertNotReparse(directory);
        var owner = new SecurityIdentifier(ownerSid);
        var acl = new DirectoryInfo(directory).GetAccessControl(AccessControlSections.Access);
        Require(acl.AreAccessRulesProtected, "fixture_scm_directory_inheritance_enabled");
        foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
        {
            Require(rule.AccessControlType != AccessControlType.Allow ||
                rule.IdentityReference.Equals(owner) || rule.IdentityReference.Equals(SystemSid) ||
                rule.IdentityReference.Equals(AdministratorsSid), "fixture_scm_directory_not_private");
        }
    }

    private static void AssertChildPath(string directory, string path)
    {
        var root = directory.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        Require(path.StartsWith(root, StringComparison.OrdinalIgnoreCase), "fixture_scm_path_outside_directory");
        var current = path;
        while (!string.Equals(current, directory, StringComparison.OrdinalIgnoreCase))
        {
            AssertNotReparse(current);
            current = Path.GetDirectoryName(current) ?? throw new Program.FixtureException("fixture_scm_path_invalid");
        }
    }

    private static void AssertNotReparse(string path) =>
        Require((File.GetAttributes(path) & FileAttributes.ReparsePoint) == 0, "fixture_scm_reparse_path");

    private static string HashFile(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static string RequestId() => Guid.NewGuid().ToString("N");
    private static void Require(bool condition, string code)
    {
        if (!condition) { throw new Program.FixtureException(code); }
    }

    private sealed record FixtureSettings(string FixtureId, string ServiceName, string PipeName,
        int ControllerPid, long ControllerStartTicks, string OwnerSid, string HarnessPath, string HarnessSha256,
        string RuntimeDirectory, string Endpoint, VpnProfileSigningKey SigningKey, bool FullTunnelChecks = false);

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceSidInfo { public uint SidType; }

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceStatusProcess
    {
        public uint ServiceType, CurrentState, ControlsAccepted, Win32ExitCode, ServiceSpecificExitCode,
            Checkpoint, WaitHint, ProcessId, ServiceFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceConfiguration
    {
        public uint ServiceType, StartType, ErrorControl;
        public IntPtr BinaryPath, LoadOrderGroup;
        public uint TagId;
        public IntPtr Dependencies, AccountName, DisplayName;
    }

    private sealed class ServiceHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        private ServiceHandle() : base(true) { }
        protected override bool ReleaseHandle() => CloseServiceHandle(handle);
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ServiceHandle OpenSCManager(string? machineName, string? databaseName, uint desiredAccess);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ServiceHandle OpenService(ServiceHandle manager, string serviceName, uint desiredAccess);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ServiceHandle CreateService(ServiceHandle manager, string serviceName, string displayName,
        uint desiredAccess, uint serviceType, uint startType, uint errorControl, string binaryPath,
        string? loadOrderGroup, IntPtr tagId, string? dependencies, string? accountName, string? password);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryServiceConfig(ServiceHandle service, IntPtr configuration, uint bufferSize, out uint bytesNeeded);
    [DllImport("advapi32.dll", EntryPoint = "QueryServiceConfig2W", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryServiceConfig2(ServiceHandle service, uint level, ref ServiceSidInfo information,
        uint bufferSize, out uint bytesNeeded);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryServiceStatusEx(ServiceHandle service, int informationLevel,
        out ServiceStatusProcess status, uint bufferSize, out uint bytesNeeded);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteService(ServiceHandle service);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseServiceHandle(IntPtr service);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(SafeProcessHandle process, uint access, out SafeAccessTokenHandle token);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint processId);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint processId);
}
