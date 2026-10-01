import Foundation

enum VpnConnectionState: String, Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
}

@main
enum CountryGroupingContract {
    static func main() {
        let locations = [
            location(id: "de-slow", country: "DE", latency: 32),
            location(id: "fi-best", country: "FI", latency: 8),
            location(id: "de-best", country: "DE", latency: 12),
            location(id: "nl-best", country: "NL", latency: 18),
        ]

        let result = FocusPulsePresentation.featuredLocations(
            locations,
            selectedLocationId: "de-slow"
        )

        guard result.map(\.countryCode) == ["DE", "FI", "NL"] else {
            fputs("expected one card per country with the selected country first\n", stderr)
            exit(1)
        }
        guard result.first?.id == "de-slow" else {
            fputs("expected an explicitly selected server to remain the country representative\n", stderr)
            exit(1)
        }

        let finlandSelected = FocusPulsePresentation.featuredLocations(
            locations,
            selectedLocationId: "fi-best"
        )
        guard finlandSelected.map(\.countryCode) == ["DE", "FI", "NL"] else {
            fputs("expected country cards to keep a stable order after selection\n", stderr)
            exit(1)
        }
        guard finlandSelected[1].id == "fi-best" else {
            fputs("expected the selected server to represent its country without reordering cards\n", stderr)
            exit(1)
        }

        let cardWidth = FocusPulsePresentation.locationCardWidth(
            containerWidth: 892,
            visibleCardCount: 3,
            spacing: 12
        )
        guard abs(cardWidth - (868.0 / 3.0)) < 0.01 else {
            fputs("expected three cards to fit without overlap and keep two 12pt gaps\n", stderr)
            exit(1)
        }

        guard FocusPulsePresentation.photoTransitionDuration(reduceMotion: false) == 0.45,
              FocusPulsePresentation.photoTransitionDuration(reduceMotion: true) == 0.08 else {
            fputs("expected a calm photo crossfade with a short Reduce Motion fallback\n", stderr)
            exit(1)
        }
        guard FocusPulsePresentation.selectionTransitionDuration(reduceMotion: false) == 0.24,
              FocusPulsePresentation.selectionTransitionDuration(reduceMotion: true) == 0.01 else {
            fputs("expected card selection to settle faster than the hero photo\n", stderr)
            exit(1)
        }

        guard FocusPulsePresentation.pulseCanvasSize == 360 else {
            fputs("expected the power pulse to render in a square canvas\n", stderr)
            exit(1)
        }
        guard FocusPulsePresentation.pulseGradientEndRadius
                <= FocusPulsePresentation.pulseCanvasSize / 2 - 8 else {
            fputs("expected the power pulse gradient to become transparent before the canvas edge\n", stderr)
            exit(1)
        }
    }

    private static func location(id: String, country: String, latency: Double) -> VpnLocation {
        VpnLocation(
            id: id,
            countryCode: country,
            city: country,
            flagEmoji: nil,
            availability: "available",
            status: "healthy",
            healthyNodes: 1,
            latencyMs: latency
        )
    }
}
