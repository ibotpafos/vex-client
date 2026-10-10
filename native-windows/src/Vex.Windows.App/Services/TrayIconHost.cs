using Microsoft.UI.Dispatching;
using System.ComponentModel;
using System.Drawing;
using System.Security.Cryptography;
using System.Windows.Forms;
using Vex.Windows.Client.Api;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Navigation;
using Vex.Windows.Core.Presentation;
using Vex.Windows.Core.Vpn;
using Vex.Windows.Core.Vpn.Ipc;

namespace Vex.Windows.App.Services;

public sealed class TrayIconHost : IDisposable
{
    private readonly MainWindow _window;
    private readonly AppServices _services;
    private readonly Action _exitApplication;
    private readonly DispatcherQueue _dispatcherQueue;
    private readonly NotifyIcon _notifyIcon;
    private readonly ContextMenuStrip _contextMenu;
    private readonly ToolStripMenuItem _statusMenuItem;
    private readonly ToolStripMenuItem _toggleConnectionMenuItem;
    private readonly ToolStripMenuItem _toggleWindowMenuItem;
    private readonly ToolStripMenuItem _updateMenuItem;
    private readonly ToolStripMenuItem _exitMenuItem;
    private readonly SemaphoreSlim _requestGate = new(1, 1);
    private readonly CancellationTokenSource _lifetime = new();

    private VpnConnectionSnapshot _snapshot =
        VpnConnectionSnapshot.Disconnected();
    private string? _lastNotifiedUpdateVersion;
    private bool _disposed;
    private bool _requestInFlight;
    private bool _exitInFlight;

    public TrayIconHost(
        MainWindow window,
        AppServices services,
        Action exitApplication)
    {
        _window = window;
        _services = services;
        _exitApplication = exitApplication;
        _dispatcherQueue = window.DispatcherQueue;
        _window.ShellWindowVisibilityChanged += OnShellWindowVisibilityChanged;

        _statusMenuItem = new ToolStripMenuItem("Статус: проверка…")
        {
            Enabled = false,
        };
        _toggleConnectionMenuItem = new ToolStripMenuItem("Подключить");
        _toggleWindowMenuItem = new ToolStripMenuItem("Скрыть окно");
        _updateMenuItem = new ToolStripMenuItem("Обновления")
        {
            Visible = false,
        };
        _exitMenuItem = new ToolStripMenuItem("Выход");

        _contextMenu = new ContextMenuStrip();
        _contextMenu.Items.AddRange(
        [
            _statusMenuItem,
            _toggleConnectionMenuItem,
            _toggleWindowMenuItem,
            _updateMenuItem,
            new ToolStripSeparator(),
            _exitMenuItem,
        ]);
        _contextMenu.Opening += OnContextMenuOpening;

        _toggleConnectionMenuItem.Click += OnToggleConnectionClick;
        _toggleWindowMenuItem.Click += OnToggleWindowClick;
        _updateMenuItem.Click += OnUpdateClick;
        _exitMenuItem.Click += OnExitClick;

        _notifyIcon = new NotifyIcon
        {
            Icon = SystemIcons.Shield,
            Text = "VEX",
            Visible = true,
            ContextMenuStrip = _contextMenu,
        };
        _notifyIcon.MouseClick += OnNotifyIconMouseClick;
        _notifyIcon.BalloonTipClicked += OnUpdateClick;
        _services.UpdateService.Changed += OnUpdateSnapshotChanged;
        _services.VpnUiState.Changed += OnVpnStateChanged;

        Render();
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _lifetime.Cancel();
        _contextMenu.Opening -= OnContextMenuOpening;
        _window.ShellWindowVisibilityChanged -= OnShellWindowVisibilityChanged;
        _toggleConnectionMenuItem.Click -= OnToggleConnectionClick;
        _toggleWindowMenuItem.Click -= OnToggleWindowClick;
        _updateMenuItem.Click -= OnUpdateClick;
        _exitMenuItem.Click -= OnExitClick;
        _notifyIcon.MouseClick -= OnNotifyIconMouseClick;
        _notifyIcon.BalloonTipClicked -= OnUpdateClick;
        _services.UpdateService.Changed -= OnUpdateSnapshotChanged;
        _services.VpnUiState.Changed -= OnVpnStateChanged;
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
        _contextMenu.Dispose();
        // An in-flight tray operation may still release this process-lifetime
        // gate after the shell has started closing.
    }

