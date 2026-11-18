using System.Diagnostics;
using System.Text.Json;
using Microsoft.Diagnostics.Tracing;
using Vex.Windows.Client.Auth;

if (args is ["--stage-catalog"] or ["--startup-stage-catalog"])
{
    var startupCatalog = args is ["--startup-stage-catalog"];
    var values = Enum.GetValues(startupCatalog ? typeof(AppStartupStage) : typeof(AuthActivationStage)).Cast<Enum>();
    Console.WriteLine(JsonSerializer.Serialize(new
    {
        schema = "vex.windows-stage-catalog.v1",
        provider_guid = AuthActivationTrace.ProviderGuid,
        kind = startupCatalog ? "startup" : "auth",
        stages = values.Select(value => new { id = Convert.ToInt32(value), name = value.ToString() }),
    }));
    return 0;
}

if (args is ["--self-test"])
{
    StageProjection.SelfTest();
    Console.WriteLine("PASS bounded auth/startup stage projections, legacy event isolation and payload rejection");
    return 0;
}
try
{
    var startup = args is ["--etl", _, "--primary-pid", _, "--startup"];
    var input = startup ? args[..4] : args;
    if (input is not ["--etl", var filename, "--primary-pid", var process] ||
        !int.TryParse(process, out var primary) || primary < 0 || !OperatingSystem.IsWindows() ||
        Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" ||
        Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") != "github-hosted")
        throw new InvalidOperationException();
    var root = Path.GetFullPath(Environment.GetEnvironmentVariable("RUNNER_TEMP") ?? "")
        .TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
    var file = new FileInfo(Path.GetFullPath(filename));
    if (!file.FullName.StartsWith(root, StringComparison.OrdinalIgnoreCase) || file.Length is <= 0 or > 9 * 1024 * 1024)
        throw new InvalidOperationException();
    for (FileSystemInfo? current = file; current is not null; current = current is DirectoryInfo directory ? directory.Parent : file.Directory)
        if ((current.Attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidOperationException();
    var projection = Decode(file.FullName, primary, startup);
    Console.WriteLine(JsonSerializer.Serialize(new { schema = startup ? "vex.windows-startup-stage-projection.v1" : "vex.windows-auth-stage-projection.v1", events = projection.Events }));
    return 0;
}
catch
{
    Console.Error.WriteLine("The bounded authentication trace could not be decoded.");
    return 1;
}

static StageProjection Decode(string filename, int primary, bool startup)
{
    var projection = new StageProjection(startup);
    var deadline = Stopwatch.StartNew();
    using var source = new ETWTraceEventSource(filename);
    source.Dynamic.All += value =>
    {
        if (deadline.Elapsed > TimeSpan.FromSeconds(10)) throw new InvalidOperationException();
        if (!projection.Accepts(value.ProviderGuid, value.EventName)) return;
        if (value.PayloadNames.Length != 1 || value.PayloadNames[0] != "stage") throw new InvalidOperationException();
        projection.Add(value.PayloadValue(0), value.ProcessID == primary);
    };
    source.Process();
    return projection;
}

internal sealed record StageObservation(int Stage, bool Primary);
internal sealed class StageProjection(bool startup = false)
{
    private static readonly Guid ProviderId = new(AuthActivationTrace.ProviderGuid);
    public List<StageObservation> Events { get; } = [];
    public bool Accepts(Guid provider, string? name) => provider == ProviderId &&
        string.Equals(name, startup ? "StartupStage" : "Stage", StringComparison.Ordinal);
    public void Add(object? payload, bool primary)
    {
        if (payload is not int stage ||
            !(startup ? Enum.IsDefined((AppStartupStage)stage) : Enum.IsDefined((AuthActivationStage)stage)) ||
            Events.Count >= 256) throw new InvalidOperationException();
        Events.Add(new(stage, primary));
    }
    public static void SelfTest()
    {
        if (!Enum.GetValues<AuthActivationStage>().Select(value => (int)value).SequenceEqual(Enumerable.Range(1, 32)) ||
            !Enum.GetValues<AppStartupStage>().Select(value => (int)value).SequenceEqual(Enumerable.Range(1, 13))) throw new InvalidOperationException();
        var actual = new StageProjection(); actual.Add(1, true); actual.Add(22, false); actual.Add(32, true);
        if (!actual.Events.SequenceEqual(new[] { new StageObservation(1, true), new StageObservation(22, false), new StageObservation(32, true) })) throw new InvalidOperationException();
        foreach (var bad in new object?[] { null, 0, 33, "private payload", 1L })
        {
            try { actual.Add(bad, true); throw new Exception("Invalid payload accepted."); }
            catch (InvalidOperationException) { }
        }
        while (actual.Events.Count < 256) actual.Add(1, true);
        try { actual.Add(1, true); throw new Exception("Unbounded event count accepted."); }
        catch (InvalidOperationException) { }
        var startupProjection = new StageProjection(startup: true);
        startupProjection.Add(1, true); startupProjection.Add(13, false);
        if (!startupProjection.Events.SequenceEqual(new[] { new StageObservation(1, true), new StageObservation(13, false) }) ||
            actual.Accepts(ProviderId, "StartupStage") || startupProjection.Accepts(ProviderId, "Stage") ||
            actual.Accepts(Guid.Empty, "Stage") || startupProjection.Accepts(Guid.Empty, "StartupStage") ||
            !actual.Accepts(ProviderId, "Stage") || !startupProjection.Accepts(ProviderId, "StartupStage")) throw new InvalidOperationException();
        foreach (var bad in new object?[] { null, 0, 14, 32, "private payload", 1L })
        {
            try { startupProjection.Add(bad, true); throw new Exception("Invalid startup payload accepted."); }
            catch (InvalidOperationException) { }
        }
        while (startupProjection.Events.Count < 256) startupProjection.Add(1, true);
        try { startupProjection.Add(1, true); throw new Exception("Unbounded startup event count accepted."); }
        catch (InvalidOperationException) { }
    }
}
