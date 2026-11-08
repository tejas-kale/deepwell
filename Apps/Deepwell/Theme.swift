import SwiftUI
import AppKit

/// Ayu palette: Ayu Light in light mode, Ayu Mirage in dark mode. Every colour is dynamic, so the app follows
/// the macOS appearance (including Auto, which switches with day and night) without any app setting.
enum Ayu {
    /// Reader / editor surface.
    static let background = dynamic(light: 0xFCFCFC, dark: 0x242936)
    /// Sidebar and list panels.
    static let panel = dynamic(light: 0xF8F9FA, dark: 0x1F2430)
    static let text = dynamic(light: 0x5C6166, dark: 0xCCCAC2)
    static let accent = dynamic(light: 0xFFAA33, dark: 0xFFCC66)
    static let blue = dynamic(light: 0x399EE6, dark: 0x73D0FF)
    static let green = dynamic(light: 0x86B300, dark: 0x87D96C)
    static let orange = dynamic(light: 0xFA8D3E, dark: 0xFFAD66)
    static let red = dynamic(light: 0xE65050, dark: 0xFF6666)
    /// Tag chips and other quiet fills.
    static let chip = dynamic(light: 0x8A9199, dark: 0x707A8C, alpha: 0.18)

    private static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        })
    }
}

extension View {
    /// Ayu text colour and accent for a whole view tree. `.secondary` styles derive from the text colour.
    func ayuTheme() -> some View {
        foregroundStyle(Ayu.text).tint(Ayu.accent)
    }

    /// Replaces a List's or Form's default background with an Ayu surface.
    func ayuSurface(_ color: Color) -> some View {
        scrollContentBackground(.hidden).background(color)
    }
}
