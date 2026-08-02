using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Vex.Windows.App.Views;

internal static class CountrySilhouetteGeometry
{
    private const double ArtworkExtent = 100;
    private static readonly Lazy<IReadOnlyDictionary<string, CountryShape>>
        Shapes = new(LoadShapes);

    public static Geometry Create(string? countryCode)
    {
        var geometry = new PathGeometry
        {
            FillRule = FillRule.EvenOdd,
        };
        if (string.IsNullOrWhiteSpace(countryCode) ||
            !Shapes.Value.TryGetValue(
                countryCode.Trim().ToUpperInvariant(),
                out var country))
        {
            return geometry;
        }

        foreach (var ring in country.Rings)
        {
            if (ring.Length < 4)
            {
                continue;
            }

            var figure = new PathFigure
            {
                StartPoint = Point(ring[0]),
                IsClosed = true,
                IsFilled = true,
            };
            for (var index = 1; index < ring.Length; index++)
            {
                figure.Segments.Add(new LineSegment
                {
                    Point = Point(ring[index]),
                });
            }

            geometry.Figures.Add(figure);
        }

        return geometry;
    }

    private static global::Windows.Foundation.Point Point(
        IReadOnlyList<double> coordinates) =>
        new(
            coordinates[0] * ArtworkExtent,
            coordinates[1] * ArtworkExtent);

    private static IReadOnlyDictionary<string, CountryShape> LoadShapes()
    {
        var path = Path.Combine(
            AppContext.BaseDirectory,
            "Assets",
            "country-silhouettes.json");
        if (!File.Exists(path))
        {
            return new Dictionary<string, CountryShape>(
                StringComparer.OrdinalIgnoreCase);
        }

        try
        {
            var payload = JsonSerializer.Deserialize<CountryPayload>(
                File.ReadAllText(path));
            return payload?.Countries is null
                ? new Dictionary<string, CountryShape>(
                    StringComparer.OrdinalIgnoreCase)
                : new Dictionary<string, CountryShape>(
                    payload.Countries,
                    StringComparer.OrdinalIgnoreCase);
        }
        catch (JsonException)
        {
            return new Dictionary<string, CountryShape>(
                StringComparer.OrdinalIgnoreCase);
        }
    }

    private sealed record CountryPayload(
        [property: JsonPropertyName("countries")]
        Dictionary<string, CountryShape> Countries);

    private sealed record CountryShape(
        [property: JsonPropertyName("rings")]
        double[][][] Rings);
}
