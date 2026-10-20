import Foundation

enum VEXAppResources {
    private static let bundleName = "VEXNativeMac_VEXNativeMac.bundle"

    // SwiftPM's generated accessor traps when its build directory is absent
    // and the resource bundle lives inside a distributed app's Resources folder.
    static let bundle: Bundle? = {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources", isDirectory: true)
                .appendingPathComponent(bundleName)
        ].compactMap { $0 }

        return candidates.lazy.compactMap(Bundle.init(url:)).first
    }()
}
