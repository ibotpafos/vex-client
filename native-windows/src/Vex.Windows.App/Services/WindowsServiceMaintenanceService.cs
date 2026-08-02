using System.Diagnostics;

namespace Vex.Windows.App.Services;

public sealed record ServiceMaintenanceResult(
    bool Success,
    string Message);

public sealed class WindowsServiceMaintenanceService
{
    private const string ServiceName = "VEX VPN Service";

    public async Task<ServiceMaintenanceResult> RepairAsync(
        CancellationToken cancellationToken)
    {
        using var process = new Process
        {
            StartInfo = new ProcessStartInfo(
                Path.Combine(
                    Environment.GetFolderPath(
                        Environment.SpecialFolder.System),
                    "sc.exe"),
                $"start \"{ServiceName}\"")
            {
                CreateNoWindow = true,
                RedirectStandardError = true,
                RedirectStandardOutput = true,
                UseShellExecute = false,
            },
        };
        if (!process.Start())
        {
            return new ServiceMaintenanceResult(
                false,
                "Системная служба не запустилась.");
        }

        await process.WaitForExitAsync(cancellationToken)
            .ConfigureAwait(false);
        var output = string.Join(
            " ",
            await process.StandardOutput.ReadToEndAsync(cancellationToken)
                .ConfigureAwait(false),
            await process.StandardError.ReadToEndAsync(cancellationToken)
                .ConfigureAwait(false));
        var alreadyRunning =
            output.Contains("1056", StringComparison.Ordinal);
        return process.ExitCode == 0 || alreadyRunning
            ? new ServiceMaintenanceResult(
                true,
                alreadyRunning
                    ? "Служба VEX VPN уже запущена."
                    : "Служба VEX VPN запущена.")
            : new ServiceMaintenanceResult(
                false,
                "Windows отклонила запуск службы. Запустите проверенный установщик VEX от имени администратора.");
    }
}
