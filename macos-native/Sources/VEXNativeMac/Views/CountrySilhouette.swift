import Foundation
import SwiftUI

struct CountrySilhouetteGeometry: Decodable {
    let rings: [[[Double]]]
}

private struct CountrySilhouetteCatalog: Decodable {
    let countries: [String: CountrySilhouetteGeometry]
}

enum CountrySilhouetteStore {
    private static let countries: [String: CountrySilhouetteGeometry] = {
        guard let url = Bundle.module.url(
            forResource: "country-silhouettes",
            withExtension: "json"
        ),
        let data = try? Data(contentsOf: url),
        let catalog = try? JSONDecoder().decode(CountrySilhouetteCatalog.self, from: data) else {
            return [:]
        }
        return catalog.countries
    }()

    static func geometry(for countryCode: String) -> CountrySilhouetteGeometry? {
        countries[countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()]
    }
}

struct CountrySilhouetteShape: Shape {
    let countryCode: String

    func path(in rect: CGRect) -> Path {
        guard let geometry = CountrySilhouetteStore.geometry(for: countryCode) else {
            return Path()
        }

        var path = Path()
        for ring in geometry.rings where ring.count >= 3 {
            guard let first = point(ring[0], in: rect) else { continue }
            path.move(to: first)
            for coordinates in ring.dropFirst() {
                guard let next = point(coordinates, in: rect) else { continue }
                path.addLine(to: next)
            }
            path.closeSubpath()
        }
        return path
    }

    private func point(_ coordinates: [Double], in rect: CGRect) -> CGPoint? {
        guard coordinates.count >= 2 else { return nil }
        return CGPoint(
            x: rect.minX + rect.width * coordinates[0],
            y: rect.minY + rect.height * coordinates[1]
        )
    }
}
