using Vex.Windows.Client.Api;

public static class ServerCatalogTests
{
    private static readonly IReadOnlySet<string> NoFavorites = new HashSet<string>();

    public static void Run()
    {
        AvailabilityHonorsStatusMaintenanceAndAwg3();
        CountryGroupsPreserveEveryNodeAndOriginalIds();
        MissingOrInvalidCountriesStaySeparate();
        RepresentativesPreferSelectionThenAvailabilityAndValidLatency();
        FilteringHonorsFavoritesAndFastestEligibility();
        SearchFoldsAccentsAndMatchesTokensAcrossFields();
        TitlesAndFavoritesHaveStableFallbacks();
    }

    private static void AvailabilityHonorsStatusMaintenanceAndAwg3()
    {
        var available = Location("de", "DE");
        foreach (var status in new string?[] { null, "", "  ", "active", "ONLINE", " healthy ", "degraded" })
            Check(ServerCatalog.IsAvailable(available with { Status = status }), $"Status '{status}' should be available");
        foreach (var status in new[] { "offline", "disabled", "maintenance", "unavailable", "retired", "unknown" })
            Check(!ServerCatalog.IsAvailable(available with { Status = status }), $"Status '{status}' must not connect");
        foreach (var availability in new[] { "MAINTENANCE", " unavailable ", "retired" })
            Check(!ServerCatalog.IsAvailable(available with { Availability = availability }), $"Availability '{availability}' must not connect");
        Check(!ServerCatalog.IsAvailable(available with { HealthyNodes = 0 }), "Zero healthy nodes is unavailable");
        Check(!ServerCatalog.IsAvailable(available with { HealthyNodes = -1 }), "Negative healthy nodes is unavailable");
        Check(!ServerCatalog.IsAvailable(available with { Awg3Nodes = 0 }), "Explicit lack of AWG3 is unavailable");
        Check(!ServerCatalog.IsAvailable(available with { Awg3Nodes = -1 }), "Negative AWG3 count is unavailable");
        Check(ServerCatalog.IsAvailable(available with { Awg3Nodes = null }), "Legacy missing AWG3 count retains compatibility");
    }

    private static void CountryGroupsPreserveEveryNodeAndOriginalIds()
    {
        var berlin = Location("de-berlin", " de ", latency: 12) with { HealthyNodes = 3 };
        var munich = Location("de-munich", "DE", latency: 8) with { HealthyNodes = 2 };
        var offline = Location("de-old", "de", latency: 1) with { Status = "offline", HealthyNodes = 5 };
        var finland = Location("fi-helsinki", "FI", latency: 7);
        var groups = ServerCatalog.Groups([berlin, munich, offline, berlin, finland], selectedId: null, limit: 1);

        Check(groups.Count == 1, "Limit applies to countries");
        var group = groups[0];
        Check(group.Id == "country:DE" && group.CountryCode == "DE", "Country grouping normalizes valid country code");
        Check(group.Title == "Германия" && group.FlagEmoji == "🇩🇪", "Group has native country title and flag");
        Ids(["de-munich", "de-berlin", "de-old"], group.Locations);
        Check(group.AvailableNodeCount == 5, "Counts every available member once after deduplication");
        Check(group.Representative.Id == "de-munich", "Connection target is an original location ID");
        Check(berlin.CountryCode == " de ", "Grouping does not mutate the API model");
        Check(ServerCatalog.Groups([berlin], null, 0).Count == 0, "Zero country budget is empty");
        Check(ServerCatalog.Groups([berlin], null, -1).Count == 0, "Negative country budget is empty");

        var selectedFirst = ServerCatalog.Groups([berlin, munich, finland], "fi-helsinki", limit: 1);
        Check(selectedFirst.Single().Id == "country:FI" && selectedFirst.Single().IsSelected,
            "Selected country stays visible within a country limit");
    }

    private static void MissingOrInvalidCountriesStaySeparate()
    {
        var groups = ServerCatalog.Groups(
        [
            Location("missing-a", null), Location("missing-b", null), Location("invalid-a", "USA"),
            Location("invalid-b", "1A"), Location("valid", "us")
        ], null);
        Check(groups.Count == 5, "Missing or invalid codes never collapse unrelated locations");
        Check(groups.Any(group => group.Id == "location:missing-a") &&
              groups.Any(group => group.Id == "location:missing-b"), "Null country keys retain unique location IDs");
        Check(groups.Single(group => group.Id == "country:US").Title == "США", "Valid code still makes a country group");
    }

    private static void RepresentativesPreferSelectionThenAvailabilityAndValidLatency()
    {
        var offline = Location("de-offline", "DE", latency: 0) with { Status = "offline" };
        var negative = Location("de-negative", "DE", latency: -1);
        var nan = Location("de-nan", "DE", latency: double.NaN);
        var infinite = Location("de-infinite", "DE", latency: double.PositiveInfinity);
        var slower = Location("de-slower", "DE", latency: 20);
        var first = Location("de-a", "DE", latency: 5);
        var tie = Location("de-z", "DE", latency: 5);
        var locations = new[] { offline, negative, nan, infinite, slower, tie, first };
        var automatic = ServerCatalog.Groups(locations, null).Single();
        Check(automatic.Representative.Id == "de-a", "Available, finite nonnegative latency, then ID decides representative");
        Check(automatic.Locations.Last().Id == "de-offline", "Unavailability sorts after healthy members despite low latency");
        var selected = ServerCatalog.Groups(locations, "DE-OFFLINE").Single();
        Check(selected.Representative.Id == "de-offline" && selected.IsSelected, "Explicit selection wins over availability");

        var reversed = ServerCatalog.Groups(locations.Reverse().ToArray(), null).Single();
        Ids(automatic.Locations.Select(location => location.Id).ToArray(), reversed.Locations);
        var saturated = ServerCatalog.Groups(
            [first with { HealthyNodes = int.MaxValue }, tie with { HealthyNodes = int.MaxValue }], null).Single();
        Check(saturated.AvailableNodeCount == int.MaxValue, "Node aggregation does not overflow");
    }

