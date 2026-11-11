import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Ayu palette: Ayu Light in light mode, Ayu Mirage in dark mode. Every colour is dynamic, so the app follows
/// the system appearance (including Auto, which switches with day and night) without any app setting.
public enum Ayu {
    /// Reader / editor surface.
    public static let background = dynamic(light: 0xFCFCFC, dark: 0x242936)
    /// Sidebar and list panels.
    public static let panel = dynamic(light: 0xF8F9FA, dark: 0x1F2430)
    public static let text = dynamic(light: 0x5C6166, dark: 0xCCCAC2)
    public static let accent = dynamic(light: 0xFFAA33, dark: 0xFFCC66)
    public static let blue = dynamic(light: 0x399EE6, dark: 0x73D0FF)
    public static let green = dynamic(light: 0x86B300, dark: 0x87D96C)
    public static let orange = dynamic(light: 0xFA8D3E, dark: 0xFFAD66)
    public static let red = dynamic(light: 0xE65050, dark: 0xFF6666)
    /// Tag chips and other quiet fills.
    public static let chip = dynamic(light: 0x8A9199, dark: 0x707A8C, alpha: 0.18)

    private static func components(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
        (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
    }

    // Seam: the platform's dynamic colour type resolves light/dark at draw time.
    #if os(macOS)
    private static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (r, g, b) = components(isDark ? dark : light)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
        })
    }
    #else
    private static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(uiColor: UIColor { traits in
            let (r, g, b) = components(traits.userInterfaceStyle == .dark ? dark : light)
            return UIColor(red: r, green: g, blue: b, alpha: alpha)
        })
    }
    #endif
}

extension View {
    /// Ayu text colour and accent for a whole view tree. `.secondary` styles derive from the text colour.
    public func ayuTheme() -> some View {
        foregroundStyle(Ayu.text).tint(Ayu.accent)
    }

    /// Replaces a List's or Form's default background with an Ayu surface.
    public func ayuSurface(_ color: Color) -> some View {
        scrollContentBackground(.hidden).background(color)
    }

    /// Text-link button look. Seam: `.link` exists only on macOS; iOS uses a borderless button, which is tinted.
    @ViewBuilder func linkButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless)
        #endif
    }
}
