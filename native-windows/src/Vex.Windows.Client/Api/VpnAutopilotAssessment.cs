using Vex.Windows.Core.Vpn;

namespace Vex.Windows.Client.Api;

public sealed record VpnAutopilotAssessment(string Cause, bool CanFailover, string UserMessage)
{
    public static VpnAutopilotAssessment Assess(
        string? errorCode, VpnTunnelDiagnostics? diagnostics = null,
        VpnDeviceUsage? usage = null, DateTimeOffset? now = null)
    {
        var code = (errorCode ?? string.Empty).ToLowerInvariant();
        string cause;
        if (code.Contains("entitlement") || code.Contains("subscription")) { cause = "subscription"; }
        else if (code.Contains("permission") || code.Contains("unauthorized") ||
            code.Contains("service_unavailable") || code.Contains("integrity")) { cause = "permission"; }
        else if (code.Contains("profile") || code.Contains("key") || code.Contains("missing_peer")) { cause = "key_or_profile"; }
        else if (code.Contains("dns") || diagnostics is { DnsConfigured: false, AdapterName: not null }) { cause = "dns"; }
        else if (code.Contains("handshake") || code.Contains("endpoint") ||
            usage?.SecondsSinceHandshake > 180 ||
            usage?.ConnectionStatus is "stale" or "no_handshake" or "missing_peer" or "never_connected" ||
            diagnostics?.LatestHandshakeAt < (now ?? DateTimeOffset.UtcNow).AddSeconds(-180)) { cause = "server"; }
        else if (code.Contains("network") || code.Contains("timeout") ||
            diagnostics?.LeakProtection is VpnLeakProtectionState.Blocking or VpnLeakProtectionState.Degraded) { cause = "network"; }
        else { cause = "unknown"; }

        return new(cause, cause is "server" or "dns" or "key_or_profile", cause switch
        {
            "subscription" => "Для VPN нужна активная подписка.",
            "permission" => "Проверьте системный компонент и разрешения VPN.",
            "key_or_profile" => "Обновляем профиль VPN.",
            "dns" => "DNS недоступен. Восстанавливаем VPN.",
            "server" => "Сервер нестабилен. Восстанавливаем VPN.",
            "network" => "Сеть нестабильна. Восстанавливаем соединение.",
            _ => "Пробуем восстановить соединение VPN.",
        });
    }
}