    public async Task RefreshStatusAsync(CancellationToken cancellationToken)
    {
        if (_disposed)
        {
            return;
        }

        await RunSerializedAsync(
            async token =>
            {
                var response = await _services.VpnUiState.RefreshAsync(token);
                await ApplyResponseAsync(response);
            },
            cancellationToken).ConfigureAwait(false);
    }

    private async void OnContextMenuOpening(
        object? sender,
        CancelEventArgs args)
    {
        try
        {
            await RefreshStatusAsync(CancellationToken.None);
        }
        catch (OperationCanceledException)
        {
        }
    }

    private void OnShellWindowVisibilityChanged(
        object? sender,
        EventArgs args) =>
        Render();

    private void OnUpdateSnapshotChanged(object? sender, EventArgs args)
    {
        if (_disposed)
        {
            return;
        }

        _dispatcherQueue.TryEnqueue(() =>
        {
            if (_disposed) return;
            var update = _services.UpdateService.CurrentSnapshot;
            Render();
            var version = update.Release?.Version;
            if (!update.UpdateAvailable ||
                string.IsNullOrWhiteSpace(version) ||
                string.Equals(
                    _lastNotifiedUpdateVersion,
                    version,
                    StringComparison.Ordinal))
            {
                return;
            }

            _lastNotifiedUpdateVersion = version;
            _notifyIcon.ShowBalloonTip(
                5000,
                update.Required
                    ? "Требуется обновление VEX"
                    : "Доступно обновление VEX",
                $"Версия {version} готова к установке.",
                update.Required
                    ? ToolTipIcon.Warning
                    : ToolTipIcon.Info);
        });
    }

    private void OnUpdateClick(object? sender, EventArgs args)
    {
        if (_disposed)
        {
            return;
        }

        _window.ShowShellWindow();
        _window.Activate();
        _window.BringToFront();
        _window.NavigateToSection(AppSection.Settings);
    }

    private async void OnToggleConnectionClick(object? sender, EventArgs args)
    {
        try
        {
            await RunSerializedAsync(
                async token =>
                {
                    var disconnect = VpnConnectionActionPolicy.ShouldDisconnect(_services.VpnUiState.Snapshot);
                    _services.VpnUiState.MarkConnectionDesired(!disconnect);
                    var response = await _services.VpnUiState.RunAsync(
                        requestToken => disconnect
                            ? _services.VpnClient.DisconnectAsync(requestToken)
                            : ConnectAfterUpdateCheckAsync(requestToken), token);
                    await ApplyResponseAsync(response);
                },
                CancellationToken.None).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
        }
    }

    private void OnToggleWindowClick(object? sender, EventArgs args)
    {
        if (_window.IsShellWindowVisible)
        {
            _window.HideShellWindow();
        }
        else
        {
            _window.ShowShellWindow();
            _window.Activate();
            _window.BringToFront();
        }

        Render();
    }

    private void OnNotifyIconMouseClick(
        object? sender,
        MouseEventArgs args)
    {
        if (args.Button != MouseButtons.Left)
        {
            return;
        }

        if (!_window.IsShellWindowVisible)
        {
            _window.ShowShellWindow();
        }

        _window.Activate();
        _window.BringToFront();
        Render();
    }

