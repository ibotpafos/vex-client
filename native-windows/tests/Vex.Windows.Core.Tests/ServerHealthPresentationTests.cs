using Vex.Windows.Core.Presentation;

internal static class ServerHealthPresentationTests
{
    public static void Run()
    {
        ServerHealthLocation[] healthy = [new("healthy", "available", 1), new(" ONLINE ", "available", 2), new("active", "available", 1)];
        Require(ServerHealthPresentation.Evaluate(healthy, true, false) == ServerHealthStatus.Available,
            "Every healthy advertised location must show the available state, including normalized Mac status aliases.");
        Require(ServerHealthPresentation.Evaluate([healthy[0], new("offline", "available", 0)], true, false) == ServerHealthStatus.Degraded,
            "One available location must not hide a partial outage behind a green status dot.");
        foreach (var availability in new[] { "maintenance", " UNAVAILABLE ", "retired" })
            Require(ServerHealthPresentation.Evaluate([new("healthy", availability, 2)], true, false) == ServerHealthStatus.Unavailable,
                "A positive healthy-node count must not make an unavailable or maintenance location green.");
        Require(ServerHealthPresentation.Evaluate([new("healthy", "available", 0), new("offline", "available", 1)], true, false) == ServerHealthStatus.Unavailable,
            "An entirely unavailable catalog must be reported as unavailable rather than partially degraded.");
        Require(ServerHealthPresentation.Evaluate([], true, false) == ServerHealthStatus.Unavailable &&
            ServerHealthPresentation.Evaluate([], true, true) == ServerHealthStatus.Checking &&
            ServerHealthPresentation.Evaluate(healthy, false, false) == ServerHealthStatus.Unknown,
            "An empty/loading catalog and a signed-out session must remain distinct.");
        Require(ServerHealthPresentation.Title(ServerHealthStatus.Unavailable) == "Серверы недоступны" &&
            ServerHealthPresentation.Title(ServerHealthStatus.Degraded) == "Часть серверов недоступна",
            "The accessible status must distinguish partial and total outages.");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
