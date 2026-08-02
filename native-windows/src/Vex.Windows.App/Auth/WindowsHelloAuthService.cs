using Windows.Security.Credentials.UI;

namespace Vex.Windows.App.Auth;

public sealed record WindowsHelloAvailability(
    bool IsAvailable,
    string Label);

public sealed record WindowsHelloPromptResult(
    bool Success,
    string Message);

public sealed class WindowsHelloAuthService
{
    public async Task<WindowsHelloAvailability> GetAvailabilityAsync(
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
        {
            return new WindowsHelloAvailability(
                false,
                "Windows Hello требует Windows 11 для desktop verification");
        }

        var availability = await UserConsentVerifier.CheckAvailabilityAsync();
        return availability == UserConsentVerifierAvailability.Available
            ? new WindowsHelloAvailability(
                true,
                "Windows Hello")
            : new WindowsHelloAvailability(
                false,
                "Windows Hello");
    }

    public async Task<WindowsHelloPromptResult> VerifyAsync(
        nint windowHandle,
        string message,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
        {
            return new WindowsHelloPromptResult(
                false,
                "Windows Hello для desktop-приложения требует Windows 11.");
        }

        var result = await UserConsentVerifierInterop
            .RequestVerificationForWindowAsync(
                windowHandle,
                message);
        return result switch
        {
            UserConsentVerificationResult.Verified =>
                new WindowsHelloPromptResult(
                    true,
                    "Подтверждение выполнено."),
            UserConsentVerificationResult.Canceled =>
                new WindowsHelloPromptResult(
                    false,
                    "Проверка личности отменена."),
            UserConsentVerificationResult.DeviceBusy =>
                new WindowsHelloPromptResult(
                    false,
                    "Windows Hello сейчас занят. Повторите попытку."),
            UserConsentVerificationResult.DeviceNotPresent =>
                new WindowsHelloPromptResult(
                    false,
                    "Windows Hello недоступен на этом устройстве."),
            UserConsentVerificationResult.DisabledByPolicy =>
                new WindowsHelloPromptResult(
                    false,
                    "Windows Hello отключен политикой Windows."),
            UserConsentVerificationResult.NotConfiguredForUser =>
                new WindowsHelloPromptResult(
                    false,
                    "Настройте PIN или биометрию Windows Hello и повторите."),
            UserConsentVerificationResult.RetriesExhausted =>
                new WindowsHelloPromptResult(
                    false,
                    "Windows Hello временно заблокирован после неудачных попыток."),
            _ =>
                new WindowsHelloPromptResult(
                    false,
                    "Windows Hello сейчас недоступен."),
        };
    }
}
