using System.Security.Cryptography;
using System.Text;

namespace Vex.Windows.Client.Auth;

public enum WebAuthMode
{
    Login,
    Register,
}

public sealed record PendingPkceChallenge(
    string Verifier,
    string State);

public sealed record AppWebAuthRequest(
    Uri Url,
    PendingPkceChallenge PendingChallenge);

public sealed record AppAuthCodeExchange(
    string Code,
    string CodeVerifier);

public static class PkceAuthFlow
{
    private const string DefaultCallbackScheme = "vexguard";

    public static AppWebAuthRequest CreateRequest(
        Uri apiBaseUri,
        string deviceId,
        string deviceName,
        string platform,
        WebAuthMode mode,
        Func<int, string>? randomString = null)
    {
        ArgumentNullException.ThrowIfNull(apiBaseUri);
        randomString ??= CreateRandomString;

        deviceId = deviceId.Trim();
        deviceName = deviceName.Trim();
        platform = platform.Trim().ToLowerInvariant();
        if (deviceId.Length == 0 ||
            deviceName.Length == 0 ||
            platform.Length == 0)
        {
            throw new ArgumentException("PKCE request context is invalid.");
        }

        var verifier = randomString(64);
        var state = randomString(16);
        var builder = new UriBuilder(
            new Uri(
                apiBaseUri,
                "/auth/app"));
        builder.Query = string.Join(
            "&",
            new[]
            {
                QueryItem("client_id", "vex_app"),
                QueryItem("code_challenge", CreateChallenge(verifier)),
                QueryItem("state", state),
                QueryItem("device_id", deviceId),
                QueryItem("device_name", deviceName),
                QueryItem("platform", platform),
                QueryItem("mode", mode == WebAuthMode.Register ? "register" : "login"),
            });

        return new AppWebAuthRequest(
            builder.Uri,
            new PendingPkceChallenge(
                verifier,
                state));
    }

    public static AppAuthCodeExchange ResolveCallback(
        Uri callbackUri,
        string expectedState,
        string expectedVerifier)
    {
        ArgumentNullException.ThrowIfNull(callbackUri);
        expectedState = expectedState.Trim();
        expectedVerifier = expectedVerifier.Trim();
        ValidateCallbackUri(callbackUri);

        var code = UniqueQueryValue(callbackUri, "code");
        var returnedState = UniqueQueryValue(callbackUri, "state");
        if (string.IsNullOrWhiteSpace(code) ||
            string.IsNullOrWhiteSpace(returnedState))
        {
            throw new InvalidOperationException(
                "Сайт вернул неполные параметры входа.");
        }

        if (returnedState != expectedState)
        {
            throw new InvalidOperationException(
                "Проверка безопасности входа не прошла. Запустите вход заново.");
        }

        if (expectedVerifier.Length == 0)
        {
            throw new InvalidOperationException(
                "Сессия входа устарела. Запустите вход заново.");
        }

        return new AppAuthCodeExchange(
            code,
            expectedVerifier);
    }

    private static void ValidateCallbackUri(Uri callbackUri)
    {
        var scheme = callbackUri.Scheme.Trim();
        if (!(scheme.Equals(
                  DefaultCallbackScheme,
                  StringComparison.OrdinalIgnoreCase) ||
              scheme.Equals(
                  "vex",
                  StringComparison.OrdinalIgnoreCase)) ||
            !callbackUri.Host.Equals(
                "auth",
                StringComparison.OrdinalIgnoreCase) ||
            !callbackUri.AbsolutePath.Equals(
                "/callback",
                StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "Неподдерживаемый auth callback.");
        }
    }

    private static string? UniqueQueryValue(
        Uri uri,
        string name)
    {
        ArgumentNullException.ThrowIfNull(uri);
        var values = ParseQuery(uri)
            .Where(item =>
                item.Key.Equals(name, StringComparison.Ordinal))
            .Select(item => item.Value)
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .ToArray();
        return values.Length == 1
            ? values[0]
            : null;
    }

    private static IEnumerable<KeyValuePair<string, string?>> ParseQuery(Uri uri)
    {
        var query = uri.Query;
        if (query.StartsWith("?", StringComparison.Ordinal))
        {
            query = query[1..];
        }

        if (query.Length == 0)
        {
            yield break;
        }

        foreach (var segment in query.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var separatorIndex = segment.IndexOf('=');
            if (separatorIndex < 0)
            {
                yield return new KeyValuePair<string, string?>(
                    Uri.UnescapeDataString(segment),
                    null);
                continue;
            }

            yield return new KeyValuePair<string, string?>(
                Uri.UnescapeDataString(segment[..separatorIndex]),
                Uri.UnescapeDataString(segment[(separatorIndex + 1)..]));
        }
    }

    private static string CreateChallenge(string verifier)
    {
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(verifier));
        return Convert.ToBase64String(digest)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }

    private static string CreateRandomString(int length)
    {
        const string alphabet =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";
        var bytes = new byte[length];
        RandomNumberGenerator.Fill(bytes);
        var result = new char[length];
        for (var index = 0; index < length; index += 1)
        {
            result[index] = alphabet[bytes[index] % alphabet.Length];
        }

        return new string(result);
    }

    private static string QueryItem(
        string name,
        string value) =>
        $"{Uri.EscapeDataString(name)}={Uri.EscapeDataString(value)}";
}
