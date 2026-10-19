using System.Diagnostics;
using System.Text.Json;
using Microsoft.Diagnostics.Tracing;

if (args is ["--self-test"])
{
    StageProjection.SelfTest();
    Console.WriteLine("PASS bounded numeric auth-stage projection and payload rejection");
    return 0;
}
try
{
    if (args is not ["--etl", var filename, "--primary-pid", var process] ||
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
    var projection = Decode(file.FullName, primary);
    Console.WriteLine(JsonSerializer.Serialize(new { schema = "vex.windows-auth-stage-projection.v1", events = projection.Events }));
    return 0;
}
catch
{
    Console.Error.WriteLine("The bounded authentication trace could not be decoded.");
    return 1;
}

static StageProjection Decode(string filename, int primary)
{
    var projection = new StageProjection();
    var deadline = Stopwatch.StartNew();
    using var source = new ETWTraceEventSource(filename);
    source.Dynamic.All += value =>
    {
        if (deadline.Elapsed > TimeSpan.FromSeconds(10)) throw new InvalidOperationException();
        if (value.ProviderGuid != new Guid("5474fab7-6d97-488e-b40f-84ba10c8c1d9") || value.EventName != "Stage") return;
        if (value.PayloadNames.Length != 1 || value.PayloadNames[0] != "stage") throw new InvalidOperationException();
        projection.Add(value.PayloadValue(0), value.ProcessID == primary);
    };
    source.Process();
    return projection;
}

internal sealed record StageObservation(int Stage, bool Primary);
internal sealed class StageProjection
{
    public List<StageObservation> Events { get; } = [];
    public void Add(object? payload, bool primary)
    {
        if (payload is not int stage || stage is < 1 or > 27 || Events.Count >= 256) throw new InvalidOperationException();
        Events.Add(new(stage, primary));
    }
    public static void SelfTest()
    {
        var actual = new StageProjection(); actual.Add(1, true); actual.Add(22, false);
        if (!actual.Events.SequenceEqual(new[] { new StageObservation(1, true), new StageObservation(22, false) })) throw new InvalidOperationException();
        foreach (var bad in new object?[] { null, 0, 28, "private payload", 1L })
        {
            try { actual.Add(bad, true); throw new Exception("Invalid payload accepted."); }
            catch (InvalidOperationException) { }
        }
        while (actual.Events.Count < 256) actual.Add(1, true);
        try { actual.Add(1, true); throw new Exception("Unbounded event count accepted."); }
        catch (InvalidOperationException) { }
    }
}
