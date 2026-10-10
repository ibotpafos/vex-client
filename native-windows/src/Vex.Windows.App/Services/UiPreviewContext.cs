using System.Security.Cryptography;
using System.Text;

namespace Vex.Windows.App.Services;

/// <summary>Debug-only, isolated UI fixtures. Release builds cannot enable them.</summary>
internal static class UiPreviewContext
{
    internal const string ProtocolScheme = "vexguard-ui-preview";
#if DEBUG
    public static bool IsSupported => true;
#else
    public static bool IsSupported => false;
#endif
    public static bool IsEnabled { get; private set; }
    public static bool IsAuthenticated { get; private set; }
    public static bool IsPreviewRequest { get; private set; }
    public static bool IsCommandOnly { get; private set; }
    public static string? StateDirectory { get; private set; }
    public static string InstanceKey { get; private set; } = "main";

    public static void Initialize(string[] arguments, Uri? protocolUri)
    {
        var signedOut = arguments.Contains("--signed-out-ui-preview", StringComparer.Ordinal);
        var fixtures = arguments.Contains("--focus-pulse-ui-preview", StringComparer.Ordinal);
        var command = arguments.Contains("--ui-smoke-exit", StringComparer.Ordinal) ||
            IsActivationUri(protocolUri);
        IsPreviewRequest = signedOut || fixtures || command;
        if (!IsPreviewRequest) return;
#if DEBUG
        IsCommandOnly = command && !signedOut && !fixtures;
        var executable = Path.GetFullPath(Environment.ProcessPath ?? AppContext.BaseDirectory);
        InstanceKey = "vex-ui-preview-" + Convert.ToHexString(
            SHA256.HashData(Encoding.UTF8.GetBytes(executable.ToUpperInvariant())))[..24];
        if (IsCommandOnly) return;

        IsEnabled = true;
        IsAuthenticated = fixtures;
        StateDirectory = Path.Combine(Path.GetTempPath(), "VEX.Windows.UiPreview", Guid.NewGuid().ToString("N"));
        Environment.SetEnvironmentVariable("VEX_WINDOWS_PREVIEW", fixtures ? "1" : "0");
#endif
    }

    public static Uri? ParseActivationUri(string? arguments)
    {
        if (string.IsNullOrWhiteSpace(arguments)) return null;
        foreach (var argument in arguments.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            if (Uri.TryCreate(argument.Trim('"'), UriKind.Absolute, out var uri) && IsActivationUri(uri))
                return uri;
        }
        return null;
    }

    public static bool IsActivationUri(Uri? uri) =>
        uri is { IsAbsoluteUri: true } &&
        string.Equals(uri.Scheme, ProtocolScheme, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(uri.Host, "ui-smoke", StringComparison.OrdinalIgnoreCase) &&
        string.Equals(uri.AbsolutePath, "/activate", StringComparison.Ordinal);

    public static bool IsExitCommand(string? arguments) =>
        IsEnabled && arguments is not null &&
        arguments.Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Contains("--ui-smoke-exit", StringComparer.Ordinal);

    public static void Cleanup()
    {
        if (!IsEnabled || StateDirectory is null) return;
        try { Directory.Delete(StateDirectory, recursive: true); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
}
