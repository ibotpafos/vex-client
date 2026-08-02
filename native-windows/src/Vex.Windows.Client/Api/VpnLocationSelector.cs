namespace Vex.Windows.Client.Api;

public static class VpnLocationSelector
{
    public static string? SelectAutomaticLocation(
        IReadOnlyList<VpnLocation> locations,
        string? preferredLocationId)
    {
        ArgumentNullException.ThrowIfNull(locations);

        var eligible = locations
            .Where(IsEligible)
            .ToArray();
        var preferred = eligible.FirstOrDefault(location =>
            string.Equals(
                location.Id,
                preferredLocationId,
                StringComparison.OrdinalIgnoreCase));
        if (preferred is not null)
        {
            return preferred.Id;
        }

        return eligible
            .OrderBy(location => location.LatencyMs is null)
            .ThenBy(location => location.LatencyMs)
            .ThenByDescending(location => location.HealthyNodes)
            .ThenBy(location => location.City, StringComparer.OrdinalIgnoreCase)
            .Select(location => location.Id)
            .FirstOrDefault();
    }

    private static bool IsEligible(VpnLocation location) =>
        location.HealthyNodes > 0 &&
        !string.Equals(
            location.Availability,
            "unavailable",
            StringComparison.OrdinalIgnoreCase);
}
