import Darwin
import Foundation
import SwiftUI

// This executable links only the resource resolver and country drawing code.
// It has no application lifecycle, helper, account, or network dependencies.
@main
struct ResourceBundleProbe {
    static func main() {
        let expectCountries = CommandLine.arguments.dropFirst().first == "countries"
        for country in ["FI", "DE", "RU"] {
            let geometry = CountrySilhouetteStore.geometry(for: " \(country.lowercased())\n")
            let path = CountrySilhouetteShape(countryCode: country)
                .path(in: CGRect(x: 0, y: 0, width: 100, height: 100))
            if expectCountries {
                guard geometry?.rings.contains(where: { $0.count >= 3 }) == true,
                      !path.isEmpty else {
                    fail("Missing country geometry: \(country)")
                }
            } else if geometry != nil || !path.isEmpty {
                fail("Unavailable catalog must produce an empty shape")
            }
        }
        guard CountrySilhouetteStore.geometry(for: "ZZ") == nil else {
            fail("Unknown country must remain optional")
        }
        print(expectCountries ? "countries loaded" : "empty shapes")
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(1)
    }
}
