using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Vex.Windows.Service.Ipc;

namespace Vex.Windows.Service;

public sealed class VpnBackgroundService(
    NamedPipeVpnServer server,
    ILogger<VpnBackgroundService> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            await server.RunAsync(stoppingToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            logger.LogInformation("VEX VPN Service stopped.");
        }
        catch (Exception error)
        {
            logger.LogCritical(
                "VEX VPN Service stopped after {ErrorType}.",
                error.GetType().Name);
            Environment.ExitCode = 1;
            throw;
        }
    }
}
