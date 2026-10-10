using Vex.Windows.Core.Presentation;

internal static class SupportConversationTests
{
    public static void Run()
    {
        var now = DateTimeOffset.Parse("2026-10-10T12:00:00Z");
        var reconciler = new SupportMessageReconciler();
        var pending = new[]
        {
            new PendingSupportIdentity("first", "ticket-a", "Повтор", now),
            new PendingSupportIdentity("second", "ticket-a", "Повтор", now.AddSeconds(1)),
        };
        var confirmed = new SupportConversationMessage(
            "message-1", "ticket-a", "user", "Повтор", now);
        var acknowledged = reconciler.ConfirmedPendingIds([confirmed], pending);
        Require(acknowledged.SetEquals(["first"]), "One confirmation must acknowledge one send.");
        Require(reconciler.ConfirmedPendingIds([confirmed], [pending[1]]).Count == 0,
            "A repeated snapshot must not acknowledge a second send.");
        var secondConfirmation = confirmed with { Id = "message-2", CreatedAt = now.AddSeconds(1) };
        Require(reconciler.ConfirmedPendingIds([confirmed, secondConfirmation], [pending[1]])
            .SetEquals(["second"]), "Distinct repeated sends need distinct confirmations.");

        reconciler.Clear();
        Require(reconciler.ConfirmedPendingIds([confirmed with { TicketId = "ticket-b" }], pending).Count == 0,
            "A different ticket must not acknowledge an existing thread's send.");
        reconciler.Clear();
        Require(reconciler.ConfirmedPendingIds([confirmed with { CreatedAt = null }], pending).Count == 0,
            "An unknown timestamp must not acknowledge a send.");
        reconciler.Clear();
        Require(reconciler.ConfirmedPendingIds([confirmed], []).Count == 0,
            "Historical messages have no pending send.");
        Require(reconciler.ConfirmedPendingIds([confirmed], pending).Count == 0,
            "Historical snapshots must not confirm a later send with the same body.");
        Require(SupportConversationPresentation.MessageKey(confirmed) !=
            SupportConversationPresentation.MessageKey(secondConfirmation),
            "Distinct messages with identical bodies remain visible.");
        Require(SupportConversationPresentation.MessageKey(confirmed) ==
            SupportConversationPresentation.MessageKey(confirmed with { Body = "Исправлено" }),
            "An edited message retains its stable identity.");

        var diagnostic = "generated_at: now\nstatus: ok\nSTATUS: repeated\ncheck.dns: yes\nreason: manual";
        Require(SupportConversationPresentation.CollapseDiagnostics(diagnostic) ==
            string.Join(Environment.NewLine, "Автоматическая диагностика", "status: ok", "reason: manual"),
            "Repeated diagnostic fields must render safely.");
        Require(SupportConversationPresentation.CollapseDiagnostics("Обычное сообщение") == "Обычное сообщение",
            "Normal support messages keep their content.");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }
}
