using System.Globalization;
using System.Text;

namespace Vex.Windows.Client.Api;

public enum ServerCatalogFilter
{
    All,
    Fastest,
    Favorites,
    Available
}

/// <summary>Country presentation; connect using Representative.Id or an original Locations ID.</summary>
public sealed record ServerCountryGroup(
    string Id,
    string CountryCode,
    string Title,
    string FlagEmoji,
    IReadOnlyList<VpnLocation> Locations,
    VpnLocation Representative,
    bool IsSelected,
    int AvailableNodeCount);

public static class ServerCatalog
{
    public static IReadOnlyList<VpnLocation> Filter(
        IReadOnlyList<VpnLocation> locations,
        string query,
        ServerCatalogFilter filter,
        IReadOnlySet<string> favoriteIds)
    {
        ArgumentNullException.ThrowIfNull(locations);
        ArgumentNullException.ThrowIfNull(favoriteIds);
        var favorites = NormalizeFavoriteIds(favoriteIds);
        var tokens = FoldSearch(query ?? string.Empty)
            .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        var scoped = UniqueLocations(locations).Where(location => Matches(location, tokens));
        scoped = filter switch
        {
            ServerCatalogFilter.All => scoped,
            ServerCatalogFilter.Fastest => scoped.Where(location => IsAvailable(location) && ValidLatency(location) is not null),
            ServerCatalogFilter.Favorites => scoped.Where(location => favorites.Contains(location.Id.Trim())),
            ServerCatalogFilter.Available => scoped.Where(IsAvailable),
            _ => throw new ArgumentOutOfRangeException(nameof(filter))
        };

        return scoped
            .OrderByDescending(location => filter != ServerCatalogFilter.Fastest && favorites.Contains(location.Id.Trim()))
            .ThenBy(location => ValidLatency(location) ?? double.PositiveInfinity)
            .ThenBy(CountryTitle, StringComparer.OrdinalIgnoreCase)
            .ThenBy(location => location.Id, StringComparer.Ordinal)
            .ToArray();
    }

    public static IReadOnlyList<ServerCountryGroup> Groups(
        IReadOnlyList<VpnLocation> locations,
        string? selectedId,
        int limit = int.MaxValue)
    {
        ArgumentNullException.ThrowIfNull(locations);
        if (limit <= 0)
            return [];

        return UniqueLocations(locations)
            .GroupBy(location => ValidCountryCode(location.CountryCode) is { } code
                ? "country:" + code
                : "location:" + location.Id, StringComparer.Ordinal)
            .Select(group =>
            {
                var members = group
                    .OrderByDescending(IsAvailable)
                    .ThenBy(location => ValidLatency(location) ?? double.PositiveInfinity)
                    .ThenBy(location => location.Id, StringComparer.Ordinal)
                    .ToArray();
                var selected = members.FirstOrDefault(location =>
                    string.Equals(location.Id, selectedId, StringComparison.OrdinalIgnoreCase));
                var representative = selected ?? members[0];
                var countryCode = ValidCountryCode(representative.CountryCode) ?? string.Empty;
                representative = representative with { CountryCode = countryCode };
                var availableNodes = (int)Math.Min(int.MaxValue,
                    members.Where(IsAvailable).Sum(location => (long)Math.Max(location.HealthyNodes, 0)));
                return new ServerCountryGroup(group.Key, countryCode, CountryTitle(representative),
                    string.IsNullOrWhiteSpace(representative.FlagEmoji)
                        ? CountryFlag(countryCode)
                        : representative.FlagEmoji.Trim(),
                    members, representative, selected is not null, availableNodes);
            })
            .OrderByDescending(group => group.IsSelected)
            .ThenBy(group => group.Id, StringComparer.Ordinal)
            .Take(limit)
            .ToArray();
    }

    public static bool IsAvailable(VpnLocation location)
    {
        ArgumentNullException.ThrowIfNull(location);
        var availability = location.Availability?.Trim().ToLowerInvariant() ?? string.Empty;
        var status = location.Status?.Trim().ToLowerInvariant() ?? string.Empty;
        return location.HealthyNodes > 0 &&
               (location.Awg3Nodes ?? 1) > 0 &&
               availability is not ("maintenance" or "unavailable" or "retired") &&
               status is "" or "active" or "online" or "healthy" or "degraded";
    }

    public static string CountryTitle(VpnLocation location)
    {
        ArgumentNullException.ThrowIfNull(location);
        return ValidCountryCode(location.CountryCode) switch
        {
            "DE" => "Германия",
            "FI" => "Финляндия",
            "NL" => "Нидерланды",
            "US" => "США",
            _ => string.IsNullOrWhiteSpace(location.City) ? location.Id : location.City.Trim()
        };
    }

    public static IReadOnlySet<string> NormalizeFavoriteIds(IEnumerable<string>? favoriteIds) =>
        new HashSet<string>((favoriteIds ?? [])
            .Where(id => !string.IsNullOrWhiteSpace(id))
            .Select(id => id.Trim().ToLowerInvariant()), StringComparer.OrdinalIgnoreCase);

    private static IEnumerable<VpnLocation> UniqueLocations(IEnumerable<VpnLocation> locations)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var location in locations)
        {
            if (seen.Add(location.Id))
                yield return location;
        }
    }

    private static bool Matches(VpnLocation location, IReadOnlyList<string> tokens)
    {
        if (tokens.Count == 0)
            return true;
        var values = new[] { location.Id, location.CountryCode, location.City, CountryTitle(location), location.Status }
            .Select(value => FoldSearch(value ?? string.Empty))
            .ToArray();
        return tokens.All(token => values.Any(value => value.Contains(token, StringComparison.Ordinal)));
    }

    private static double? ValidLatency(VpnLocation location) =>
        location.LatencyMs is { } latency && double.IsFinite(latency) && latency >= 0 ? latency : null;

    private static string? ValidCountryCode(string? countryCode)
    {
        var normalized = countryCode?.Trim().ToUpperInvariant();
        return normalized is { Length: 2 } && normalized.All(character => character is >= 'A' and <= 'Z')
            ? normalized
            : null;
    }

    private static string CountryFlag(string countryCode) => countryCode.Length == 2
        ? char.ConvertFromUtf32(0x1F1E6 + countryCode[0] - 'A') + char.ConvertFromUtf32(0x1F1E6 + countryCode[1] - 'A')
        : string.Empty;

    private static string FoldSearch(string value)
    {
        var folded = new StringBuilder();
        foreach (var character in value.Normalize(NormalizationForm.FormD).ToLowerInvariant())
        {
            if (CharUnicodeInfo.GetUnicodeCategory(character) is UnicodeCategory.NonSpacingMark or
                UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark)
                continue;

            // Match the macOS sidebar's Latin/Cyrillic search for Russian country names.
            folded.Append(character switch
            {
                'а' => "a", 'б' => "b", 'в' => "v", 'г' => "g", 'д' => "d", 'е' => "e",
                'ж' => "zh", 'з' => "z", 'и' => "i", 'й' => "i", 'к' => "k", 'л' => "l",
                'м' => "m", 'н' => "n", 'о' => "o", 'п' => "p", 'р' => "r", 'с' => "s",
                'т' => "t", 'у' => "u", 'ф' => "f", 'х' => "kh", 'ц' => "ts", 'ч' => "ch",
                'ш' => "sh", 'щ' => "shch", 'ъ' or 'ь' => "", 'ы' => "y", 'э' => "e",
                'ю' => "iu", 'я' => "ia", _ => character.ToString()
            });
        }
        return folded.ToString();
    }
}
