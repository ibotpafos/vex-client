import Foundation

enum DeviceRemovalSafety {
    /// Fail closed when an existing helper tunnel cannot be mapped back to a
    /// profile (including after sign-out). Never guess its remote device ID.
    static func permitsRemoval(confirmedIdle: Bool, helperBusy: Bool, vpnBusy: Bool, activeDeviceID: String?, requestedDeviceID: String) -> Bool {
        confirmedIdle && !helperBusy && !vpnBusy && activeDeviceID != requestedDeviceID
    }
}
