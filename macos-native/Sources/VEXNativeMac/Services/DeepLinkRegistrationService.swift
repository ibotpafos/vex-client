import AppKit
import CoreServices
import Foundation

enum DeepLinkRegistrationService {
    static let supportedSchemes = ["vexguard", "vex"]

    static func registerPreferredHandlers() {
        let appURL = Bundle.main.bundleURL
        LSRegisterURL(appURL as CFURL, true)
        for scheme in supportedSchemes {
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: scheme) { error in
                if let error {
                    NSLog("VEX failed to register %@ deep link handler at %@: %@", scheme, appURL.path, error.localizedDescription)
                }
            }
        }
    }
}
