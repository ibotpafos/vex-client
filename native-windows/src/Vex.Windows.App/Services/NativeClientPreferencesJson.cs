using System.Text.Json;

namespace Vex.Windows.App.Services;

public static class NativeClientPreferencesJson
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = false,
        RespectRequiredConstructorParameters = true,
        RespectNullableAnnotations = true,
    };

    public static NativeClientPreferences Decode(ReadOnlyMemory<byte> value)
    {
        try
        {
            using var document = JsonDocument.Parse(value);
            // A decrypted cache can contain valid JSON without containing
            // preferences. Do not run object-only migration on such a value.
            if (document.RootElement.ValueKind != JsonValueKind.Object)
                return NativeClientPreferences.Default;

            var preferences = document.RootElement.Deserialize<NativeClientPreferences>(JsonOptions);
            if (preferences is null) return NativeClientPreferences.Default;
            if (!document.RootElement.TryGetProperty(
                    nameof(NativeClientPreferences.AutoUpdatesEnabled), out _))
                preferences = preferences with { AutoUpdatesEnabled = true };
            return preferences;
        }
        catch (JsonException)
        {
            return NativeClientPreferences.Default;
        }
    }
}
