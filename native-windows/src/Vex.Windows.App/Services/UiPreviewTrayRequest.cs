#if DEBUG
namespace Vex.Windows.App.Services;

// A nonce owns one immutable completed receipt. Callers cannot supply a path,
// another process ID, or an empty filename through command metadata.
internal sealed class UiPreviewTrayRequest
{
    internal UiPreviewTrayRequest(Guid id, string scenario)
    {
        if (id == Guid.Empty) throw new ArgumentException("A tray request requires a nonce.", nameof(id));
        if (scenario is not ("locked" or "reset" or "signed-out"))
            throw new ArgumentOutOfRangeException(nameof(scenario));
        Id = id;
        Scenario = scenario;
    }

    internal Guid Id { get; }
    internal string Scenario { get; }
    internal string CompletedPath => Path.Combine(Path.GetTempPath(),
        $"vex-ui-preview-tray-{Environment.ProcessId}-{Scenario}-{Id:N}.json");
    internal string ProgressPath => CompletedPath + ".progress.json";

    internal static bool TryParse(string? arguments, out UiPreviewTrayRequest? request)
    {
        request = null;
        if (!UiPreviewContext.IsEnabled || UiPreviewContext.StateDirectory is null || arguments is null) return false;
        // Unpackaged AppInstance launch data includes the full command line.
        // Remove only our own executable, never an arbitrary leading token.
        var executable = Environment.ProcessPath;
        if (executable is not null)
        {
            foreach (var executablePrefix in new[] { "\"" + executable + "\" ", executable + " " })
                if (arguments.StartsWith(executablePrefix, StringComparison.OrdinalIgnoreCase))
                {
                    arguments = arguments[executablePrefix.Length..];
                    break;
                }
        }
        var tokens = arguments.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (tokens.Length != 2) return false;
        var commands = tokens.Where(value => value is "--ui-smoke-tray-connect" or
            "--ui-smoke-tray-connect-locked" or "--ui-smoke-tray-reset").ToArray();
        var metadata = tokens.Where(value => value.StartsWith(UiPreviewContext.TrayRequestPrefix,
            StringComparison.Ordinal)).ToArray();
        var prefix = UiPreviewContext.TrayRequestPrefix + "=";
        if (commands.Length != 1 || metadata.Length != 1 || !metadata[0].StartsWith(prefix, StringComparison.Ordinal))
            return false;
        var nonce = metadata[0][prefix.Length..];
        if (!Guid.TryParseExact(nonce, "N", out var id) || id == Guid.Empty || nonce != id.ToString("N")) return false;
        var scenario = commands[0] == "--ui-smoke-tray-connect-locked" ? "locked" :
            commands[0] == "--ui-smoke-tray-reset" ? "reset" : "signed-out";
        request = new(id, scenario);
        return true;
    }
}
#endif
