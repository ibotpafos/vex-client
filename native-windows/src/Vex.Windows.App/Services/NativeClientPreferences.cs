namespace Vex.Windows.App.Services;

public sealed record NativeClientPreferences(
    bool AutoLaunchEnabled,
    bool AutoServerEnabled,
    bool SmartRoutingEnabled,
    bool AntiLeakEnabled,
    bool AutoRecoveryEnabled,
    string InterfaceLanguage,
    string? SelectedLocationId,
    bool AutoUpdatesEnabled = true,
    IReadOnlyList<string>? FavoriteLocationIds = null,
    string ServerCatalogFilter = "all")
{
    public static NativeClientPreferences Default { get; } =
        new(
            AutoLaunchEnabled: false,
            AutoServerEnabled: true,
            SmartRoutingEnabled: true,
            AntiLeakEnabled: true,
            AutoRecoveryEnabled: true,
            InterfaceLanguage: "ru",
            SelectedLocationId: null,
            AutoUpdatesEnabled: true);
}
