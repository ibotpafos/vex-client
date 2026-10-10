using System.Net;
using System.Text.Json;
using Vex.Windows.App.Services;
using Vex.Windows.Client.Api;

internal static class DiagnosticsQueueTests
{
    public static void Run() => CheckAsync().GetAwaiter().GetResult();

    private static async Task CheckAsync()
    {
        var directory = Path.Combine(Path.GetTempPath(), "vex-diagnostics-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var now = DateTimeOffset.Parse("2026-10-10T12:00:00Z");
            var path = Path.Combine(directory, "queue.json");
            var service = new DiagnosticsQueueService(path, () => now);
            var report = await service.EnqueueAsync("manual", "info", new Dictionary<string, string?>
            {
                ["DNS.OK"] = "first",
                ["dns.ok"] = "second",
                ["access_token"] = "raw-secret",
                ["note"] = "test@example.com 192.0.2.1 [2001:db8::1] ::1 Bearer raw-token",
            }, CancellationToken.None);
            Require(report.Samples.Count == 3 && report.Samples["dns.ok"] == "second",
                "Normalized sample-key collisions must not break diagnostics attachment.");
            Require(report.Samples["access_token"] == "[REDACTED]" &&
                !report.Samples["note"].Contains("test@example.com", StringComparison.Ordinal) &&
                !report.Samples["note"].Contains("192.0.2.1", StringComparison.Ordinal) &&
                !report.Samples["note"].Contains("2001:db8::1", StringComparison.Ordinal) &&
                !report.Samples["note"].Contains("::1", StringComparison.Ordinal) &&
                !report.Samples["note"].Contains("raw-token", StringComparison.Ordinal),
                "Stored diagnostic samples must redact credentials and personal fields.");
            service.ConfigureUploader((_, _) => throw new VexApiException(HttpStatusCode.ServiceUnavailable, "unavailable"));
            var failed = await service.FlushAsync(CancellationToken.None);
            Require(failed.Pending == 1 && failed.Uploaded == 0, "API failures must leave diagnostics queued.");
            Require(ReadQueue(path)[0].AttemptCount == 1, "Failed uploads record a retry attempt.");
            service.ConfigureUploader((_, _) => Task.CompletedTask);
            var recovered = await service.FlushAsync(CancellationToken.None);
            Require(recovered.Uploaded == 1 && recovered.Pending == 0, "A later successful upload drains the queue.");

            for (var index = 0; index < 3; index++)
            {
                await service.EnqueueAsync("cancel-test", "info", new Dictionary<string, string?>(), CancellationToken.None);
            }
            using var cancellation = new CancellationTokenSource();
            var attempts = 0;
            service.ConfigureUploader((_, token) =>
            {
                if (++attempts == 2)
                {
                    cancellation.Cancel();
                    throw new OperationCanceledException(token);
                }
                return Task.CompletedTask;
            });
            try
            {
                await service.FlushAsync(cancellation.Token);
                throw new InvalidOperationException("Cancellation must propagate.");
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
            {
            }
            var pending = ReadQueue(path);
            Require(pending.Count == 2 && pending.All(item => item.AttemptCount == 0),
                "Cancellation preserves unsent reports without requeueing an acknowledged upload or counting a failure.");

            attempts = 0;
            service.ConfigureUploader((_, _) =>
            {
                attempts++;
                throw new VexApiException(HttpStatusCode.TooManyRequests, "rate_limited");
            });
            var limited = await service.FlushAsync(CancellationToken.None);
            Require(limited.Pending == 2 && attempts == 1, "Rate limiting must stop the batch without losing later reports.");
            await service.FlushAsync(CancellationToken.None);
            Require(attempts == 1, "Repeated flushes must honor the 60-second rate limit.");
            now = now.AddSeconds(61);
            service.ConfigureUploader((_, _) => Task.CompletedTask);
            Require((await service.FlushAsync(CancellationToken.None)).Uploaded == 2,
                "Queued diagnostics resume after the rate limit expires.");
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static List<QueuedDiagnosticsReport> ReadQueue(string path) =>
        JsonSerializer.Deserialize<List<QueuedDiagnosticsReport>>(File.ReadAllText(path),
            new JsonSerializerOptions(JsonSerializerDefaults.Web)) ?? [];

    private static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }
}
