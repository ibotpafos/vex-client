namespace Vex.Windows.Client.Auth;

public static class ProtocolActivationUriParser
{
    private static readonly HashSet<string> AllowedSchemes =
        new(StringComparer.OrdinalIgnoreCase)
        {
            "vex",
            "vexguard",
        };

    public static Uri? Parse(string? arguments)
    {
        var candidate = arguments?.Trim();
        if (string.IsNullOrWhiteSpace(candidate))
        {
            return null;
        }

        if (candidate.Length >= 2 &&
            candidate[0] == '"' &&
            candidate[^1] == '"')
        {
            candidate = candidate[1..^1].Trim();
        }

        if (candidate.Any(char.IsWhiteSpace) ||
            !Uri.TryCreate(candidate, UriKind.Absolute, out var uri) ||
            !AllowedSchemes.Contains(uri.Scheme))
        {
            return null;
        }

        return uri;
    }
}
