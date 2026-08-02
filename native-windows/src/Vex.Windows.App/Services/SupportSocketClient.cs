using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using Vex.Windows.Client.Api;

namespace Vex.Windows.App.Services;

public sealed class SupportSocketClient : IAsyncDisposable
{
    private const int MaximumReconnectAttempts = 6;
    private const int MaximumSeenEvents = 512;
    private static readonly TimeSpan MaximumReconnectDelay =
        TimeSpan.FromSeconds(30);
    private static readonly JsonSerializerOptions JsonOptions =
        new(JsonSerializerDefaults.Web)
        {
            PropertyNameCaseInsensitive = true,
        };

    private readonly SemaphoreSlim _lifecycleGate = new(1, 1);
    private readonly Queue<string> _seenEventOrder = new();
    private readonly HashSet<string> _seenEvents =
        new(StringComparer.Ordinal);
    private Func<string, CancellationToken, Task<Uri>>? _endpointProvider;
    private ClientWebSocket? _socket;
    private CancellationTokenSource? _lifetime;
    private Task? _runTask;
    private string? _accessToken;
    private int _reconnectAttempt;

    public static SupportSocketClient Current { get; } = new();

    public bool IsConnected =>
        _socket?.State == WebSocketState.Open;

    public bool IsReconnecting { get; private set; }

    public string? LastError { get; private set; }

    public event EventHandler<SupportSocketStateChangedEventArgs>?
        StateChanged;

    public event EventHandler<SupportSocketSnapshotEventArgs>?
        SnapshotReceived;

    public event EventHandler<SupportSocketTicketEventArgs>?
        TicketReceived;

    public void ConfigureEndpointProvider(
        Func<string, CancellationToken, Task<Uri>> endpointProvider)
    {
        ArgumentNullException.ThrowIfNull(endpointProvider);
        _endpointProvider = endpointProvider;
    }

    public async Task ConnectAsync(
        string accessToken,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(accessToken);
        if (_endpointProvider is null)
        {
            SetState(
                connected: false,
                reconnecting: false,
                "support_socket_not_configured");
            return;
        }

        await _lifecycleGate.WaitAsync(cancellationToken);
        try
        {
            if (string.Equals(
                    _accessToken,
                    accessToken,
                    StringComparison.Ordinal) &&
                _runTask is { IsCompleted: false })
            {
                return;
            }

            await StopCoreAsync();
            _accessToken = accessToken;
            _reconnectAttempt = 0;
            _lifetime = CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken);
            _runTask = RunAsync(_lifetime.Token);
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    public async Task<bool> SendAsync(
        string body,
        string? subject,
        string? ticketId,
        CancellationToken cancellationToken)
    {
        body = body.Trim();
        if (body.Length == 0 ||
            _socket is not { State: WebSocketState.Open } socket)
        {
            return false;
        }

        var payload = JsonSerializer.SerializeToUtf8Bytes(
            new SupportSocketOutgoingMessage(
                "support.message",
                body,
                NullIfEmpty(subject),
                NullIfEmpty(ticketId)),
            JsonOptions);
        try
        {
            await socket.SendAsync(
                payload,
                WebSocketMessageType.Text,
                endOfMessage: true,
                cancellationToken);
            return true;
        }
        catch (Exception error) when (
            error is WebSocketException or
                IOException or
                InvalidOperationException)
        {
            SetState(
                connected: false,
                reconnecting: true,
                error.Message);
            return false;
        }
    }

    public async Task StopAsync()
    {
        await _lifecycleGate.WaitAsync();
        try
        {
            await StopCoreAsync();
            _accessToken = null;
            SetState(false, false, null);
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync();
        _lifecycleGate.Dispose();
    }

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested &&
            _reconnectAttempt < MaximumReconnectAttempts)
        {
            try
            {
                var provider = _endpointProvider ??
                    throw new InvalidOperationException(
                        "support_socket_not_configured");
                var token = _accessToken ??
                    throw new InvalidOperationException(
                        "support_socket_token_missing");
                var endpoint = await provider(
                    token,
                    cancellationToken);
                if (endpoint.Scheme is not ("ws" or "wss"))
                {
                    throw new InvalidOperationException(
                        "support_socket_uri_invalid");
                }

                var socket = new ClientWebSocket();
                socket.Options.KeepAliveInterval =
                    TimeSpan.FromSeconds(20);
                _socket = socket;
                await socket.ConnectAsync(endpoint, cancellationToken);
                _reconnectAttempt = 0;
                SetState(true, false, null);
                await ReceiveLoopAsync(socket, cancellationToken);
            }
            catch (OperationCanceledException)
                when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception error) when (
                error is WebSocketException or
                    HttpRequestException or
                    IOException or
                    InvalidOperationException or
                    JsonException)
            {
                _reconnectAttempt++;
                SetState(false, true, error.Message);
                if (_reconnectAttempt >= MaximumReconnectAttempts)
                {
                    break;
                }

                var seconds = Math.Min(
                    MaximumReconnectDelay.TotalSeconds,
                    Math.Pow(2, _reconnectAttempt - 1));
                await Task.Delay(
                    TimeSpan.FromSeconds(seconds),
                    cancellationToken);
            }
            finally
            {
                _socket?.Dispose();
                _socket = null;
            }
        }

