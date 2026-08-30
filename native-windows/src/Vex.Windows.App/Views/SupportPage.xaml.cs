using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Vex.Windows.App.Services;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Session;

namespace Vex.Windows.App.Views;

public sealed partial class SupportPage : Page
{
    private static readonly TimeSpan RefreshInterval =
        TimeSpan.FromSeconds(30);
    private readonly AppServices _services = AppServices.Current;
    private readonly SupportSocketClient _socket =
        SupportSocketClient.Current;
    private readonly DiagnosticsQueueService _diagnostics =
        DiagnosticsQueueService.Current;
    private readonly List<PendingSupportMessage> _pending = [];
    private IReadOnlyList<SupportTicket> _tickets = [];
    private NativeSupportSnapshot? _snapshot;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _refreshTimer;
    private CancellationTokenSource? _pageLifetime;
    private int _activationGeneration;

    private NativeClientCoordinator Coordinator =>
        _services.Coordinator;

    public SupportPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        Render();
    }

    private async void OnLoaded(object sender, RoutedEventArgs args)
    {
        _pageLifetime?.Cancel();
        _pageLifetime?.Dispose();
        _pageLifetime = new CancellationTokenSource();
        var generation = checked(++_activationGeneration);
        _services.Auth.StateChanged += OnAuthStateChanged;
        _services.CustomerRealtimeChanged += OnCustomerRealtimeChanged;
        _socket.StateChanged += OnSocketStateChanged;
        _socket.SnapshotReceived += OnSocketSnapshotReceived;
        _socket.TicketReceived += OnSocketTicketReceived;
        await ActivateSessionSafelyAsync(
            generation,
            _pageLifetime.Token);
    }

    private async void OnUnloaded(object sender, RoutedEventArgs args)
    {
        _services.Auth.StateChanged -= OnAuthStateChanged;
        _services.CustomerRealtimeChanged -= OnCustomerRealtimeChanged;
        _socket.StateChanged -= OnSocketStateChanged;
        _socket.SnapshotReceived -= OnSocketSnapshotReceived;
        _socket.TicketReceived -= OnSocketTicketReceived;
        _refreshTimer?.Stop();
        _refreshTimer = null;
        checked
        {
            _activationGeneration++;
        }
        _pageLifetime?.Cancel();
        _pageLifetime?.Dispose();
        _pageLifetime = null;
        await _socket.StopAsync();
    }

    private void OnCustomerRealtimeChanged(
        object? sender,
        CustomerRealtimeChangedEventArgs args)
    {
        if (args.Event.Type != "customer.resync" &&
            !args.Metadata.Domains.Contains("support"))
        {
            return;
        }
        DispatcherQueue.TryEnqueue(async () =>
        {
            var token = _pageLifetime?.Token;
            if (token is { IsCancellationRequested: false })
            {
                await RefreshAsync(token.Value);
            }
        });
    }

    private void OnAuthStateChanged(object? sender, EventArgs args) =>
        DispatcherQueue.TryEnqueue(
            async () =>
            {
                var lifetime = _pageLifetime;
                if (lifetime is null)
                {
                    return;
                }

                var generation = checked(++_activationGeneration);
                await ActivateSessionSafelyAsync(
                    generation,
                    lifetime.Token);
            });

    private async Task ActivateSessionSafelyAsync(
        int generation,
        CancellationToken cancellationToken)
    {
        try
        {
            await ActivateSessionAsync(
                generation,
                cancellationToken);
        }
        catch (OperationCanceledException)
        {
        }
    }

    private async Task ActivateSessionAsync(
        int generation,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var state = Coordinator.CurrentState;
        if (state is null)
        {
            _snapshot = null;
            _tickets = [];
            _pending.Clear();
            _refreshTimer?.Stop();
            await _socket.StopAsync();
            if (IsCurrentActivation(generation, cancellationToken))
            {
                Render();
            }
            return;
        }

        await _socket.ConnectAsync(
            state.Session.AccessToken,
            cancellationToken);
        await RefreshAsync(cancellationToken);
        if (!IsCurrentActivation(generation, cancellationToken))
        {
            await _socket.StopAsync();
            return;
        }

        StartRefreshTimer();
        _ = _diagnostics.FlushAsync(cancellationToken);
    }

    private bool IsCurrentActivation(
        int generation,
        CancellationToken cancellationToken) =>
        !cancellationToken.IsCancellationRequested &&
        generation == _activationGeneration &&
        _pageLifetime is not null;

    private void StartRefreshTimer()
    {
        _refreshTimer ??= DispatcherQueue.CreateTimer();
        _refreshTimer.Interval = RefreshInterval;
        _refreshTimer.IsRepeating = true;
        _refreshTimer.Tick -= OnRefreshTimerTick;
        _refreshTimer.Tick += OnRefreshTimerTick;
        _refreshTimer.Start();
    }

    private async void OnRefreshTimerTick(
        Microsoft.UI.Dispatching.DispatcherQueueTimer sender,
        object args)
    {
        if (!BusyIndicator.IsActive &&
            Coordinator.CurrentState is not null)
        {
            var cancellationToken =
                _pageLifetime?.Token ?? new CancellationToken(canceled: true);
            if (cancellationToken.IsCancellationRequested)
            {
                return;
            }

            await RefreshAsync(cancellationToken);
            _ = _diagnostics.FlushAsync(cancellationToken);
        }
    }

    private async void OnRefreshClick(
        object sender,
        RoutedEventArgs args) =>
        await RefreshAsync(
            _pageLifetime?.Token ?? CancellationToken.None);

    private async void OnSendClick(
        object sender,
        RoutedEventArgs args)
    {
        var body = MessageInput.Text.Trim();
        if (body.Length == 0)
        {
            ShowNotice(
                "Сообщение не должно быть пустым.",
                InfoBarSeverity.Warning);
            return;
        }

        var activeTicket = ActiveTicket(_tickets);
        var pending = new PendingSupportMessage(
            Guid.NewGuid().ToString("N"),
            body,
            DateTimeOffset.Now,
            PendingDelivery.Sending);
        _pending.Add(pending);
        MessageInput.Text = string.Empty;
        Render();
        SetBusy(true);
        try
        {
            if (AttachDiagnosticsCheckBox.IsChecked == true)
            {
                await QueueDiagnosticsAsync();
                AttachDiagnosticsCheckBox.IsChecked = false;
            }

            var sentOverSocket = await _socket.SendAsync(
                body,
                activeTicket is null ? SubjectInput.Text : null,
                activeTicket?.Id,
                CancellationToken.None);
            if (sentOverSocket)
            {
                ReplacePending(
                    pending.Id,
                    pending with
                    {
                        Delivery = PendingDelivery.AwaitingConfirmation,
                    });
                ShowNotice(
                    "Сообщение отправлено. Ожидаем подтверждение.",
                    InfoBarSeverity.Success);
            }
            else
            {
                var ticket = await Coordinator.SendSupportMessageAsync(
                    body,
                    SubjectInput.Text,
                    CancellationToken.None);
                MergeTicket(ticket);
                RemoveConfirmedPending(ticket);
                SubjectInput.Text = string.Empty;
                ShowNotice(
                    "Сообщение отправлено.",
                    InfoBarSeverity.Success);
            }
        }
        catch (Exception error) when (
            error is ArgumentException or
                HttpRequestException or
                TaskCanceledException or
                VexApiException or
                NativeClientFlowException)
        {
            ReplacePending(
                pending.Id,
                pending with { Delivery = PendingDelivery.Failed });
            ShowNotice(
                error is NativeClientFlowException flow &&
                    flow.Code == "sign_in_required"
                    ? "Сначала войдите в аккаунт."
                    : "Сообщение сохранено на экране. Повторите отправку.",
                InfoBarSeverity.Error);
        }
        finally
        {
            SetBusy(false);
            Render();
        }
    }

    private async Task QueueDiagnosticsAsync()
    {
        var state = Coordinator.CurrentState;
        var samples = new Dictionary<string, string?>
        {
            ["app_version"] = _services.AppVersion,
            ["platform"] = "windows_native",
            ["os_version"] = Environment.OSVersion.VersionString,
            ["architecture"] =
                System.Runtime.InteropServices.RuntimeInformation
                    .OSArchitecture.ToString(),
            ["device_state"] = state is null
                ? "signed_out"
                : "registered",
            ["location_id"] = state?.LocationId,
            ["socket_state"] = _socket.IsConnected
                ? "connected"
                : _socket.IsReconnecting
                    ? "reconnecting"
                    : "offline",
        };
        await _diagnostics.EnqueueAsync(
            "manual_support_diagnostics",
            "info",
            samples,
            CancellationToken.None);
        var flush = await _diagnostics.FlushAsync(
            CancellationToken.None);
        DraftHintText.Text = flush.Pending == 0
            ? "Диагностика приложена."
            : $"Диагностика сохранена и будет отправлена автоматически (в очереди: {flush.Pending}).";
    }

    private async Task RefreshAsync(
        CancellationToken cancellationToken)
    {
        if (Coordinator.CurrentState is null)
        {
            Render();
            return;
        }

        SetBusy(true);
        try
        {
            _snapshot = await Coordinator.GetSupportSnapshotAsync(
                cancellationToken);
            _tickets = _snapshot.Tickets;
            RemoveConfirmedPending(_tickets);
            SupportNotice.IsOpen = false;
        }
        catch (Exception error) when (
            error is HttpRequestException or
                TaskCanceledException or
                VexApiException or
                NativeClientFlowException)
        {
            if (error is NativeClientFlowException flow &&
                flow.Code == "sign_in_required")
            {
                _snapshot = null;
                _tickets = [];
            }
            else
            {
                ShowNotice(
                    "Не удалось загрузить историю поддержки.",
                    InfoBarSeverity.Warning);
            }
        }
        finally
        {
            SetBusy(false);
            Render();
        }
    }

    private void OnSocketStateChanged(
        object? sender,
        SupportSocketStateChangedEventArgs args) =>
        DispatcherQueue.TryEnqueue(Render);

    private void OnSocketSnapshotReceived(
        object? sender,
        SupportSocketSnapshotEventArgs args) =>
        DispatcherQueue.TryEnqueue(() =>
        {
            _tickets = args.Tickets;
            RemoveConfirmedPending(_tickets);
            Render();
        });

    private void OnSocketTicketReceived(
        object? sender,
        SupportSocketTicketEventArgs args) =>
        DispatcherQueue.TryEnqueue(() =>
        {
            MergeTicket(args.Ticket);
            RemoveConfirmedPending(args.Ticket);
            Render();
        });

    private void MergeTicket(SupportTicket ticket)
    {
        _tickets = _tickets
            .Where(candidate =>
                !string.Equals(
                    candidate.Id,
                    ticket.Id,
                    StringComparison.Ordinal))
            .Append(ticket)
            .OrderByDescending(candidate =>
                ParseTimestamp(candidate.UpdatedAt))
            .ToList();
    }

    private void Render()
    {
        var state = Coordinator.CurrentState;
        var signedIn = state is not null;
        var activeTicket = ActiveTicket(_tickets);
        var messages = DisplayMessagesView(_tickets, _pending);

        SignInRequiredPanel.Visibility = signedIn
            ? Visibility.Collapsed
            : Visibility.Visible;
        ConversationPanel.Visibility = signedIn
            ? Visibility.Visible
            : Visibility.Collapsed;
        ComposerPanel.Visibility = signedIn
            ? Visibility.Visible
            : Visibility.Collapsed;
        SupportStatusText.Text = !signedIn
            ? "Войдите, чтобы открыть чат."
            : _socket.IsConnected
                ? $"{state!.Session.User.Email} · онлайн"
                : _socket.IsReconnecting
                    ? $"{state!.Session.User.Email} · переподключение"
                    : $"{state!.Session.User.Email} · резервный режим";
        RefreshSupportButton.IsEnabled = signedIn &&
            !BusyIndicator.IsActive;
        SubjectInput.Visibility = activeTicket is null
            ? Visibility.Visible
            : Visibility.Collapsed;
        SubjectInput.IsEnabled = signedIn && !BusyIndicator.IsActive;
        MessageInput.IsEnabled = signedIn && !BusyIndicator.IsActive;
        AttachDiagnosticsCheckBox.IsEnabled =
            signedIn && !BusyIndicator.IsActive;
        SendMessageButton.IsEnabled = signedIn &&
            !BusyIndicator.IsActive;
        TicketSummaryPanel.Visibility = activeTicket is null
            ? Visibility.Collapsed
            : Visibility.Visible;
        EmptyStatePanel.Visibility = messages.Count == 0
            ? Visibility.Visible
            : Visibility.Collapsed;
        MessagesList.Visibility = messages.Count == 0
            ? Visibility.Collapsed
            : Visibility.Visible;
        MessagesList.ItemsSource = messages;

        if (activeTicket is not null)
        {
            TicketSubjectText.Text = activeTicket.Subject;
            TicketMetaText.Text =
                $"Статус: {RenderTicketStatus(activeTicket.Status)}";
            TicketUpdatedText.Text =
                $"Последнее обновление: {FormatTimestamp(activeTicket.UpdatedAt)}";
        }

        if (signedIn)
        {
            DraftHintText.Text = activeTicket is null
                ? "Новый тред получит тему из поля выше или из первой строки сообщения."
                : "Сообщение уйдёт в активный тред. При потере сети сохранённая диагностика отправится позже.";
        }
    }

    private void SetBusy(bool busy)
    {
        BusyIndicator.IsActive = busy;
        BusyIndicator.Visibility = busy
            ? Visibility.Visible
            : Visibility.Collapsed;
        RefreshSupportButton.IsEnabled = !busy;
    }

    private void ShowNotice(
        string message,
        InfoBarSeverity severity)
    {
        SupportNotice.Message = message;
        SupportNotice.Severity = severity;
        SupportNotice.IsOpen = true;
    }

    private void ReplacePending(
        string id,
        PendingSupportMessage replacement)
    {
        var index = _pending.FindIndex(item => item.Id == id);
        if (index >= 0)
        {
            _pending[index] = replacement;
        }
    }

    private void RemoveConfirmedPending(
        SupportTicket ticket) =>
        RemoveConfirmedPending([ticket]);

    private void RemoveConfirmedPending(
        IReadOnlyList<SupportTicket> tickets)
    {
        var confirmed = tickets
            .SelectMany(DisplayMessages)
            .Where(message =>
                message.Sender.Equals(
                    "user",
                    StringComparison.OrdinalIgnoreCase))
            .ToList();
        _pending.RemoveAll(pending =>
            confirmed.Any(message =>
                Normalize(message.Body) == Normalize(pending.Body) &&
                Math.Abs(
                    (ParseTimestamp(message.CreatedAt) -
                        pending.CreatedAt).TotalMinutes) <= 5));
    }

    private static SupportTicket? ActiveTicket(
        IReadOnlyList<SupportTicket> tickets) =>
        tickets
            .OrderByDescending(ticket =>
                ParseTimestamp(ticket.UpdatedAt))
            .FirstOrDefault(ticket =>
                ticket.Status.Trim().ToLowerInvariant() is not
                    ("closed" or "resolved"));

    private static IReadOnlyList<SupportMessage> DisplayMessages(
        SupportTicket ticket)
    {
        if (ticket.Messages.Count > 0)
        {
            return ticket.Messages;
        }

        var messages = new List<SupportMessage>();
        if (!string.IsNullOrWhiteSpace(ticket.Message))
        {
            messages.Add(
                new SupportMessage(
                    $"{ticket.Id}-seed",
                    ticket.Id,
                    "user",
                    null,
                    ticket.Message,
                    ticket.CreatedAt));
        }

        if (!string.IsNullOrWhiteSpace(ticket.AdminNote))
        {
            messages.Add(
                new SupportMessage(
                    $"{ticket.Id}-admin",
                    ticket.Id,
                    "admin",
                    null,
                    ticket.AdminNote,
                    ticket.UpdatedAt));
        }

        return messages;
    }

    private static List<SupportMessageView> DisplayMessagesView(
        IReadOnlyList<SupportTicket> tickets,
        IReadOnlyList<PendingSupportMessage> pending)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var confirmed = tickets
            .SelectMany(DisplayMessages)
            .OrderBy(message => ParseTimestamp(message.CreatedAt))
            .Where(message => seen.Add(MessageKey(message)))
            .ToList();
        var deduplicated = new List<SupportMessage>();
        foreach (var message in confirmed)
        {
            var previous = deduplicated.LastOrDefault();
            if (previous is not null &&
                previous.Sender.Equals(
                    message.Sender,
                    StringComparison.OrdinalIgnoreCase) &&
                Normalize(previous.Body) == Normalize(message.Body) &&
                Math.Abs(
                    (ParseTimestamp(previous.CreatedAt) -
                        ParseTimestamp(message.CreatedAt)).TotalSeconds) <= 10)
            {
                continue;
            }

            deduplicated.Add(message);
        }

        var result = deduplicated
            .Select(message => new SupportMessageView(
                RenderSender(message.Sender),
                CollapseDiagnostics(message.Body),
                FormatTimestamp(message.CreatedAt),
                string.Empty,
                new SolidColorBrush(Colors.Transparent)))
            .ToList();
        result.AddRange(
            pending.Select(item => new SupportMessageView(
                "Вы",
                item.Body,
                item.CreatedAt.ToString("HH:mm"),
                item.Delivery switch
                {
                    PendingDelivery.Sending => "Отправка…",
                    PendingDelivery.AwaitingConfirmation => "Доставляется…",
                    _ => "Ошибка",
                },
                new SolidColorBrush(
                    item.Delivery == PendingDelivery.Failed
                        ? Colors.IndianRed
                        : Colors.Transparent))));
        return result;
    }

    private static string CollapseDiagnostics(string body)
    {
        if (!body.Contains("generated_at:", StringComparison.Ordinal) ||
            !(body.Contains("check.", StringComparison.Ordinal) ||
              body.Contains("status:", StringComparison.Ordinal)))
        {
            return body;
        }

        var fields = body
            .Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(line => line.Split(':', 2))
            .Where(parts => parts.Length == 2)
            .ToDictionary(
                parts => parts[0].Trim(),
                parts => parts[1].Trim(),
                StringComparer.OrdinalIgnoreCase);
        var lines = new List<string> { "Автоматическая диагностика" };
        foreach (var key in new[] { "status", "reason", "error" })
        {
            if (fields.TryGetValue(key, out var value))
            {
                lines.Add($"{key}: {value}");
            }
        }

        return string.Join(Environment.NewLine, lines);
    }

    private static string MessageKey(SupportMessage message) =>
        string.Join(
            ':',
            message.Id,
            message.TicketId,
            message.Sender,
            message.CreatedAt,
            Normalize(message.Body));

    private static string Normalize(string value) =>
        string.Join(
            ' ',
            value.Split(
                (char[]?)null,
                StringSplitOptions.RemoveEmptyEntries))
            .ToLowerInvariant();

    private static DateTimeOffset ParseTimestamp(string value) =>
        DateTimeOffset.TryParse(value, out var timestamp)
            ? timestamp
            : DateTimeOffset.MinValue;

    private static string FormatTimestamp(string value)
    {
        var timestamp = ParseTimestamp(value);
        return timestamp == DateTimeOffset.MinValue
            ? value
            : timestamp.ToLocalTime().ToString("dd.MM.yyyy HH:mm");
    }

    private static string RenderTicketStatus(string status) =>
        status.Trim().ToLowerInvariant() switch
        {
            "closed" => "закрыт",
            "resolved" => "решён",
            "open" => "открыт",
            "pending" => "ожидает ответа",
            _ => string.IsNullOrWhiteSpace(status) ? "—" : status,
        };

    private static string RenderSender(string sender) =>
        sender.Trim().ToLowerInvariant() switch
        {
            "admin" or "support" => "Поддержка VEX",
            _ => "Вы",
        };

    private sealed record SupportMessageView(
        string Sender,
        string Body,
        string CreatedAt,
        string Delivery,
        Brush BorderBrush);

    private sealed record PendingSupportMessage(
        string Id,
        string Body,
        DateTimeOffset CreatedAt,
        PendingDelivery Delivery);

    private enum PendingDelivery
    {
        Sending,
        AwaitingConfirmation,
        Failed,
    }
}
