using Vex.Windows.Client.Api;
using Vex.Windows.Client.Session;
using Vex.Windows.Core.Vpn;

namespace Vex.Windows.App.Services;

public sealed record LocationSelectionResult(
    bool Applied,
    string Message);

public sealed class VpnProductParityService
{
    private IReadOnlyList<VpnLocation> _cachedLocations =
        Array.Empty<VpnLocation>();

    public async Task<IReadOnlyList<VpnLocation>> GetLocationsAsync(
        NativeClientCoordinator coordinator,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(coordinator);
        var locations = await coordinator
            .GetLocationsAsync(cancellationToken)
            .ConfigureAwait(false);
        _cachedLocations = locations.ToArray();
        return _cachedLocations;
    }

    public async Task<LocationSelectionResult> SelectLocationAsync(
        NativeClientCoordinator coordinator,
        string locationId,
        bool reconnectIfConnected,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(coordinator);
        ArgumentException.ThrowIfNullOrWhiteSpace(locationId);
        await coordinator.SelectLocationAsync(
            locationId,
            reconnectIfConnected,
            cancellationToken).ConfigureAwait(false);
        return new LocationSelectionResult(
            Applied: true,
            "Сервер применён.");
    }

    public async Task<VpnServiceResponse> ConnectAsync(
        NativeClientCoordinator coordinator,
        NativeClientPreferences preferences,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(coordinator);
        ArgumentNullException.ThrowIfNull(preferences);
        var locationId = preferences.SelectedLocationId;
        if (preferences.AutoServerEnabled)
        {
            var locations = _cachedLocations.Count > 0
                ? _cachedLocations
                : await GetLocationsAsync(
                    coordinator,
                    cancellationToken).ConfigureAwait(false);
            locationId = VpnLocationSelector.SelectAutomaticLocation(
                locations,
                coordinator.CurrentState?.LocationId);
        }
        var routingMode = preferences.SmartRoutingEnabled
            ? "split"
            : "full";
        return await coordinator.ConnectAsync(
            locationId,
            routingMode,
            preferences.AntiLeakEnabled,
            cancellationToken).ConfigureAwait(false);
    }
}
