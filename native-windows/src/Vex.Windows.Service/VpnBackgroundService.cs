using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Vex.Windows.Service.Ipc;
using Vex.Windows.Core.Vpn;

namespace Vex.Windows.Service;

public sealed class VpnBackgroundService(
    NamedPipeVpnServer server,
    IVpnTunnelRuntime runtime,
    ILogger<VpnBackgroundService> logger) : BackgroundService
{
    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        try
        {
            await base.StopAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            // SCM stopping the privileged controller must also stop the vendor
            // tunnel, including when the host's own shutdown deadline elapsed.
            using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(40));
            try
            {
                await runtime.DisconnectAsync(cleanup.Token).ConfigureAwait(false);
            }
            catch (Exception error)
            {
                logger.LogCritical("VPN service cleanup failed with {ErrorType}.", error.GetType().Name);
                throw;
            }
        }
    }

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