    private async void OnExitClick(object? sender, EventArgs args)
    {
        if (_disposed || _exitInFlight) return;
        _exitInFlight = true;
        _services.VpnUiState.MarkConnectionDesired(false);
        Render();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        timeout.CancelAfter(TimeSpan.FromSeconds(65));
        try
        {
            var response = await _services.VpnUiState.RunAsync(
                async token =>
                {
                    var cleanup = await _services.VpnClient.DisconnectAsync(token).ConfigureAwait(false);
                    if (cleanup.Success && cleanup.Snapshot.Phase == VpnConnectionPhase.Disconnected)
                        _services.VpnUiState.CompleteShutdown();
                    return cleanup;
                }, timeout.Token).ConfigureAwait(false);
            if (!response.Success || response.Snapshot.Phase != VpnConnectionPhase.Disconnected)
            {
                await ShowExitFailureAsync(response.ErrorCode).ConfigureAwait(false);
                return;
            }
            await InvokeOnUiThreadAsync(() =>
            {
                if (_disposed) return;
                _notifyIcon.Visible = false;
                _exitApplication();
            }).ConfigureAwait(false);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or
            CryptographicException or HttpRequestException or InvalidOperationException or
            NativeClientFlowException or VexApiException or VpnIpcProtocolException or OperationCanceledException)
        {
            await ShowExitFailureAsync(error is NativeClientFlowException flow ? flow.Code : null)
                .ConfigureAwait(false);
        }
        finally
        {
            _exitInFlight = false;
            await InvokeOnUiThreadAsync(Render).ConfigureAwait(false);
        }
    }

    private Task ShowExitFailureAsync(string? errorCode) => InvokeOnUiThreadAsync(() =>
    {
        if (_disposed) return;
        _notifyIcon.Visible = true;
        _window.ShowShellWindow();
        _window.Activate();
        _window.BringToFront();
        _notifyIcon.ShowBalloonTip(5000, "Не удалось завершить VEX",
            $"Подтвердить отключение VPN не удалось. Повторите выход. {ErrorMessage(errorCode)}",
            ToolTipIcon.Warning);
    });

