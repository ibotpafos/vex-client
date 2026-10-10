namespace Vex.Windows.Core.Presentation;

public sealed record SupportConversationMessage(
    string Id,
    string TicketId,
    string Sender,
    string Body,
    DateTimeOffset? CreatedAt);

public sealed record PendingSupportIdentity(
    string Id,
    string? TicketId,
    string Body,
    DateTimeOffset CreatedAt);

public sealed class SupportMessageReconciler
{
    private readonly HashSet<string> _observed = new(StringComparer.Ordinal);

    public void Clear() => _observed.Clear();

    public IReadOnlySet<string> ConfirmedPendingIds(
        IEnumerable<SupportConversationMessage> messages,
        IEnumerable<PendingSupportIdentity> pendingMessages)
    {
        var pending = pendingMessages.ToList();
        var acknowledged = new HashSet<string>(StringComparer.Ordinal);
        foreach (var message in messages)
        {
            // A repeated snapshot must never acknowledge a second identical
            // send. Observe historical messages before a new send, too.
            if (!_observed.Add(SupportConversationPresentation.MessageKey(message)) ||
                !message.Sender.Equals("user", StringComparison.OrdinalIgnoreCase) ||
                message.CreatedAt is not { } createdAt)
            {
                continue;
            }

            var match = pending
                .Where(candidate =>
                    !acknowledged.Contains(candidate.Id) &&
                    (candidate.TicketId is null || candidate.TicketId == message.TicketId) &&
                    SupportConversationPresentation.NormalizeBody(candidate.Body) ==
                        SupportConversationPresentation.NormalizeBody(message.Body) &&
                    Math.Abs((createdAt - candidate.CreatedAt).TotalMinutes) <= 5)
                .OrderBy(candidate => Math.Abs((createdAt - candidate.CreatedAt).TotalMilliseconds))
                .FirstOrDefault();
            if (match is not null)
            {
                acknowledged.Add(match.Id);
            }
        }

        return acknowledged;
    }
}

public static class SupportConversationPresentation
{
    public static string MessageKey(SupportConversationMessage message) =>
        !string.IsNullOrWhiteSpace(message.Id)
            ? $"{message.TicketId}:{message.Id}"
            : string.Join(':', message.TicketId, message.Sender,
                message.CreatedAt?.ToString("O"), NormalizeBody(message.Body));

    public static string NormalizeBody(string body) =>
        string.Join(' ', body.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    public static string CollapseDiagnostics(string body)
    {
        if (!body.Contains("generated_at:", StringComparison.Ordinal) ||
            !(body.Contains("check.", StringComparison.Ordinal) ||
              body.Contains("status:", StringComparison.Ordinal)))
        {
            return body;
        }

        var fields = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in body.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var separator = line.IndexOf(':');
            if (separator > 0)
            {
                fields.TryAdd(line[..separator].Trim(), line[(separator + 1)..].Trim());
            }
        }

        var lines = new List<string> { "Автоматическая диагностика" };
        foreach (var key in new[] { "status", "reason", "error" })
        {
            if (fields.TryGetValue(key, out var value) && value.Length > 0)
            {
                lines.Add($"{key}: {value}");
            }
        }

        return string.Join(Environment.NewLine, lines);
    }
}
