namespace Vex.Windows.Core.Presentation;

public static class NativeLocationLabel
{
    private static readonly IReadOnlyDictionary<string, string> RussianNames =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["at"] = "Австрия",
            ["ca"] = "Канада",
            ["ch"] = "Швейцария",
            ["cz"] = "Чехия",
            ["de"] = "Германия",
            ["fi"] = "Финляндия",
            ["fr"] = "Франция",
            ["gb"] = "Великобритания",
            ["jp"] = "Япония",
            ["nl"] = "Нидерланды",
            ["pl"] = "Польша",
            ["se"] = "Швеция",
            ["sg"] = "Сингапур",
            ["uk"] = "Великобритания",
            ["us"] = "США",
        };

    public static string Russian(string? locationId)
    {
        if (string.IsNullOrWhiteSpace(locationId) ||
            locationId.Equals("auto", StringComparison.OrdinalIgnoreCase))
        {
            return "Автоматический сервер";
        }

        var normalized = locationId.Trim().ToLowerInvariant();
        var countryCode = normalized.Split('-', 2)[0];
        return RussianNames.TryGetValue(countryCode, out var label)
            ? label
            : $"Сервер {normalized}";
    }
}
