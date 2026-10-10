using System.Text.Json;
using System.Text.RegularExpressions;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Session;

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
    private readonly Func<DateTimeOffset> _utcNow;
    private DateTimeOffset? _rateLimitedUntil;
    private Func<QueuedDiagnosticsReport, CancellationToken, Task>?
        _uploader;

    public DiagnosticsQueueService(
        string? queuePath = null,
        Func<DateTimeOffset>? utcNow = null)
    {
        _utcNow = utcNow ?? (() => DateTimeOffset.UtcNow);
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
            _utcNow(),
            NormalizeField(reason, "manual_support_diagnostics"),
            NormalizeField(status, "info"),
            samples.GroupBy(item => NormalizeKey(item.Key), StringComparer.OrdinalIgnoreCase)
                .ToDictionary(
                group => group.Key,
                group => IsSensitiveKey(group.Key)
                    ? "[REDACTED]"
                    : Redact(group.Last().Value ?? string.Empty),
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
            if (_rateLimitedUntil > _utcNow())
            {
                return new DiagnosticsFlushResult(0, queue.Count, "diagnostics_rate_limited");
            }
            var uploaded = 0;
            string? lastError = null;
            for (var index = 0; index < queue.Count;)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var report = queue[index];
                var accepted = false;
                try
                {
                    await _uploader(report, cancellationToken);
                    accepted = true;
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    throw;
                }
                catch (Exception error) when (
                    error is HttpRequestException or
                        IOException or
                        OperationCanceledException or
                        InvalidOperationException or
                        VexApiException or NativeClientFlowException)
                {
                    lastError = Redact(error.Message);
                    queue[index] = report with
                    {
                        AttemptCount = report.AttemptCount == int.MaxValue
                            ? int.MaxValue
                            : report.AttemptCount + 1,
                    };
                    await WriteQueueAsync(queue, CancellationToken.None);
                    if (error is VexApiException { StatusCode: System.Net.HttpStatusCode.TooManyRequests })
                    {
                        _rateLimitedUntil = _utcNow().AddSeconds(60);
                        break;
                    }
                    index++;
                }
                if (accepted)
                {
                    queue.RemoveAt(index);
                    // Persist each acknowledgement even if navigation cancels
                    // the next upload, so a later flush does not send it twice.
                    await WriteQueueAsync(queue, CancellationToken.None);
                    uploaded++;
                }
            }

            return new DiagnosticsFlushResult(
                uploaded,
                queue.Count,
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
        result = IPv6CandidateRegex().Replace(result, match =>
            System.Net.IPAddress.TryParse(match.Value, out var address) &&
            address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetworkV6
                ? "[REDACTED_IP]"
                : match.Value);
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
        catch (JsonException)
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

    private static bool IsSensitiveKey(string key)
    {
        key = key.Replace('-', '_').Replace('.', '_');
        return new[] { "authorization", "access_token", "refresh_token",
                "private_key", "preshared_key", "password", "secret" }
            .Any(field => key == field || key.EndsWith('_' + field, StringComparison.Ordinal));
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

    [GeneratedRegex(@"(?<![\w:])(?:[0-9A-Fa-f]{0,4}:){2,}[0-9A-Fa-f:.]*(?:%[0-9A-Za-z_.-]+)?(?![\w:])")]
    private static partial Regex IPv6CandidateRegex();
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
