namespace Vex.Windows.Client.Api;

// One admission and path policy for the Windows HTTP, realtime and PKCE clients.
public static class VexApiConfiguration
{
    public const string DefaultBaseUrl = "https://vexguard.app";

    public static Uri Resolve(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
            value = DefaultBaseUrl;
        if (!Uri.TryCreate(value.Trim(), UriKind.Absolute, out var uri))
            throw new ArgumentException("invalid_api_base_url", nameof(value));
        return Require(uri);
    }

    public static Uri Require(Uri? uri, string parameterName = "apiBaseUri")
    {
        if (uri is null || !uri.IsAbsoluteUri || !uri.IsWellFormedOriginalString() ||
            string.IsNullOrEmpty(uri.Host) || uri.UserInfo.Length != 0 ||
            uri.Query.Length != 0 || uri.Fragment.Length != 0 ||
            !(uri.Scheme == Uri.UriSchemeHttps ||
              uri.Scheme == Uri.UriSchemeHttp && uri.IsLoopback))
            throw new ArgumentException("invalid_api_base_url", parameterName);
        return new Uri(uri.AbsoluteUri.TrimEnd('/') + "/", UriKind.Absolute);
    }

    internal static Uri Endpoint(Uri baseUri, string path)
    {
        if (!path.StartsWith('/') || path.StartsWith("//", StringComparison.Ordinal) || path.Contains('\\'))
            throw new ArgumentException("Invalid API endpoint path.", nameof(path));
        var endpoint = new Uri(baseUri, path[1..]);
        if (!baseUri.IsBaseOf(endpoint))
            throw new ArgumentException("Invalid API endpoint path.", nameof(path));
        return endpoint;
    }

    internal static string? ApiPath(Uri baseUri, Uri? uri) =>
        uri is { IsAbsoluteUri: true } && baseUri.IsBaseOf(uri)
            ? "/" + baseUri.MakeRelativeUri(uri).OriginalString.Split('?', 2)[0]
            : null;
}
