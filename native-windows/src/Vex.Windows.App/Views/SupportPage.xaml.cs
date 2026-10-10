using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Windows.System;
using Vex.Windows.App.Services;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Presentation;
using Vex.Windows.Core.Navigation;

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
    private readonly SupportMessageReconciler _reconciler = new();
    private string? _activeUserId;
    private int _busyOperations;
    private bool _sendInFlight;
    private bool _refreshInFlight;
    private bool _refreshPending;
    private IReadOnlyList<SupportTicket> _tickets = [];
    private NativeSupportSnapshot? _snapshot;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _refreshTimer;
    private CancellationTokenSource? _pageLifetime;
    private CancellationTokenSource? _sessionLifetime;
    private int _activationGeneration;
    private int _socketGeneration;

    private NativeClientCoordinator Coordinator =>
        _services.Coordinator;

    public SupportPage()
    {
        InitializeComponent();
        NavigationCacheMode = NavigationCacheMode.Required;
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        Render();
    }

    private async void OnLoaded(object sender, RoutedEventArgs args)
    {
        if (_pageLifetime is not null) return;
        _pageLifetime = new CancellationTokenSource();
        _sessionLifetime = CancellationTokenSource.CreateLinkedTokenSource(_pageLifetime.Token);
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
        _sessionLifetime?.Dispose();
        _sessionLifetime = null;
        _pageLifetime?.Dispose();
        _pageLifetime = null;
        _refreshPending = false;
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
            var token = _sessionLifetime?.Token;
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
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or
            System.Security.Cryptography.CryptographicException or InvalidOperationException or
            HttpRequestException or VexApiException or NativeClientFlowException)
        {
            if (IsCurrentActivation(generation, cancellationToken))
            {
                Render();
                ShowNotice("Не удалось открыть чат. Попробуйте обновить страницу или откройте поддержку на сайте.",
                    InfoBarSeverity.Warning);
            }
        }
    }

    private async Task ActivateSessionAsync(
        int generation,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var state = Coordinator.CurrentState;
        if (state?.Session.User.Id != _activeUserId)
        {
            _activeUserId = state?.Session.User.Id;
            _snapshot = null;
            _tickets = [];
            _pending.Clear();
            _reconciler.Clear();
            MessageInput.Text = string.Empty;
            SubjectInput.Text = string.Empty;
            AttachDiagnosticsCheckBox.IsChecked = false;
            SupportNotice.IsOpen = false;
            _sessionLifetime?.Cancel();
            _sessionLifetime?.Dispose();
            _sessionLifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        }
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

        _socketGeneration = 0;
        var sessionToken = _sessionLifetime?.Token ?? cancellationToken;
        await _socket.ConnectAsync(
            state.Session.AccessToken,
            sessionToken);
        if (!IsCurrentActivation(generation, cancellationToken) ||
            state.Session.User.Id != Coordinator.CurrentState?.Session.User.Id) return;
        _socketGeneration = generation;
        await RefreshAsync(sessionToken);
        if (!IsCurrentActivation(generation, cancellationToken))
        {
            return;
        }

        StartRefreshTimer();
        _ = _diagnostics.FlushAsync(sessionToken);
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
                _sessionLifetime?.Token ?? new CancellationToken(canceled: true);
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
            _sessionLifetime?.Token ?? new CancellationToken(canceled: true));

    private async void OnSendClick(
        object sender,
        RoutedEventArgs args)
    {
        var state = Coordinator.CurrentState;
        if (_sendInFlight || state is null)
        {
            return;
        }
        var cancellationToken = _sessionLifetime?.Token ?? new CancellationToken(canceled: true);
        if (cancellationToken.IsCancellationRequested)
        {
            return;
        }
        var userId = state.Session.User.Id;
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
            activeTicket?.Id,
            DateTimeOffset.Now,
            PendingDelivery.Sending);
        _pending.Add(pending);
        MessageInput.Text = string.Empty;
        _sendInFlight = true;
        SetBusy(true);
        Render();
        try
        {
            if (AttachDiagnosticsCheckBox.IsChecked == true)
            {
                await QueueDiagnosticsAsync(cancellationToken);
                AttachDiagnosticsCheckBox.IsChecked = false;
            }

            var sentOverSocket = await _socket.SendAsync(
                body,
                activeTicket is null ? SubjectInput.Text : null,
                activeTicket?.Id,
                cancellationToken);
            if (sentOverSocket)
            {
                if (!IsCurrentUser(userId, cancellationToken)) return;
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
                    cancellationToken);
                if (!IsCurrentUser(userId, cancellationToken))
                {
                    return;
                }
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
                OperationCanceledException or
                VexApiException or
                NativeClientFlowException or IOException or UnauthorizedAccessException or
                System.Security.Cryptography.CryptographicException or InvalidOperationException)
        {
            if (_activeUserId != userId) return;
            ReplacePending(
                pending.Id,
                pending with { Delivery = PendingDelivery.Failed });
            if (!IsCurrentUser(userId, cancellationToken)) return;
            ShowNotice(
                error is NativeClientFlowException flow &&
                    flow.Code == "sign_in_required"
                    ? "Сначала войдите в аккаунт."
                    : "Сообщение сохранено на экране. Повторите отправку.",
                InfoBarSeverity.Error);
        }
        finally
        {
            _sendInFlight = false;
            SetBusy(false);
            Render();
        }
    }

    private bool IsCurrentUser(string userId, CancellationToken token) =>
        !token.IsCancellationRequested && _pageLifetime is not null &&
        Coordinator.CurrentState?.Session.User.Id == userId;

    private void OnDraftChanged(object sender, TextChangedEventArgs args)
    {
        if (SendMessageButton is not null) UpdateComposerEnabled();
    }

    private void OnSendAcceleratorInvoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        if (SendMessageButton.IsEnabled) OnSendClick(sender, new RoutedEventArgs());
    }

    private void OnOpenAccountClick(object sender, RoutedEventArgs args) =>
        _services.MainWindow?.NavigateToSection(AppSection.Account);

    private async void OnOpenSupportWebsiteClick(object sender, RoutedEventArgs args)
    {
        if (UiPreviewContext.IsEnabled) return;
        try
        {
            if (!await Launcher.LaunchUriAsync(new Uri("https://vexguard.app/support")))
                ShowNotice("Не удалось открыть поддержку на сайте.", InfoBarSeverity.Warning);
        }
        catch (Exception error) when (error is InvalidOperationException or
            System.Runtime.InteropServices.COMException)
        {
            ShowNotice("Не удалось открыть поддержку на сайте.", InfoBarSeverity.Warning);
        }
    }

    private async Task QueueDiagnosticsAsync(CancellationToken cancellationToken)
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
            cancellationToken);
        var flush = await _diagnostics.FlushAsync(
            cancellationToken);
        DraftHintText.Text = flush.Pending == 0
            ? "Диагностика приложена."
            : $"Диагностика сохранена и будет отправлена автоматически (в очереди: {flush.Pending}).";
    }

    private void OnRetryMessageClick(object sender, RoutedEventArgs args)
    {
        if (_sendInFlight || sender is not Button { Tag: string id })
        {
            return;
        }
        var message = _pending.FirstOrDefault(item => item.Id == id && item.Delivery == PendingDelivery.Failed);
        if (message is null)
        {
            return;
        }
        if (!string.IsNullOrWhiteSpace(MessageInput.Text))
        {
            ShowNotice("Сначала отправьте или очистите текущий черновик.", InfoBarSeverity.Warning);
            return;
        }
        _pending.Remove(message);
        MessageInput.Text = message.Body;
        OnSendClick(sender, args);
    }

    private async Task RefreshAsync(
        CancellationToken cancellationToken)
    {
        if (cancellationToken.IsCancellationRequested) return;
        if (_refreshInFlight)
        {
            _refreshPending = true;
            return;
        }
        var state = Coordinator.CurrentState;
        if (state is null)
        {
            Render();
            return;
        }

        _refreshInFlight = true;
        _refreshPending = false;
        var userId = state.Session.User.Id;
        SetBusy(true);
        Render();
        try
        {
            var snapshot = await Coordinator.GetSupportSnapshotAsync(cancellationToken);
            if (!IsCurrentUser(userId, cancellationToken))
            {
                return;
            }
            _snapshot = snapshot;
            _tickets = snapshot.Tickets;
            RemoveConfirmedPending(_tickets);
            SupportNotice.IsOpen = false;
        }
        catch (Exception error) when (
            error is HttpRequestException or
                OperationCanceledException or
                VexApiException or
                NativeClientFlowException or IOException or UnauthorizedAccessException or
                System.Security.Cryptography.CryptographicException or InvalidOperationException)
        {
            if (!IsCurrentUser(userId, cancellationToken)) return;
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
            _refreshInFlight = false;
            SetBusy(false);
            Render();
            if (_refreshPending && _sessionLifetime is { IsCancellationRequested: false })
            {
                _refreshPending = false;
                _ = RefreshAsync(_sessionLifetime.Token);
            }
        }
    }

    private void OnSocketStateChanged(
        object? sender,
        SupportSocketStateChangedEventArgs args) =>
        DispatcherQueue.TryEnqueue(Render);

    private void OnSocketSnapshotReceived(
        object? sender,
        SupportSocketSnapshotEventArgs args)
    {
        var generation = _activationGeneration;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (generation != _activationGeneration || generation != _socketGeneration || _pageLifetime is null ||
                Coordinator.CurrentState is null)
            {
                return;
            }
            _tickets = args.Tickets;
            RemoveConfirmedPending(_tickets);
            Render();
        });
    }

    private void OnSocketTicketReceived(
        object? sender,
        SupportSocketTicketEventArgs args)
    {
        var generation = _activationGeneration;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (generation != _activationGeneration || generation != _socketGeneration || _pageLifetime is null ||
                Coordinator.CurrentState is null)
            {
                return;
            }
            MergeTicket(args.Ticket);
            RemoveConfirmedPending(args.Ticket);
            Render();
        });
    }

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
        var signedIn = state is not null && state.Session.User.Id == _activeUserId;
        var activeTicket = ActiveTicket(_tickets);
        var messages = DisplayMessagesView(_tickets, _pending);
        if (!signedIn)
        {
            activeTicket = null;
            messages = [];
        }

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
            ? "Поможем с подключением и аккаунтом"
            : _socket.IsConnected
                ? "Команда VEX на связи"
                : _socket.IsReconnecting
                    ? "Восстанавливаем связь с поддержкой"
                    : "Сообщения отправляются через защищённое соединение";
        RefreshSupportButton.IsEnabled = signedIn && !_refreshInFlight;
        SubjectInput.Visibility = activeTicket is null
            ? Visibility.Visible
            : Visibility.Collapsed;
        UpdateComposerEnabled();
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
                ? "Ctrl+Enter — отправить. Если тема не указана, используем первую строку сообщения."
                : "Ctrl+Enter — отправить сообщение в текущее обращение.";
        }
    }

    private void SetBusy(bool busy)
    {
        _busyOperations = Math.Max(0, _busyOperations + (busy ? 1 : -1));
        BusyIndicator.IsActive = _busyOperations > 0;
        BusyIndicator.Visibility = BusyIndicator.IsActive
            ? Visibility.Visible
            : Visibility.Collapsed;
        RefreshSupportButton.IsEnabled = !_refreshInFlight && Coordinator.CurrentState is not null;
        UpdateComposerEnabled();
    }

    private void UpdateComposerEnabled()
    {
        var enabled = !_sendInFlight && Coordinator.CurrentState is not null;
        SendMessageButton.IsEnabled = enabled && !string.IsNullOrWhiteSpace(MessageInput.Text);
        SubjectInput.IsEnabled = enabled;
        MessageInput.IsEnabled = enabled;
        AttachDiagnosticsCheckBox.IsEnabled = enabled;
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
        var acknowledged = _reconciler.ConfirmedPendingIds(
            tickets.SelectMany(DisplayMessages).Select(PresentationMessage),
            _pending.Select(pending => new PendingSupportIdentity(
                pending.Id, pending.TicketId, pending.Body, pending.CreatedAt)));
        _pending.RemoveAll(pending => acknowledged.Contains(pending.Id));
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
        var deduplicated = tickets
            .SelectMany(DisplayMessages)
            .GroupBy(message => SupportConversationPresentation.MessageKey(PresentationMessage(message)),
                StringComparer.Ordinal)
            .Select(group => group.Last())
            .OrderBy(message => ParseTimestamp(message.CreatedAt))
            .ToList();

        var result = deduplicated
            .Select(message => new SupportMessageView(
                RenderSender(message.Sender),
                SupportConversationPresentation.CollapseDiagnostics(message.Body),
                FormatTimestamp(message.CreatedAt),
                string.Empty,
                ColorBrush(0x00000000),
                null,
                Visibility.Collapsed,
                ColorBrush(RenderSender(message.Sender) == "Вы" ? 0x2122D3EEu : 0x7508191Du),
                RenderSender(message.Sender) == "Вы" ? HorizontalAlignment.Right : HorizontalAlignment.Left))
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
                ColorBrush(item.Delivery == PendingDelivery.Failed ? 0x66FF7A7Au : 0x00000000u),
                item.Id,
                item.Delivery == PendingDelivery.Failed
                    ? Visibility.Visible
                    : Visibility.Collapsed,
                ColorBrush(0x2122D3EEu),
                HorizontalAlignment.Right)));
        return result;
    }

    private static SupportConversationMessage PresentationMessage(SupportMessage message) =>
        new(message.Id, message.TicketId, message.Sender, message.Body,
            DateTimeOffset.TryParse(message.CreatedAt, out var timestamp) ? timestamp : null);

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

    private static SolidColorBrush ColorBrush(uint argb) => new(global::Windows.UI.Color.FromArgb(
        (byte)(argb >> 24), (byte)(argb >> 16), (byte)(argb >> 8), (byte)argb));

    private sealed record SupportMessageView(
        string Sender,
        string Body,
        string CreatedAt,
        string Delivery,
        Brush BorderBrush,
        string? PendingId,
        Visibility RetryVisibility,
        Brush Background,
        HorizontalAlignment Alignment);

    private sealed record PendingSupportMessage(
        string Id,
        string Body,
        string? TicketId,
        DateTimeOffset CreatedAt,
        PendingDelivery Delivery);

    private enum PendingDelivery
    {
        Sending,
        AwaitingConfirmation,
        Failed,
    }
}
