using Vex.Windows.Client.Api;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Vpn;

namespace Vex.Windows.App.Services;

internal static class VpnFailurePresentation
{
    internal const string NetworkTimeout = "vpn_network_timeout";

    internal static bool IsNetworkTimeout(Exception error) =>
        error is OperationCanceledException { InnerException: TimeoutException };

    internal static string CodeFromException(Exception error) => error switch
    {
        OperationCanceledException { InnerException: TimeoutException } => NetworkTimeout,
        NativeClientFlowException flow => VpnErrorCode.Sanitize(flow.Code),
        // Only the enumerated public API contract may become user guidance.
        // An unknown server code/message must never become product copy.
        VexApiException { Code: "vpn_entitlement_required" } => "vpn_entitlement_required",
        VexApiException { Code: "vpn_device_limit_reached" } => "vpn_device_limit_reached",
        _ => "vpn_service_unavailable",
    };

    internal static bool RequiresAccountAction(string? code) => code is
        "vpn_entitlement_required" or "vpn_device_limit_reached";

    internal static bool IsTerminalError(string? code) =>
        VpnRecoveryPolicy.IsTerminalError(code) || code == "vpn_device_limit_reached";

    internal static string? MessageFor(string? code) => code switch
    {
        "vpn_entitlement_required" =>
            "Для подключения нужна активная подписка. Откройте «Аккаунт», чтобы выбрать или продлить тариф.",
        "vpn_device_limit_reached" =>
            "Достигнут лимит устройств. Откройте «Аккаунт», чтобы проверить устройства и тариф. Ненужное устройство можно отключить на сайте VEX.",
        NetworkTimeout =>
            "Сервер VEX не ответил вовремя. Проверьте интернет и повторите подключение.",
        _ => null,
    };
}
