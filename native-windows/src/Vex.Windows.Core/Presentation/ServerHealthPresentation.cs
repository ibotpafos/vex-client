namespace Vex.Windows.Core.Presentation;

public enum ServerHealthStatus
{
    Unknown,
    Checking,
    Available,
    Degraded,
    Unavailable,
}

public readonly record struct ServerHealthLocation(string? Status, string? Availability, int HealthyNodes);

public static class ServerHealthPresentation
{
    public static ServerHealthStatus Evaluate(
        IEnumerable<ServerHealthLocation> locations,
        bool authenticated,
        bool loading)
    {
        ArgumentNullException.ThrowIfNull(locations);
        if (!authenticated) return ServerHealthStatus.Unknown;
        var catalog = locations.ToArray();
        if (catalog.Length == 0) return loading ? ServerHealthStatus.Checking : ServerHealthStatus.Unavailable;
        var healthy = catalog.Count(location => location.HealthyNodes > 0 &&
            location.Status?.Trim().ToLowerInvariant() is "active" or "online" or "healthy" &&
            location.Availability?.Trim().ToLowerInvariant() is not ("maintenance" or "unavailable" or "retired"));
        return healthy == catalog.Length ? ServerHealthStatus.Available :
            healthy > 0 ? ServerHealthStatus.Degraded : ServerHealthStatus.Unavailable;
    }

    public static string Title(ServerHealthStatus status) => status switch
    {
        ServerHealthStatus.Checking => "Проверяем серверы",
        ServerHealthStatus.Available => "Серверы работают",
        ServerHealthStatus.Degraded => "Часть серверов недоступна",
        ServerHealthStatus.Unavailable => "Серверы недоступны",
        _ => "Статус серверов неизвестен",
    };
}
