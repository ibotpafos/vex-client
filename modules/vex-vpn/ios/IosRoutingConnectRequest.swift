import Foundation

struct IosRoutingConnectRequest: Codable {
  let config: String
  let routingParameters: String
  let antiLeak: Bool

  static func decode(_ value: String) -> IosRoutingConnectRequest? {
    guard value.hasPrefix("{"), value.utf8.count <= 3 * 1024 * 1024 else { return nil }
    return try? JSONDecoder().decode(Self.self, from: Data(value.utf8))
  }
}

struct IosRoutingRequestError: LocalizedError {
  var errorDescription: String? { "VEX routing parameters are invalid." }
}
