import Foundation

/// A configured API origin is shared by requests, web auth and realtime.
/// Keep invalid configuration explicit; never redirect it to the production API.
enum VEXAPIConfiguration {
    static var baseURL: URL? {
        resolve(ProcessInfo.processInfo.environment["VEX_API_BASE_URL"])
    }

    static func resolve(_ configured: String?) -> URL? {
        let selected = configured.flatMap { $0.isEmpty ? nil : $0 } ?? "https://vexguard.app"
        let value = selected
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try? requireBaseURL(URL(string: value))
    }

    static func requireBaseURL(_ url: URL?) throws -> URL {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw VEXAPIError.invalidAPIBaseURL
        }
        if let port = components.port, !(0...65535).contains(port) { throw VEXAPIError.invalidAPIBaseURL }
        while components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath.removeLast() }
        guard let normalized = components.url else { throw VEXAPIError.invalidAPIBaseURL }
        return normalized
    }
}
