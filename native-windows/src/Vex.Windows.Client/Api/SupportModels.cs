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

public static class SupportModelNormalization
{
    public static SupportTicket NormalizeTicket(SupportTicket ticket)
    {
        if (ticket is null || string.IsNullOrWhiteSpace(ticket.Id))
        {
            throw new VexApiException(System.Net.HttpStatusCode.BadGateway, "api_response_invalid");
        }
        var messages = (ticket.Messages ?? []).Where(message => message is not null &&
                !string.IsNullOrWhiteSpace(message.Id) && !string.IsNullOrWhiteSpace(message.Body))
            .Select(message => message with
            {
                TicketId = ticket.Id,
                Sender = message.Sender ?? "user",
                CreatedAt = message.CreatedAt ?? string.Empty,
            }).ToArray();
        return ticket with
        {
            Subject = ticket.Subject ?? "Поддержка VEX",
            Message = ticket.Message ?? string.Empty,
            Messages = messages,
            Status = ticket.Status ?? "open",
            Source = ticket.Source ?? "native",
            CreatedAt = ticket.CreatedAt ?? string.Empty,
            UpdatedAt = ticket.UpdatedAt ?? ticket.CreatedAt ?? string.Empty,
        };
    }
}
