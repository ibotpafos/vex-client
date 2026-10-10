using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using System.Runtime.ExceptionServices;
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
        Exception? shutdownFailure = null;
        var lifetime = runtime as IVpnRuntimeLifetime;
        try
        {
            lifetime?.BeginShutdown();
        }
        catch (Exception error)
        {
            shutdownFailure = error;
            logger.LogCritical("VPN shutdown intent failed with {ErrorType}.", error.GetType().Name);
        }

        try
        {
            using var pipeStop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            pipeStop.CancelAfter(VpnRuntimeLifetimePolicy.PipeShutdownTimeout);
            await base.StopAsync(pipeStop.Token).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            shutdownFailure ??= error;
        }
        finally
        {
            // Cancel recovery before draining IPC and wait for the queued
            // watchdog/lease callbacks before taking down the vendor tunnel.
            try
            {
                using var quiesce = new CancellationTokenSource(VpnRuntimeLifetimePolicy.QuiesceTimeout);
                if (lifetime is not null)
                {
                    await lifetime.QuiesceAsync(quiesce.Token).ConfigureAwait(false);
                }
            }
            catch (Exception error)
            {
                shutdownFailure ??= error;
                logger.LogCritical("VPN background drain failed with {ErrorType}.", error.GetType().Name);
            }
            finally
            {
                // Cleanup gets its own bounded deadline even if IPC draining
                // exhausted the host token. Unconfirmed stop retains protection.
                using var cleanup = new CancellationTokenSource(VpnRuntimeLifetimePolicy.CleanupTimeout);
                try
                {
                    await runtime.DisconnectAsync(cleanup.Token).ConfigureAwait(false);
                }
                catch (Exception error)
                {
                    shutdownFailure = error;
                    logger.LogCritical("VPN service cleanup failed with {ErrorType}.", error.GetType().Name);
                }
            }
        }

        if (shutdownFailure is not null)
        {
            Environment.ExitCode = 1;
            ExceptionDispatchInfo.Capture(shutdownFailure).Throw();
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
