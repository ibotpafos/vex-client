using System.Text.Json;
using System.Text.RegularExpressions;

namespace Vex.Windows.App.Services;

public sealed partial class DiagnosticsQueueService
{
    private const int MaximumQueueLength = 50;
    private const int MaximumValueLength = 2_000;
    private static readonly JsonSerializerOptions JsonOptions =
        new(JsonSerializerDefaults.Web)
        {
            WriteIndented = true,
        };

    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly string _queuePath;
    private Func<QueuedDiagnosticsReport, CancellationToken, Task>?
        _uploader;

    public DiagnosticsQueueService(string? queuePath = null)
    {
        _queuePath = queuePath ??
            Path.Combine(
                Environment.GetFolderPath(
                    Environment.SpecialFolder.LocalApplicationData),
                "VEX",
                "client-diagnostics-queue.json");
    }

    public static DiagnosticsQueueService Current { get; } = new();

    public string QueuePath => _queuePath;

    public void ConfigureUploader(
        Func<QueuedDiagnosticsReport, CancellationToken, Task> uploader)
    {
        ArgumentNullException.ThrowIfNull(uploader);
        _uploader = uploader;
    }

    public async Task<QueuedDiagnosticsReport> EnqueueAsync(
        string reason,
        string status,
        IReadOnlyDictionary<string, string?> samples,
        CancellationToken cancellationToken)
    {
        var report = new QueuedDiagnosticsReport(
            Guid.NewGuid().ToString("N"),
            DateTimeOffset.UtcNow,
            NormalizeField(reason, "manual_support_diagnostics"),
            NormalizeField(status, "info"),
            samples.ToDictionary(
                item => NormalizeKey(item.Key),
                item => Redact(item.Value ?? string.Empty),
                StringComparer.OrdinalIgnoreCase),
            0);

        await _gate.WaitAsync(cancellationToken);
        try
        {
            var queue = await ReadQueueAsync(cancellationToken);
            queue.Add(report);
            if (queue.Count > MaximumQueueLength)
            {
                queue.RemoveRange(
                    0,
                    queue.Count - MaximumQueueLength);
            }

            await WriteQueueAsync(queue, cancellationToken);
        }
        finally
        {
            _gate.Release();
        }

        return report;
    }

    public async Task<DiagnosticsFlushResult> FlushAsync(
        CancellationToken cancellationToken)
    {
        if (_uploader is null)
        {
            return new DiagnosticsFlushResult(
                Uploaded: 0,
                Pending: await CountAsync(cancellationToken),
                LastError: "diagnostics_uploader_not_configured");
        }

        await _gate.WaitAsync(cancellationToken);
        try
        {
            var queue = await ReadQueueAsync(cancellationToken);
            var remaining = new List<QueuedDiagnosticsReport>();
            var uploaded = 0;
            string? lastError = null;
            foreach (var report in queue)
            {
                cancellationToken.ThrowIfCancellationRequested();
                try
                {
                    await _uploader(report, cancellationToken);
                    uploaded++;
                }
                catch (Exception error) when (
                    error is HttpRequestException or
                        IOException or
                        TaskCanceledException or
                        InvalidOperationException)
                {
                    lastError = error.Message;
                    remaining.Add(
                        report with
                        {
                            AttemptCount = checked(
                                report.AttemptCount + 1),
                        });
                }
            }

            await WriteQueueAsync(remaining, cancellationToken);
            return new DiagnosticsFlushResult(
                uploaded,
                remaining.Count,
                lastError);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<int> CountAsync(
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            return (await ReadQueueAsync(cancellationToken)).Count;
        }
        finally
        {
            _gate.Release();
        }
    }

    public static string Redact(string value)
    {
        var result = value.Length > MaximumValueLength
            ? value[..MaximumValueLength]
            : value;
        result = BearerTokenRegex().Replace(
            result,
            "$1[REDACTED]");
        result = SensitiveAssignmentRegex().Replace(
            result,
            "$1=[REDACTED]");
        result = EmailRegex().Replace(result, "[REDACTED_EMAIL]");
        result = IpAddressRegex().Replace(result, "[REDACTED_IP]");
        return result;
    }

    private async Task<List<QueuedDiagnosticsReport>> ReadQueueAsync(
        CancellationToken cancellationToken)
    {
        if (!File.Exists(_queuePath))
        {
            return [];
        }

        try
        {
            await using var stream = File.OpenRead(_queuePath);
            return await JsonSerializer.DeserializeAsync<
                    List<QueuedDiagnosticsReport>>(
                    stream,
                    JsonOptions,
                    cancellationToken) ??
                [];
        }
        catch (Exception error) when (
            error is JsonException or
                IOException or
                UnauthorizedAccessException)
        {
            var corruptPath =
                $"{_queuePath}.corrupt-{DateTimeOffset.UtcNow:yyyyMMddHHmmss}";
            try
            {
                File.Move(_queuePath, corruptPath, overwrite: true);
            }
            catch (IOException)
            {
                // A future flush retries after the current writer releases it.
            }

            return [];
        }
    }

    private async Task WriteQueueAsync(
        IReadOnlyList<QueuedDiagnosticsReport> queue,
        CancellationToken cancellationToken)
    {
        var directory = Path.GetDirectoryName(_queuePath) ??
            throw new InvalidOperationException(
                "diagnostics_queue_directory_invalid");
        Directory.CreateDirectory(directory);
        var temporaryPath = $"{_queuePath}.{Guid.NewGuid():N}.tmp";
        await using (var stream = File.Create(temporaryPath))
        {
            await JsonSerializer.SerializeAsync(
                stream,
                queue,
                JsonOptions,
                cancellationToken);
            await stream.FlushAsync(cancellationToken);
        }

        File.Move(temporaryPath, _queuePath, overwrite: true);
    }

    private static string NormalizeKey(string value)
    {
        var normalized = Regex.Replace(
            value.Trim().ToLowerInvariant(),
            "[^a-z0-9_.-]",
            "_");
        return string.IsNullOrEmpty(normalized)
            ? "sample"
            : normalized[..Math.Min(normalized.Length, 80)];
    }

    private static string NormalizeField(
        string value,
        string fallback)
    {
        value = value.Trim();
        return value.Length == 0
            ? fallback
            : value[..Math.Min(value.Length, 120)];
    }

    [GeneratedRegex(
        @"(?i)\b(authorization\s*:\s*bearer\s+|bearer\s+)[A-Za-z0-9._~+/=-]+")]
    private static partial Regex BearerTokenRegex();

    [GeneratedRegex(
        @"(?i)\b(access[_-]?token|refresh[_-]?token|private[_-]?key|preshared[_-]?key|password|secret)\s*[:=]\s*[^\s,;]+")]
    private static partial Regex SensitiveAssignmentRegex();

    [GeneratedRegex(
        @"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b")]
    private static partial Regex EmailRegex();

    [GeneratedRegex(
        @"(?<![A-Fa-f0-9:])(?:\d{1,3}\.){3}\d{1,3}(?![A-Fa-f0-9:])")]
    private static partial Regex IpAddressRegex();
}

public sealed record QueuedDiagnosticsReport(
    string Id,
    DateTimeOffset GeneratedAt,
    string Reason,
    string Status,
    IReadOnlyDictionary<string, string> Samples,
    int AttemptCount);

public sealed record DiagnosticsFlushResult(
    int Uploaded,
    int Pending,
    string? LastError);
