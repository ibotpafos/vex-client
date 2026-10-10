using System.Reflection;
using System.Text;
using Vex.Windows.App.Services;

internal static class SupportSocketTests
{
    public static void Run() => CheckAsync().GetAwaiter().GetResult();

    private static async Task CheckAsync()
    {
        await using var socket = new SupportSocketClient();
        var tickets = new List<SupportSocketTicketEventArgs>();
        socket.TicketReceived += (_, args) => tickets.Add(args);
        const string first = """
            {"type":"support.ticket","ticket":{"id":"ticket-1","subject":"VPN",
            "message":"original","messages":[{"id":"message-1","sender":"support",
            "body":"original","created_at":"2026-10-10T12:00:00Z"}],"status":"open",
            "created_at":"2026-10-10T12:00:00Z","updated_at":"2026-10-10T12:00:00Z"}}
            """;
        Dispatch(socket, first);
        Dispatch(socket, first);
        Require(tickets.Count == 1, "Duplicate socket payloads must be ignored.");
        Dispatch(socket, first.Replace("original", "edited", StringComparison.Ordinal));
        Require(tickets.Count == 2 && tickets[1].Ticket.Messages[0].Body == "edited",
            "An edited ticket with unchanged timestamp and message count must reach the UI.");
        Require(tickets[0].Ticket.Messages[0].TicketId == "ticket-1",
            "Socket messages bind to their containing thread.");
        await socket.StopAsync();
        Dispatch(socket, first);
        Require(tickets.Count == 3, "A new page or user session must receive its own initial history.");
        Dispatch(socket, """{"type":"support.ticket","ticket":{"id":"legacy-ticket"}}""");
        Require(tickets[^1].Ticket.Messages.Count == 0 && tickets[^1].Ticket.Status == "open",
            "Legacy socket tickets missing optional thread fields must render safely.");
        Require(!await socket.SendAsync("offline", null, null, CancellationToken.None),
            "An offline socket must select HTTP fallback.");

        socket.ConfigureEndpointProvider((_, _) => throw new HttpRequestException("offline"));
        using var cancellation = new CancellationTokenSource();
        await socket.ConnectAsync("test-token", cancellation.Token);
        cancellation.Cancel();
        await socket.StopAsync().WaitAsync(TimeSpan.FromSeconds(5));
        Require(!socket.IsConnected && !socket.IsReconnecting,
            "Navigation during reconnect backoff must finish cleanly.");
    }

    private static void Dispatch(SupportSocketClient socket, string json) =>
        typeof(SupportSocketClient).GetMethod("Dispatch", BindingFlags.NonPublic | BindingFlags.Instance)!
            .Invoke(socket, [Encoding.UTF8.GetBytes(json)]);

    private static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }
}
