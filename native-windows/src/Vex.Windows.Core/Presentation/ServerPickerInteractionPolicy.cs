using Vex.Windows.Core.Vpn;

namespace Vex.Windows.Core.Presentation;

public static class ServerPickerInteractionPolicy
{
    public static bool CanSelect(
        VpnConnectionPhase phase,
        bool connectionInFlight,
        bool cleanupInFlight) =>
        !connectionInFlight && !cleanupInFlight &&
        phase is not (VpnConnectionPhase.Connecting or VpnConnectionPhase.Disconnecting);

    public static string? RetainSelection(
        string? highlightedLocationId,
        string? committedLocationId,
        IEnumerable<string> visibleLocationIds)
    {
        ArgumentNullException.ThrowIfNull(visibleLocationIds);
        var ids = visibleLocationIds.ToArray();
        return Find(highlightedLocationId) ?? Find(committedLocationId);

        string? Find(string? id) => string.IsNullOrWhiteSpace(id) ? null :
            ids.FirstOrDefault(candidate => string.Equals(candidate, id, StringComparison.OrdinalIgnoreCase));
    }
}
