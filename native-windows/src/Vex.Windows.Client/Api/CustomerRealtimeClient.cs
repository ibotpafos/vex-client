using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace Vex.Windows.Client.Api;

public sealed record CustomerRealtimeEvent(
    string Type,
    string Id,
    string Data);

public sealed record CustomerRealtimeMetadata(
    IReadOnlyList<string> Domains,
    string Reason)
{
    private static readonly HashSet<string> SupportedDomains =
    [
        "account",
        "entitlement",
        "billing",
        "devices",
        "provisioning",
        "connection",
        "family",
        "support",
        "releases",
        "status",
    ];

    public static CustomerRealtimeMetadata? Parse(
        string type,
        string data)
    {
        try
        {
            using var document = JsonDocument.Parse(data);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return null;
            }

            if (type == "customer.heartbeat")
            {
                return new CustomerRealtimeMetadata([], string.Empty);
            }

            if (type == "customer.session.revoked")
            {
                return new CustomerRealtimeMetadata(
                    [],
                    StringProperty(root, "reason") ?? "session_invalid");
            }

            if (type == "customer.change")
            {
                var domain = StringProperty(root, "domain");
                if (domain is null ||
                    !SupportedDomains.Contains(domain) ||
                    !root.TryGetProperty("version", out var version) ||
                    version.ValueKind != JsonValueKind.Number ||
                    !version.TryGetInt64(out var versionNumber) ||
                    versionNumber <= 0)
                {
                    return null;
                }

                return new CustomerRealtimeMetadata([domain], string.Empty);
            }

            if (type != "customer.resync" ||
                !root.TryGetProperty("versions", out var versions) ||
                versions.ValueKind != JsonValueKind.Array)
            {
                return null;
            }

            var domains = versions
                .EnumerateArray()
                .Where(item => item.ValueKind == JsonValueKind.Object)
                .Select(item => StringProperty(item, "domain"))
                .Where(domain =>
                    domain is not null && SupportedDomains.Contains(domain))
                .Cast<string>()
                .Distinct(StringComparer.Ordinal)
                .Order(StringComparer.Ordinal)
                .ToArray();
            return new CustomerRealtimeMetadata(
                domains,
                StringProperty(root, "reason") ?? "resync");
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string? StringProperty(
        JsonElement root,
        string propertyName) =>
        root.TryGetProperty(propertyName, out var value) &&
        value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;
}

public sealed class CustomerSseParser
{
    private const int MaximumRemainderLength = 64 * 1024;
    private static readonly HashSet<string> SupportedTypes =
    [
        "customer.change",
        "customer.resync",
        "customer.session.revoked",
        "customer.heartbeat",
    ];
    private readonly StringBuilder _remainder = new();

    public string Remainder => _remainder.ToString();

    public IReadOnlyList<CustomerRealtimeEvent> Append(string chunk)
    {
        ArgumentNullException.ThrowIfNull(chunk);
        var buffered = (_remainder + chunk)
            .Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n');
        var boundary = buffered.LastIndexOf(
            "\n\n",
            StringComparison.Ordinal);
        if (boundary < 0)
        {
            SetRemainder(buffered);
            return [];
        }

        var complete = buffered[..boundary];
        SetRemainder(buffered[(boundary + 2)..]);
        return complete
            .Split("\n\n", StringSplitOptions.None)
            .Select(ParseFrame)
            .Where(value => value is not null)
            .Cast<CustomerRealtimeEvent>()
            .ToArray();
    }

    private void SetRemainder(string value)
    {
        _remainder.Clear();
        _remainder.Append(
            value.Length <= MaximumRemainderLength
                ? value
                : value[^MaximumRemainderLength..]);
    }

    private static CustomerRealtimeEvent? ParseFrame(string frame)
    {
        var type = "message";
        var id = string.Empty;
        var data = new List<string>();
        foreach (var line in frame.Split('\n'))
        {
            if (line.StartsWith("event:", StringComparison.Ordinal))
            {
                type = line[6..].Trim();
            }
            else if (line.StartsWith("id:", StringComparison.Ordinal))
            {
                id = line[3..].Trim();
            }
            else if (line.StartsWith("data:", StringComparison.Ordinal))
            {
                data.Add(line[5..].TrimStart());
            }
        }

        return SupportedTypes.Contains(type) && data.Count > 0
            ? new CustomerRealtimeEvent(
                type,
                id,
                string.Join('\n', data))
            : null;
    }
}

public sealed class CustomerRealtimeChangedEventArgs(
    CustomerRealtimeEvent realtimeEvent,
    CustomerRealtimeMetadata metadata) : EventArgs
{
    public CustomerRealtimeEvent Event { get; } = realtimeEvent;

    public CustomerRealtimeMetadata Metadata { get; } = metadata;
}

public static class CustomerRealtimeRefreshPolicy
{
    public static bool ShouldRefreshAccount(
        CustomerRealtimeChangedEventArgs args) =>
        args.Event.Type == "customer.resync" ||
        args.Metadata.Domains.Any(domain => domain is
            "account" or
            "entitlement" or
            "billing" or
            "devices" or
            "family");

    public static bool ShouldRefreshSettings(
        CustomerRealtimeChangedEventArgs args) =>
        args.Event.Type == "customer.resync" ||
        args.Metadata.Domains.Any(domain => domain is
            "account" or
            "releases" or
            "status");
}

public sealed class CustomerRealtimeClient : IAsyncDisposable
{
    private readonly HttpClient _httpClient;
    private readonly SemaphoreSlim _lifecycle = new(1, 1);
    private CancellationTokenSource? _streamLifetime;
    private Task? _streamTask;

    public CustomerRealtimeClient(HttpClient httpClient)
    {
        ArgumentNullException.ThrowIfNull(httpClient);
        _httpClient = httpClient;
    }

    public event EventHandler<CustomerRealtimeChangedEventArgs>? Changed;

    public event EventHandler<bool>? ConnectionChanged;

    public bool IsConnected { get; private set; }

    public static TimeSpan ReconnectDelay(int attempt) =>
        TimeSpan.FromSeconds(
            Math.Min(30, Math.Pow(2, Math.Clamp(attempt, 0, 5))));

    public async Task StartAsync(
        string accessToken,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(accessToken);
        await _lifecycle.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await StopCoreAsync().ConfigureAwait(false);
            _streamLifetime = new CancellationTokenSource();
            _streamTask = RunAsync(accessToken, _streamLifetime.Token);
        }
        finally
        {
            _lifecycle.Release();
        }
    }

    public async Task StopAsync()
    {
        await _lifecycle.WaitAsync().ConfigureAwait(false);
        try
        {
            await StopCoreAsync().ConfigureAwait(false);
        }
        finally
        {
            _lifecycle.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
        _lifecycle.Dispose();
    }

    private async Task StopCoreAsync()
    {
        var lifetime = _streamLifetime;
        var task = _streamTask;
        _streamLifetime = null;
        _streamTask = null;
        lifetime?.Cancel();
        if (task is not null)
        {
            try
            {
                await task.ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
            }
        }
        lifetime?.Dispose();
        SetConnected(false);
    }

    private async Task RunAsync(
        string accessToken,
        CancellationToken cancellationToken)
    {
        var attempt = 0;
        var lastEventId = string.Empty;
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                lastEventId = await ReadStreamAsync(
                    accessToken,
                    lastEventId,
                    cancellationToken).ConfigureAwait(false);
                attempt = 0;
            }
            catch (OperationCanceledException)
                when (cancellationToken.IsCancellationRequested)
            {
                return;
            }
            catch (HttpRequestException)
            {
                SetConnected(false);
            }
            catch (IOException)
            {
                SetConnected(false);
            }

            await Task.Delay(
                ReconnectDelay(attempt++),
                cancellationToken).ConfigureAwait(false);
        }
    }

    private async Task<string> ReadStreamAsync(
        string accessToken,
        string lastEventId,
        CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(
            HttpMethod.Get,
            "/v1/events");
        request.Headers.Accept.Add(
            new MediaTypeWithQualityHeaderValue("text/event-stream"));
        request.Headers.Authorization =
            new AuthenticationHeaderValue("Bearer", accessToken);
        if (!string.IsNullOrEmpty(lastEventId))
        {
            request.Headers.TryAddWithoutValidation(
                "Last-Event-ID",
                lastEventId);
        }

        using var response = await _httpClient.SendAsync(
            request,
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken).ConfigureAwait(false);
        if (response.StatusCode == HttpStatusCode.Unauthorized)
        {
            Changed?.Invoke(
                this,
                new CustomerRealtimeChangedEventArgs(
                    new CustomerRealtimeEvent(
                        "customer.session.revoked",
                        string.Empty,
                        "{\"reason\":\"unauthorized\"}"),
                    new CustomerRealtimeMetadata([], "unauthorized")));
        }
        response.EnsureSuccessStatusCode();
        SetConnected(true);

        await using var stream = await response.Content
            .ReadAsStreamAsync(cancellationToken)
            .ConfigureAwait(false);
        using var reader = new StreamReader(stream, Encoding.UTF8);
        var parser = new CustomerSseParser();
        while (true)
        {
            var line = await reader.ReadLineAsync(cancellationToken)
                .ConfigureAwait(false);
            if (line is null)
            {
                break;
            }
            foreach (var realtimeEvent in parser.Append(line + "\n"))
            {
                if (!string.IsNullOrEmpty(realtimeEvent.Id))
                {
                    lastEventId = realtimeEvent.Id;
                }
                var metadata = CustomerRealtimeMetadata.Parse(
                    realtimeEvent.Type,
                    realtimeEvent.Data);
                if (metadata is not null)
                {
                    Changed?.Invoke(
                        this,
                        new CustomerRealtimeChangedEventArgs(
                            realtimeEvent,
                            metadata));
                }
            }
        }
        SetConnected(false);
        return lastEventId;
    }

    private void SetConnected(bool connected)
    {
        if (IsConnected == connected)
        {
            return;
        }
        IsConnected = connected;
        ConnectionChanged?.Invoke(this, connected);
    }
}
