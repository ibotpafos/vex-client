import Foundation
import SwiftUI

struct CountrySilhouetteGeometry: Decodable {
    let rings: [[[Double]]]
}

private struct CountrySilhouetteCatalog: Decodable {
    let countries: [String: CountrySilhouetteGeometry]
}

enum CountrySilhouetteStore {
    // SwiftPM's generated accessor assumes its build directory or a bundle at
    // the app root. Packaged apps keep resources in Contents/Resources and must
    // not depend on the developer's build cache (or fatalError if it is absent).
    static func resourceBundle(in main: Bundle = .main) -> Bundle? {
        if main.bundleURL.pathExtension == "app" {
            return main.resourceURL
                .map { $0.appendingPathComponent("VEXNativeMac_VEXNativeMac.bundle") }
                .flatMap(Bundle.init(url:))
        }
        return Bundle.module
    }

    private static let countries: [String: CountrySilhouetteGeometry] = {
        guard let url = resourceBundle()?.url(
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
