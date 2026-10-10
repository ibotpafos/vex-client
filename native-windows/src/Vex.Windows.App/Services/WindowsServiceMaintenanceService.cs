using System.ComponentModel;
using System.Diagnostics;
using System.Security.Cryptography;
using Vex.Windows.Core.Vpn;
using Vex.Windows.Core.Vpn.Ipc;

namespace Vex.Windows.App.Services;

public sealed record ServiceMaintenanceResult(bool Success, string Message, string? RecoveryUrl = null);

public sealed class WindowsServiceMaintenanceService
{
    private const string ServiceName = "VEX VPN Service";
    private const string RecoveryWebsite = "https://vexguard.app/downloads";
    private const int MaximumDiagnosticsAttempts = 10;
    private readonly Func<CancellationToken, Task<VpnServiceResponse>> _diagnostics;
    private readonly Func<CancellationToken, Task<int>> _startElevated;
    private readonly Action _validateAssets;
    private readonly Func<bool> _isPreview;
    private readonly Func<CancellationToken, Task> _pollDelay;

    public WindowsServiceMaintenanceService(Func<CancellationToken, Task<VpnServiceResponse>> diagnostics,
        Func<CancellationToken, Task<int>>? startElevated = null, Action? validateAssets = null,
        Func<bool>? isPreview = null, Func<CancellationToken, Task>? pollDelay = null)
    {
        _diagnostics = diagnostics ?? throw new ArgumentNullException(nameof(diagnostics));
        _startElevated = startElevated ?? StartElevatedAsync;
        _validateAssets = validateAssets ?? ValidateInstalledRuntimeAssets;
        _isPreview = isPreview ?? (() => UiPreviewContext.IsEnabled);
        _pollDelay = pollDelay ?? (token => Task.Delay(TimeSpan.FromMilliseconds(500), token));
    }

    public async Task<ServiceMaintenanceResult> RepairAsync(CancellationToken cancellationToken)
    {
        if (_isPreview()) return new(false, "Предпросмотр не управляет системной службой.");
        using var operation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        operation.CancelAfter(TimeSpan.FromSeconds(60));
        try
        {
            operation.Token.ThrowIfCancellationRequested();
            _validateAssets();
            if (await ReadTrustedDiagnosticsAsync(operation.Token).ConfigureAwait(false))
                return new(true, "Служба VEX VPN работает и прошла проверку.");
            var exitCode = await _startElevated(operation.Token).WaitAsync(operation.Token).ConfigureAwait(false);
            if (exitCode is not 0 and not 1056) return InstallerRecovery();
            for (var attempt = 0; attempt < MaximumDiagnosticsAttempts; attempt++)
            {
                operation.Token.ThrowIfCancellationRequested();
                if (await ReadTrustedDiagnosticsAsync(operation.Token).ConfigureAwait(false))
                    return new(true, "Служба VEX VPN запущена и прошла проверку.");
                if (attempt + 1 < MaximumDiagnosticsAttempts)
                    await _pollDelay(operation.Token).ConfigureAwait(false);
            }
            return InstallerRecovery();
        }
        catch (Win32Exception error) when (error.NativeErrorCode == 1223)
        {
            return new(false, "Запуск службы отменён в запросе Windows. Повторите восстановление, когда будете готовы.");
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return new(false, "Служба не ответила вовремя. Используйте проверенный установщик из центра загрузок.", RecoveryWebsite);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or
            CryptographicException or InvalidOperationException or VpnIpcProtocolException or Win32Exception)
        {
            return InstallerRecovery();
        }
    }

    private async Task<bool> ReadTrustedDiagnosticsAsync(CancellationToken cancellationToken)
    {
        using var request = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        request.CancelAfter(TimeSpan.FromSeconds(3));
        try
        {
            var response = await _diagnostics(request.Token).WaitAsync(request.Token).ConfigureAwait(false);
            request.Token.ThrowIfCancellationRequested();
            return response.Success && response.ErrorCode is not "unauthorized" and not "tunnel_runtime_missing" &&
                response.Snapshot.ErrorCode is not "unauthorized" and not "tunnel_runtime_missing";
        }
        catch (IOException) { return false; }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { return false; }
    }

    private static async Task<int> StartElevatedAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var startInfo = new ProcessStartInfo(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System), "sc.exe"))
        {
            UseShellExecute = true,
            Verb = "runas",
        };
        startInfo.ArgumentList.Add("start");
        startInfo.ArgumentList.Add(ServiceName);
        using var process = Process.Start(startInfo) ??
            throw new InvalidOperationException("Windows не запустила восстановление службы.");
        await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        return process.ExitCode;
    }

    private static void ValidateInstalledRuntimeAssets()
    {
        var dataDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "VEX", "VPN");
        foreach (var asset in new[]
        {
            (File: "amneziawg.exe", Pin: "amneziawg-sha256"),
            (File: "wintun.dll", Pin: "wintun-sha256"),
            (File: "profile-signing-keys.json", Pin: "profile-signing-keys-sha256"),
        })
        {
            var expected = File.ReadAllText(Path.Combine(dataDirectory, asset.Pin)).Trim();
            if (expected.Length != 64 || expected.Any(character => !Uri.IsHexDigit(character)))
                throw new InvalidOperationException("Installed runtime pin is invalid.");
            using var file = File.OpenRead(Path.Combine(AppContext.BaseDirectory, asset.File));
            if (!string.Equals(Convert.ToHexString(SHA256.HashData(file)), expected, StringComparison.OrdinalIgnoreCase))
                throw new CryptographicException("Installed runtime failed its release hash check.");
        }
    }

    private static ServiceMaintenanceResult InstallerRecovery() => new(false,
        "Службу не удалось проверить. Восстановите VEX проверенным установщиком из центра загрузок.", RecoveryWebsite);
}
