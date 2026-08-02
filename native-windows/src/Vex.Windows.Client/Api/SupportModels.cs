using System.Text.Json.Serialization;

namespace Vex.Windows.Client.Api;

public sealed record SupportMessage(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("ticket_id")] string TicketId,
    [property: JsonPropertyName("sender")] string Sender,
    [property: JsonPropertyName("author_id")] string? AuthorId,
    [property: JsonPropertyName("body")] string Body,
    [property: JsonPropertyName("created_at")] string CreatedAt);

public sealed record SupportTicket(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("subject")] string Subject,
    [property: JsonPropertyName("message")] string Message,
    [property: JsonPropertyName("messages")]
        IReadOnlyList<SupportMessage> Messages,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("priority")] string? Priority,
    [property: JsonPropertyName("source")] string Source,
    [property: JsonPropertyName("admin_note")] string? AdminNote,
    [property: JsonPropertyName("created_at")] string CreatedAt,
    [property: JsonPropertyName("updated_at")] string UpdatedAt,
    [property: JsonPropertyName("closed_at")] string? ClosedAt);
