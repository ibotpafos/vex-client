import ActivityKit
import Foundation

public struct VexVpnActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    public var state: String
    public var phase: String
    public var locationName: String
    public var latencyText: String
    public var receivedText: String
    public var sentText: String
    public var updatedAtEpochSeconds: Double

    public init(
      state: String,
      phase: String,
      locationName: String,
      latencyText: String,
      receivedText: String,
      sentText: String,
      updatedAtEpochSeconds: Double
    ) {
      self.state = state
      self.phase = phase
      self.locationName = locationName
      self.latencyText = latencyText
      self.receivedText = receivedText
      self.sentText = sentText
      self.updatedAtEpochSeconds = updatedAtEpochSeconds
    }
  }

  public var name: String

  public init(name: String) {
    self.name = name
  }
}