        SetState(false, false, LastError);
    }

    private async Task ReceiveLoopAsync(
        ClientWebSocket socket,
        CancellationToken cancellationToken)
    {
        var buffer = new byte[16 * 1024];
        using var message = new MemoryStream();
        while (socket.State == WebSocketState.Open &&
            !cancellationToken.IsCancellationRequested)
        {
            var result = await socket.ReceiveAsync(
                buffer,
                cancellationToken);
            if (result.MessageType == WebSocketMessageType.Close)
            {
                await socket.CloseOutputAsync(
                    WebSocketCloseStatus.NormalClosure,
                    "closing",
                    cancellationToken);
                throw new WebSocketException(
                    "support_socket_closed");
            }

            message.Write(buffer, 0, result.Count);
            if (!result.EndOfMessage)
            {
                if (message.Length > 1024 * 1024)
                {
                    throw new JsonException(
                        "support_socket_message_too_large");
                }

                continue;
            }

            Dispatch(message.ToArray());
            message.SetLength(0);
        }
    }

    private void Dispatch(byte[] payload)
    {
        var envelope = JsonSerializer.Deserialize<SupportSocketEnvelope>(
            payload,
            JsonOptions) ??
            throw new JsonException("support_socket_event_invalid");
        var eventKey = envelope.EventId ??
            BuildEventKey(envelope, payload);
        if (!RememberEvent(eventKey))
        {
            return;
        }

        switch (envelope.Type)
        {
            case "support.snapshot":
                SnapshotReceived?.Invoke(
                    this,
                    new SupportSocketSnapshotEventArgs(
                        envelope.Tickets ?? []));
                break;
            case "support.ticket" when envelope.Ticket is not null:
                TicketReceived?.Invoke(
                    this,
                    new SupportSocketTicketEventArgs(envelope.Ticket));
                break;
            case "support.error":
                SetState(
                    IsConnected,
                    IsReconnecting,
                    envelope.Message ?? "support_socket_error");
                break;
        }
    }

    private bool RememberEvent(string eventKey)
    {
        lock (_seenEvents)
        {
            if (!_seenEvents.Add(eventKey))
            {
                return false;
            }

            _seenEventOrder.Enqueue(eventKey);
            while (_seenEventOrder.Count > MaximumSeenEvents)
            {
                _seenEvents.Remove(_seenEventOrder.Dequeue());
            }

            return true;
        }
    }

    private async Task StopCoreAsync()
    {
        var lifetime = _lifetime;
        var runTask = _runTask;
        _lifetime = null;
        _runTask = null;
        lifetime?.Cancel();
        if (_socket is { State: WebSocketState.Open } socket)
        {
            try
            {
                await socket.CloseOutputAsync(
                    WebSocketCloseStatus.NormalClosure,
                    "navigation",
                    CancellationToken.None);
            }
            catch (WebSocketException)
            {
                // The receive loop owns reconnect/error reporting.
            }
        }

        if (runTask is not null)
        {
            try
            {
                await runTask;
            }
            catch (OperationCanceledException)
            {
                // Expected when the page or session closes.
            }
        }

        lifetime?.Dispose();
        _socket?.Dispose();
        _socket = null;
    }

    private void SetState(
        bool connected,
        bool reconnecting,
        string? error)
    {
        IsReconnecting = reconnecting;
        LastError = error;
        StateChanged?.Invoke(
            this,
            new SupportSocketStateChangedEventArgs(
                connected,
                reconnecting,
                error));
    }

    private static string BuildEventKey(
        SupportSocketEnvelope envelope,
        byte[] payload)
    {
        if (envelope.Ticket is { } ticket)
        {
            return string.Join(
                ':',
                envelope.Type,
                ticket.Id,
                ticket.UpdatedAt,
                ticket.Messages.Count);
        }

        return Convert.ToHexString(
            System.Security.Cryptography.SHA256.HashData(payload));
    }

    private static string? NullIfEmpty(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private sealed record SupportSocketOutgoingMessage(
        [property: System.Text.Json.Serialization.JsonPropertyName("type")]
            string Type,
        [property: System.Text.Json.Serialization.JsonPropertyName("body")]
            string Body,
        [property: System.Text.Json.Serialization.JsonPropertyName("subject")]
            string? Subject,
        [property: System.Text.Json.Serialization.JsonPropertyName("ticket_id")]
            string? TicketId);

    private sealed record SupportSocketEnvelope(
        [property: System.Text.Json.Serialization.JsonPropertyName("type")]
            string Type,
        [property: System.Text.Json.Serialization.JsonPropertyName("event_id")]
            string? EventId,
        [property: System.Text.Json.Serialization.JsonPropertyName("tickets")]
            IReadOnlyList<SupportTicket>? Tickets,
        [property: System.Text.Json.Serialization.JsonPropertyName("ticket")]
            SupportTicket? Ticket,
        [property: System.Text.Json.Serialization.JsonPropertyName("message")]
            string? Message);
}

public sealed record SupportSocketStateChangedEventArgs(
    bool IsConnected,
    bool IsReconnecting,
    string? Error);

public sealed record SupportSocketSnapshotEventArgs(
    IReadOnlyList<SupportTicket> Tickets);

public sealed record SupportSocketTicketEventArgs(
    SupportTicket Ticket);
