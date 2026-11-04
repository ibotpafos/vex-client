import Foundation

private final class VEXResourceBundleMarker: NSObject {}

enum VEXAppResources {
    private static let bundleName = "VEXNativeMac_VEXNativeMac.bundle"

    // SwiftPM's generated accessor traps when its build directory is absent
    // and the resource bundle lives inside a distributed app's Resources folder.
    static let bundle: Bundle? = {
        let codeBundle = Bundle(for: VEXResourceBundleMarker.self)
        var candidates = [Bundle.main, codeBundle].flatMap { bundle in
            [
                bundle.resourceURL?.appendingPathComponent(bundleName),
                bundle.bundleURL.appendingPathComponent(bundleName),
                bundle.bundleURL
                    .appendingPathComponent("Contents/Resources", isDirectory: true)
                    .appendingPathComponent(bundleName)
            ].compactMap { $0 }
        }

        // XCTest runs in a separate host; SwiftPM puts resources beside the
        // test bundle containing our code, rather than beside that host.
        if codeBundle.bundleURL.pathExtension == "xctest" {
            candidates.append(codeBundle.bundleURL.deletingLastPathComponent()
                .appendingPathComponent(bundleName))
        }

        return candidates.lazy.compactMap(Bundle.init(url:)).first
    }()
}
