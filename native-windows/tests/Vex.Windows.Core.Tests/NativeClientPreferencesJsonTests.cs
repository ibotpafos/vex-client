using System.Text;
using System.Text.Json;
using Vex.Windows.App.Services;

internal static class NativeClientPreferencesJsonTests
{
    public static void Run()
    {
        const string legacyJson =
            "{\"AutoLaunchEnabled\":true,\"AutoServerEnabled\":true,\"SmartRoutingEnabled\":true," +
            "\"AntiLeakEnabled\":true,\"AutoRecoveryEnabled\":true,\"InterfaceLanguage\":\"en\",\"SelectedLocationId\":\"de-1\"}";
        foreach (var value in new[]
        {
            "null", "[]", "true", "7", "\"preferences\"", "{", "{}", "{\"AutoLaunchEnabled\":\"yes\"}",
            legacyJson.Replace("\"AntiLeakEnabled\":true,", "", StringComparison.Ordinal),
            legacyJson.Replace("\"InterfaceLanguage\":\"en\"", "\"InterfaceLanguage\":null", StringComparison.Ordinal),
            legacyJson[..^1] + ",\"ServerCatalogFilter\":null}",
        })
            Require(NativeClientPreferencesJson.Decode(Encoding.UTF8.GetBytes(value)) == NativeClientPreferences.Default,
                "An unusable preferences cache must use defaults without crashing startup: " + value);

        var legacy = NativeClientPreferencesJson.Decode(Encoding.UTF8.GetBytes(legacyJson));
        Require(legacy.AutoUpdatesEnabled && legacy.AutoLaunchEnabled && legacy.SelectedLocationId == "de-1" &&
            legacy.InterfaceLanguage == "en", "Legacy migration must enable updates and preserve saved preferences.");

        var saved = NativeClientPreferences.Default with
        {
            AutoUpdatesEnabled = false,
            SmartRoutingEnabled = false,
            AntiLeakEnabled = false,
            SelectedLocationId = "fi-1",
            FavoriteLocationIds = ["fi-1", "nl-1"],
            ServerCatalogFilter = "favorites",
        };
        var restored = NativeClientPreferencesJson.Decode(JsonSerializer.SerializeToUtf8Bytes(saved));
        Require(!restored.AutoUpdatesEnabled && !restored.SmartRoutingEnabled && !restored.AntiLeakEnabled &&
            restored.SelectedLocationId == "fi-1" && restored.ServerCatalogFilter == "favorites" &&
            restored.FavoriteLocationIds is not null && restored.FavoriteLocationIds.SequenceEqual(saved.FavoriteLocationIds!),
            "Decoding must preserve explicit false preferences, pinned/favorite servers and the picker filter.");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