    private async Task RunSerializedAsync(
        Func<CancellationToken, Task> operation,
        CancellationToken cancellationToken)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _lifetime.Token);
        await _requestGate.WaitAsync(linked.Token).ConfigureAwait(false);
        try
        {
            if (_disposed)
            {
                return;
            }

            _requestInFlight = true;
            await InvokeOnUiThreadAsync(() =>
            {
                if (_disposed)
                {
                    return;
                }

                _toggleConnectionMenuItem.Enabled = false;
                _toggleWindowMenuItem.Enabled = false;
                _statusMenuItem.Text = "Статус: обновление…";
            }).ConfigureAwait(false);

            await operation(linked.Token).ConfigureAwait(false);
        }
        catch (Exception error) when (
            error is IOException
                or UnauthorizedAccessException
                or CryptographicException
                or HttpRequestException
                or InvalidOperationException
                or NativeClientFlowException
                or VexApiException
                or VpnIpcProtocolException)
        {
            var errorCode = error is NativeClientFlowException flow
                ? flow.Code
                : "vpn_service_unavailable";
            await InvokeOnUiThreadAsync(() =>
            {
                if (_disposed)
                {
                    return;
                }

                Render();
                _notifyIcon.ShowBalloonTip(
                    3000,
                    "VEX",
                    ErrorMessage(errorCode),
                    ToolTipIcon.Error);
            }).ConfigureAwait(false);
        }
        finally
        {
            _requestInFlight = false;
            try
            {
                await InvokeOnUiThreadAsync(() =>
                {
                    if (!_disposed) Render();
                }).ConfigureAwait(false);
            }
            finally { _requestGate.Release(); }
        }
    }

    private Task ApplyResponseAsync(VpnServiceResponse response)
    {
        return InvokeOnUiThreadAsync(() =>
        {
            if (_disposed)
            {
                return;
            }

            Render();
            if (!response.Success)
            {
                _notifyIcon.ShowBalloonTip(
                    3000,
                    "VEX",
                    ErrorMessage(response.ErrorCode),
                    ToolTipIcon.Warning);
            }
        });
    }

    private async Task<VpnServiceResponse> ConnectAfterUpdateCheckAsync(
        CancellationToken cancellationToken)
    {
        var update = _services.UpdateService.CurrentSnapshot;
        if (update.UpdateAvailable && update.Required)
        {
            throw new NativeClientFlowException("required_update");
        }

        return await _services.ProductParity.ConnectAsync(
            _services.Coordinator, _services.Preferences.Current,
            cancellationToken).ConfigureAwait(false);
    }

    private void OnVpnStateChanged(object? sender, EventArgs args)
    {
        if (_disposed) return;
        _dispatcherQueue.TryEnqueue(() =>
        {
            if (_disposed) return;
            _snapshot = _services.VpnUiState.Snapshot;
            Render();
        });
    }

    private void Render()
    {
        if (_disposed) return;
        _snapshot = _services.VpnUiState.Snapshot;
        var (statusText, toggleConnectionText, toggleEnabled) =
            BuildMenuState(_snapshot);
        _statusMenuItem.Text = $"Статус: {statusText}";
        _toggleConnectionMenuItem.Text = toggleConnectionText;
        _toggleConnectionMenuItem.Enabled = toggleEnabled && !_disposed && !_requestInFlight && !_exitInFlight;
        _exitMenuItem.Enabled = !_exitInFlight && !_disposed;
        _toggleWindowMenuItem.Text = _window.IsShellWindowVisible
            ? "Скрыть окно"
            : "Показать окно";
        _toggleWindowMenuItem.Enabled = !_disposed;
        var update = _services.UpdateService.CurrentSnapshot;
        _updateMenuItem.Visible = update.UpdateAvailable;
        _updateMenuItem.Enabled = update.UpdateAvailable && !_disposed;
        _updateMenuItem.Text = update.UpdateAvailable
            ? $"Установить VEX {update.Release?.Version ?? string.Empty}"
            : "Обновления";
        _notifyIcon.Text = BuildTrayText(statusText, _window.IsShellWindowVisible);
    }

    private static (string StatusText, string ToggleText, bool ToggleEnabled) BuildMenuState(
        VpnConnectionSnapshot snapshot) =>
        snapshot.Phase switch
        {
            VpnConnectionPhase.Disconnected =>
                ("Не подключено", "Подключить", true),
            VpnConnectionPhase.Connecting =>
                ("Подключение…", "Подключение…", false),
            VpnConnectionPhase.Connected =>
                ($"Защищено{RenderLocation(snapshot.LocationId)}", "Отключить", true),
            VpnConnectionPhase.Disconnecting =>
                ("Отключение…", "Отключение…", false),
            VpnConnectionPhase.Error =>
                ("Нужна проверка", VpnConnectionActionPolicy.ShouldDisconnect(snapshot) ? "Отключить" : "Повторить", true),
            _ =>
                ("Неизвестное состояние", "Повторить", true),
        };

    private static string BuildTrayText(string statusText, bool isWindowVisible)
    {
        var suffix = isWindowVisible ? "окно открыто" : "в фоне";
        var text = $"VEX — {statusText}; {suffix}";
        return text.Length <= 63
            ? text
            : text[..63];
    }

    private static string RenderLocation(string? locationId) =>
        string.IsNullOrWhiteSpace(locationId)
            ? string.Empty
            : $" · {NativeLocationLabel.Russian(locationId)}";

    private Task InvokeOnUiThreadAsync(Action action)
    {
        if (_disposed) return Task.CompletedTask;
        if (_dispatcherQueue.HasThreadAccess)
        {
            action();
            return Task.CompletedTask;
        }

        var completion = new TaskCompletionSource<object?>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        if (!_dispatcherQueue.TryEnqueue(() =>
            {
                try
                {
                    action();
                    completion.SetResult(null);
                }
                catch (Exception error)
                {
                    completion.SetException(error);
                }
            }))
        {
            completion.SetException(
                new InvalidOperationException(
                    "UI dispatcher is unavailable."));
        }

        return completion.Task;
    }

    private static string ErrorMessage(string? errorCode) => errorCode switch
    {
        "unauthorized" => "Требуется восстановить безопасную установку VEX.",
        "tunnel_runtime_missing" => "Компоненты VPN повреждены или отсутствуют.",
        "tunnel_adapter_timeout" => "Сетевой адаптер VPN не запустился вовремя.",
        "sign_in_required" => "Сначала войдите в аккаунт на вкладке «Аккаунт».",
        "vpn_profile_unsigned" => "Сервер вернул неподписанный VPN-профиль.",
        "vpn_profile_revoked" => "Это устройство отозвано. Войдите снова.",
        "vpn_key_rotation_required" => "Требуется безопасное обновление ключа устройства.",
        "required_update" => "Перед подключением установите обязательное обновление VEX.",
        "vpn_service_unavailable" => "Служба VEX VPN недоступна. Перезапустите приложение.",
        _ => "Не удалось выполнить операцию VPN.",
    };
}
