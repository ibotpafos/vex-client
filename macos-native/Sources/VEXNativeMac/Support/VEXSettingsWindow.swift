import AppKit

enum VEXSettingsWindow {
    static let openNotification = Notification.Name("VEXOpenSettingsSection")
    static let sectionUserInfoKey = "section"

    @MainActor
    static func open(section: AppSection = .settings) {
        NotificationCenter.default.post(
            name: openNotification,
            object: nil,
            userInfo: [sectionUserInfoKey: section.rawValue]
        )
    }
}
