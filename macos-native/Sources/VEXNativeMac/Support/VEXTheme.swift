import AppKit
import SwiftUI

extension Color {
    static let vexBackground = Color(red: 0.008, green: 0.039, blue: 0.043)
    static let vexPanel = Color(red: 0.031, green: 0.098, blue: 0.114)
    static let vexPanelStrong = Color(red: 0.027, green: 0.067, blue: 0.075)
    static let vexInput = Color(red: 0.008, green: 0.039, blue: 0.043)
    static let vexCyan = Color(red: 0.133, green: 0.827, blue: 0.933)
    static let vexCyanLight = Color(red: 0.725, green: 0.984, blue: 1.0)
    static let vexText = Color(red: 0.957, green: 0.988, blue: 0.992)
    static let vexSubtext = Color(red: 0.659, green: 0.847, blue: 0.871)
    static let vexSecondaryText = Color(red: 0.655, green: 0.725, blue: 0.741)
    static let vexMuted = Color(red: 0.561, green: 0.745, blue: 0.776)
    static let vexBorder = Color(red: 0.494, green: 0.914, blue: 0.961)
}

extension Bundle {
    func image(_ name: String) -> NSImage? {
        guard let url = url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}
