using System.Drawing;

namespace Vex.Windows.Setup;

internal sealed class SetupForm : Form
{
    private readonly Button _install = ActionButton("Установить VEX", "SetupInstallButton");
    private readonly Button _repair = ActionButton("Восстановить", "SetupRepairButton");
    private readonly Button _uninstall = ActionButton("Удалить", "SetupUninstallButton");
    private readonly Button _verify = ActionButton("Проверить файлы", "SetupVerifyButton");
    private readonly Label _status = new() { Name = "SetupStatusText", AccessibleName = "Состояние установки", AutoSize = true, MaximumSize = new Size(480, 0) };
    private readonly Label _version = new() { AutoSize = true, ForeColor = Color.DimGray };
    private readonly ProgressBar _progress = new() { Dock = DockStyle.Top, Height = 7, Style = ProgressBarStyle.Marquee, Visible = false };
    private bool _busy;
    private bool _verified;
    private bool _operationPending;
    private bool _actionActive;
    private bool _closeRequested;
    private readonly CancellationTokenSource _lifetime = new();

    internal SetupForm()
    {
        Name = "VexSetupWindow";
        AccessibleName = "Установка VEX";
        Text = "Установка VEX";
        Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!);
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(548, 390);
        MinimumSize = new Size(540, 410);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.White;
        Font = new Font("Segoe UI", 10);

        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill, Padding = new Padding(28), ColumnCount = 1, RowCount = 6,
        };
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.Controls.Add(new Label { Text = "VEX для Windows", AutoSize = true, Font = new Font("Segoe UI", 22, FontStyle.Bold), Margin = new Padding(0, 0, 0, 8) }, 0, 0);
        layout.Controls.Add(_version, 0, 1);
        layout.Controls.Add(new Label
        {
            Text = "Установка приложения и VPN-службы. Windows запросит разрешение администратора для настройки службы.",
            AutoSize = true, MaximumSize = new Size(480, 0), Margin = new Padding(0, 18, 0, 18),
        }, 0, 2);
        layout.Controls.Add(_status, 0, 3);
        var actions = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, WrapContents = true, Margin = new Padding(0, 12, 0, 0) };
        actions.Controls.AddRange([_install, _repair, _uninstall, _verify]);
        layout.Controls.Add(actions, 0, 4);
        layout.Controls.Add(_progress, 0, 5);
        Controls.Add(layout);

        _install.Click += async (_, _) => await RunActionAsync("Install");
        _repair.Click += async (_, _) => await RunActionAsync("Repair");
        _uninstall.Click += async (_, _) =>
        {
            if (MessageBox.Show(this, "Удалить VEX и его VPN-службу для этого пользователя?", "Удаление VEX", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
                await RunActionAsync("Uninstall");
        };
        _verify.Click += async (_, _) => await VerifyAsync();
        Shown += async (_, _) => await VerifyAsync();
        FormClosing += (_, e) =>
        {
            if (_busy)
            {
                e.Cancel = true;
                if (_actionActive) _status.Text = "Дождитесь завершения операции Windows.";
                else { _closeRequested = true; _lifetime.Cancel(); }
            }
        };
        RefreshControls();
    }

    private static Button ActionButton(string text, string name) => new()
    {
        Text = text, Name = name, AccessibleName = text, AutoSize = true, MinimumSize = new Size(145, 40),
        Margin = new Padding(0, 0, 10, 10), FlatStyle = FlatStyle.System,
    };

    private async Task VerifyAsync()
    {
        if (_busy || _operationPending) return;
        _busy = true;
        _verified = false;
        _status.Text = "Проверяем подпись установщика и файлы релиза…";
        RefreshControls();
        try
        {
            var version = await Task.Run(() => { using var bundle = Program.VerifyBundle(_lifetime.Token); return bundle.Version; });
            _version.Text = $"Версия {version}";
            _verified = true;
            _status.Text = "Подпись и файлы проверены. Можно установить или восстановить VEX.";
        }
        catch
        {
            _version.Text = "Установка недоступна";
            _status.Text = "Эта сборка не содержит проверенного подписанного релиза или его файлы изменены. Скачайте полный установочный комплект VEX с официального сайта.";
        }
        finally { _busy = false; RefreshControls(); if (_closeRequested) Close(); }
    }

    private async Task RunActionAsync(string action)
    {
        if (_busy || !_verified || _operationPending) return;
        _busy = true;
        _actionActive = true;
        _status.Text = action switch { "Install" => "Устанавливаем VEX… Подтвердите запрос Windows.", "Repair" => "Восстанавливаем VEX… Подтвердите запрос Windows.", _ => "Удаляем VEX… Подтвердите запрос Windows." };
        RefreshControls();
        try
        {
            var result = await Task.Run(async () =>
            {
                using var bundle = Program.VerifyBundle();
                return await WindowsBootstrapLauncher.InvokeBootstrapAsync(bundle, action).ConfigureAwait(false);
            });
            _operationPending = result.OperationMayStillBeRunning || result.FailureCode == "timeout";
            _status.Text = result.Passed ? action switch
            {
                "Install" => "VEX установлен. Приложение откроется для входа в аккаунт.",
                "Repair" => "VEX восстановлен. Можно открыть приложение.",
                _ => "VEX и его VPN-служба удалены.",
            } : result.FailureCode switch
            {
                "uac_cancelled" => "Запрос администратора отменён. Операцию можно повторить.",
                "verification_failed" => "Файлы релиза не прошли проверку. Скачайте полный комплект с официального сайта.",
                "timeout" or "process_output_timeout" => "Операция Windows не завершилась вовремя и может ещё выполняться. Не запускайте другую установку. Дождитесь её завершения, затем используйте «Восстановить».",
                _ => "Не удалось завершить операцию. Перезагрузите Windows, затем запустите этот установщик и выберите «Восстановить».",
            };
        }
        catch { _status.Text = "Не удалось проверить или запустить установку. Скачайте полный подписанный комплект с официального сайта."; _verified = false; }
        finally { _busy = false; _actionActive = false; RefreshControls(); }
    }

    private void RefreshControls()
    {
        _install.Enabled = _repair.Enabled = _uninstall.Enabled = !_busy && _verified && !_operationPending;
        _verify.Enabled = !_busy && !_operationPending;
        _progress.Visible = _busy;
        UseWaitCursor = _busy;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _lifetime.Dispose();
        base.Dispose(disposing);
    }
}
