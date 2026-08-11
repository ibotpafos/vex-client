import Foundation

/// Commands shared by the menu bar and the in-window server drawer.
///
/// The drawer deliberately lives in `ContentView`: using an `NSPanel` made it
/// possible to leave a detached window on screen after the main app lost focus.
enum VEXServerSidebarWindow {
    static let toggleNotification = Notification.Name("VEXToggleServerSidebar")
    static let closeNotification = Notification.Name("VEXCloseServerSidebar")

    @MainActor
    static func toggle() {
        NotificationCenter.default.post(name: toggleNotification, object: nil)
    }

    @MainActor
    static func close() {
        NotificationCenter.default.post(name: closeNotification, object: nil)
    }
}

enum ServerSidebarSearch {
    static func matches(query: String, values: [String]) -> Bool {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else { return true }
        let queryVariants = Set([
            normalizedQuery,
            normalized(transliterated(query))
        ])
        return values.contains { value in
            let valueVariants = [
                normalized(value),
                normalized(transliterated(value))
            ]
            return queryVariants.contains { queryVariant in
                valueVariants.contains { $0.contains(queryVariant) }
            }
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func transliterated(_ value: String) -> String {
        value.applyingTransform(.toLatin, reverse: false) ?? value
    }
}
