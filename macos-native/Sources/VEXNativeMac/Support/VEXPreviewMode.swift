import Foundation

enum VEXPreviewMode {
    static var suppressesRuntime: Bool {
        isEnabled || isSignedOutPreview
    }

    static var isEnabled: Bool {
        #if DEBUG
        !isSignedOutPreview && (
            isAnimationPreview
            || ProcessInfo.processInfo.arguments.contains("--focus-pulse-ui-preview")
            || ProcessInfo.processInfo.arguments.contains("--render-ui-preview")
            || Bundle.main.bundleIdentifier?.contains(".qa.") == true
        )
        #else
        false
        #endif
    }

    static var isAnimationPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--focus-pulse-animation-preview")
        #else
        false
        #endif
    }

    static var isSignedOutPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--signed-out-ui-preview")
        #else
        false
        #endif
    }
}
