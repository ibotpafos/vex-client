import AppKit
import Foundation
import SwiftUI

#if DEBUG
@MainActor
enum VEXPreviewRenderer {
    struct Request {
        let section: AppSection
        let outputURL: URL
    }

    static func request(arguments: [String] = ProcessInfo.processInfo.arguments) -> Request? {
        guard let flagIndex = arguments.firstIndex(of: "--render-ui-preview"),
              arguments.indices.contains(flagIndex + 2),
              let section = AppSection(rawValue: arguments[flagIndex + 1]) else {
            return nil
        }
        return Request(
            section: section,
            outputURL: URL(fileURLWithPath: arguments[flagIndex + 2])
        )
    }

    static func render(_ request: Request) throws {
        let helper = VEXHelperModel()
        let rendersServerSidebar =
            ProcessInfo.processInfo.environment["VEX_PREVIEW_SERVER_SIDEBAR"] == "1"
        if ProcessInfo.processInfo.environment["VEX_PREVIEW_HELPER_INSTALLING"] == "1" {
            helper.configureInstallationPreview(.installing)
        }
        let appState = VEXAppState()
        if rendersServerSidebar {
            appState.configureServerSidebarPreview()
        }
        if ProcessInfo.processInfo.environment["VEX_PREVIEW_BILLING"] == "1" {
            appState.configureBillingPreview()
        }
        if ProcessInfo.processInfo.environment["VEX_PREVIEW_SUPPORT_MESSAGES"] == "1" {
            appState.configureSupportPreview()
        }
        if let updateVersion = ProcessInfo.processInfo.environment["VEX_PREVIEW_UPDATE_VERSION"],
           !updateVersion.isEmpty {
            appState.applyUpdateCheck(AppUpdateCheckResult(
                updateAvailable: true,
                required: false,
                currentBuildBlocked: false,
                latestVersion: updateVersion,
                latestBuild: 999,
                minSupportedBuild: 1,
                minConfigSchemaVersion: 1,
                downloadUrl: "https://vexguard.app/downloads/native-macos/VEXNativeMac-preview.zip",
                changelog: "Preview update",
                checksumSha256: nil,
                signatureUrl: nil,
                channel: "stable",
                reason: "update_available",
                rolloutPercent: 100,
                checkedAt: nil
            ))
        }
        let content: AnyView
        let previewSize = rendersServerSidebar
            ? NSSize(width: 350, height: 580)
            : NSSize(width: 920, height: 580)
        if rendersServerSidebar {
            content = AnyView(
                ServerSidebarPanel(onClose: {})
                    .environmentObject(helper)
                    .environmentObject(appState)
                    .frame(width: previewSize.width, height: previewSize.height)
            )
        } else if ProcessInfo.processInfo.environment["VEX_PREVIEW_LAUNCH"] == "1" {
            content = AnyView(
                VEXLaunchView(appearedInitially: true)
                    .frame(width: previewSize.width, height: previewSize.height)
            )
        } else {
            content = AnyView(
                ContentView(initialSelection: request.section)
                    .environmentObject(helper)
                    .environmentObject(appState)
                    .frame(width: previewSize.width, height: previewSize.height)
            )
        }

        _ = NSApplication.shared
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(origin: .zero, size: previewSize)
        let previewWindow = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        previewWindow.isOpaque = true
        previewWindow.backgroundColor = NSColor(
            red: 0.008,
            green: 0.039,
            blue: 0.043,
            alpha: 1
        )
        previewWindow.contentView = hostingView
        previewWindow.orderFrontRegardless()
        defer {
            previewWindow.orderOut(nil)
        }
        hostingView.layoutSubtreeIfNeeded()
        let renderDelay = ProcessInfo.processInfo.environment["VEX_PREVIEW_LAUNCH"] == "1"
            ? 0.75
            : 0.15
        RunLoop.current.run(until: Date().addingTimeInterval(renderDelay))
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(previewSize.width * 2),
            pixelsHigh: Int(previewSize.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw PreviewError.renderFailed
        }
        bitmap.size = previewSize
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw PreviewError.encodingFailed
        }

        try FileManager.default.createDirectory(
            at: request.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: request.outputURL, options: .atomic)
    }

    private enum PreviewError: LocalizedError {
        case renderFailed
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .renderFailed:
                return "SwiftUI preview renderer returned no image."
            case .encodingFailed:
                return "SwiftUI preview renderer could not encode PNG."
            }
        }
    }
}
#endif