    private static void FilteringHonorsFavoritesAndFastestEligibility()
    {
        var favorite = Location("de-favorite", "DE", latency: 90);
        var fast = Location("fi-fast", "FI", latency: 6);
        var offline = Location("nl-offline", "NL", latency: 1) with { Status = "offline" };
        var missing = Location("us-missing", "US", latency: null);
        var nan = Location("us-nan", "US", latency: double.NaN);
        var negative = Location("us-negative", "US", latency: -2);
        var infinite = Location("us-infinite", "US", latency: double.NegativeInfinity);
        var incompatible = Location("de-awg2", "DE", latency: 2) with { Awg3Nodes = 0 };
        var locations = new[] { fast, favorite, offline, missing, nan, negative, infinite, incompatible };
        var favorites = new HashSet<string>(StringComparer.Ordinal) { " DE-FAVORITE ", "NL-OFFLINE" };

        var all = ServerCatalog.Filter(locations, "", ServerCatalogFilter.All, favorites);
        Ids(["nl-offline", "de-favorite"], all.Take(2).ToArray());
        Ids(["fi-fast", "de-favorite"], ServerCatalog.Filter(locations, "", ServerCatalogFilter.Fastest, favorites));
        Ids(["nl-offline", "de-favorite"], ServerCatalog.Filter(locations, "", ServerCatalogFilter.Favorites, favorites));
        var available = ServerCatalog.Filter(locations, "", ServerCatalogFilter.Available, NoFavorites);
        Check(available.Count == 6 && available.All(ServerCatalog.IsAvailable), "Available allows healthy unknown latency and excludes incompatible/offline nodes");
        Ids(all.Select(location => location.Id).ToArray(),
            ServerCatalog.Filter(locations.Reverse().ToArray(), "", ServerCatalogFilter.All, favorites));
    }

    private static void SearchFoldsAccentsAndMatchesTokensAcrossFields()
    {
        var munich = Location("de-munich", "DE", city: "München", latency: 9);
        var berlin = Location("de-berlin", "DE", city: "Berlin", latency: 10);
        var saoPaulo = Location("br-sao", "BR", city: "São Paulo", latency: 8);
        var finland = Location("fi-node", "FI", city: "Helsinki", latency: 7);
        var locations = new[] { munich, berlin, saoPaulo, finland };

        Ids(["de-munich"], ServerCatalog.Filter(locations, "  DE\tMUNCHEN\nhealthy ", ServerCatalogFilter.All, NoFavorites));
        Ids(["de-munich"], ServerCatalog.Filter(locations, "герм münch", ServerCatalogFilter.All, NoFavorites));
        Ids(["br-sao"], ServerCatalog.Filter(locations, "sao PAULO", ServerCatalogFilter.All, NoFavorites));
        Ids(["fi-node"], ServerCatalog.Filter(locations, "fin", ServerCatalogFilter.All, NoFavorites));
        Check(ServerCatalog.Filter(locations, "герм Helsinki", ServerCatalogFilter.All, NoFavorites).Count == 0,
            "Every token must match the same location across its fields");
        Check(ServerCatalog.Filter(locations, "\t\r\n ", ServerCatalogFilter.All, NoFavorites).Count == 4,
            "Whitespace query keeps all locations");
    }

    private static void TitlesAndFavoritesHaveStableFallbacks()
    {
        Check(ServerCatalog.CountryTitle(Location("de", " DE ")) == "Германия", "Germany title");
        Check(ServerCatalog.CountryTitle(Location("fi", "FI")) == "Финляндия", "Finland title");
        Check(ServerCatalog.CountryTitle(Location("nl", "NL")) == "Нидерланды", "Netherlands title");
        Check(ServerCatalog.CountryTitle(Location("us", "US")) == "США", "USA title");
        Check(ServerCatalog.CountryTitle(Location("br", "BR", city: " São Paulo ")) == "São Paulo", "Other countries use city");
        Check(ServerCatalog.CountryTitle(Location("unknown", null, city: " \t")) == "unknown", "Missing city falls back to original ID");
        var favorites = ServerCatalog.NormalizeFavoriteIds([" DE-BERLIN ", "de-berlin", "", "  ", "FI-HELSINKI"]);
        Check(favorites.Count == 2 && favorites.Contains("DE-BERLIN") && favorites.Contains("fi-helsinki"),
            "Favorites normalize whitespace, duplicates, and case");
        Check(ServerCatalog.NormalizeFavoriteIds(null).Count == 0, "Missing preferences have no favorites");
    }

    private static VpnLocation Location(
        string id,
        string? country,
        string city = "City",
        double? latency = 10) => new(id, city, "available", 1, country, Status: "healthy", LatencyMs: latency);

    private static void Ids(string[] expected, IReadOnlyList<VpnLocation> actual) =>
        Check(expected.SequenceEqual(actual.Select(location => location.Id)),
            $"Expected {string.Join(',', expected)}; got {string.Join(',', actual.Select(location => location.Id))}");

    private static void Check(bool condition, string message)
    {
        if (!condition)
            throw new InvalidOperationException(message);
    }
}
