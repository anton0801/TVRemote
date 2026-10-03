import SwiftUI
import UIKit

/// Design tokens of the Graphite / Amber design (design kit v2, `design-system/tokens.json`).
/// The app has a single dark theme. Pairs used for text are checked for WCAG contrast
/// (`DesignTokenContrastTests`).
enum Palette {
    struct RGB: Equatable, Sendable {
        let r: Double, g: Double, b: Double
        init(hex: UInt32) {
            r = Double((hex >> 16) & 0xFF) / 255
            g = Double((hex >> 8) & 0xFF) / 255
            b = Double(hex & 0xFF) / 255
        }
        var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }

        /// WCAG 2.x relative luminance.
        var luminance: Double {
            func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
        }

        func contrast(with other: RGB) -> Double {
            let l1 = max(luminance, other.luminance), l2 = min(luminance, other.luminance)
            return (l1 + 0.05) / (l2 + 0.05)
        }
    }

    static let background = RGB(hex: 0x111214)
    static let surface = RGB(hex: 0x202226)
    static let surfaceRaised = RGB(hex: 0x2B2E33)
    static let textPrimary = RGB(hex: 0xF5F6F8)
    static let textSecondary = RGB(hex: 0xB6BCC6)
    /// Amber: text, icons, outlines and the fill of primary buttons.
    static let accent = RGB(hex: 0xFFB24A)
    /// Label drawn on top of an amber fill.
    static let onAccent = RGB(hex: 0x111214)
    /// Warm tint behind selected cards (selected plan, current language, Pro banner).
    static let accentTint = RGB(hex: 0x2D2418)
    static let border = RGB(hex: 0x3B3E44)
    static let success = RGB(hex: 0x74DA8B)
    /// Error text and icons.
    static let danger = RGB(hex: 0xFF827B)
    /// Fill of a destructive button ("Stop sharing"), with a white label.
    static let dangerFill = RGB(hex: 0xD7362E)
    static let onDangerFill = RGB(hex: 0xFFFFFF)
}

extension Color {
    init(_ rgb: Palette.RGB) {
        self.init(uiColor: rgb.uiColor)
    }

    static let appBackground = Color(Palette.background)
    static let appSurface = Color(Palette.surface)
    static let appSurfaceRaised = Color(Palette.surfaceRaised)
    static let appTextPrimary = Color(Palette.textPrimary)
    static let appTextSecondary = Color(Palette.textSecondary)
    static let appAccent = Color(Palette.accent)
    static let appAccentFill = Color(Palette.accent)
    static let appOnAccent = Color(Palette.onAccent)
    static let appAccentTint = Color(Palette.accentTint)
    static let appBorder = Color(Palette.border)
    static let appSeparator = Color(Palette.border)
    static let appSuccess = Color(Palette.success)
    /// Attention states use amber, like the design (payment needs attention, receiver needed).
    static let appWarning = Color(Palette.accent)
    static let appDanger = Color(Palette.danger)
    static let appDangerFill = Color(Palette.dangerFill)
}

/// 4-pt spacing grid.
enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 40
    /// Outer screen margin.
    static let screen: CGFloat = 20
}

enum Radius {
    /// Keys, small tiles, fields.
    static let small: CGFloat = 12
    /// Buttons and rows.
    static let control: CGFloat = 16
    /// Cards and grouped sections.
    static let card: CGFloat = 20
    /// Touchpad and large panels.
    static let banner: CGFloat = 24
    static let pill: CGFloat = 999
}

enum Motion {
    static let quick: Double = 0.15
    static let standard: Double = 0.18

    static func animation(_ reduceMotion: Bool, duration: Double = standard) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: duration)
    }
}

/// Minimum hit target 44 pt; primary buttons and rows 56 pt.
enum HitTarget {
    static let minimum: CGFloat = 44
    static let row: CGFloat = 56
    static let primaryButton: CGFloat = 56
    static let remoteKey: CGFloat = 60
}

/// Kit icons (`icon-*` in the asset catalog) are template vectors and take the foreground color.
enum KitIcon {
    static func image(_ name: String) -> Image { Image("icon-\(name)").renderingMode(.template) }
}

/// Global UIKit appearance for bars, so system containers match the dark design.
@MainActor
enum AppAppearance {
    static func apply() {
        let background = Palette.background.uiColor
        let primary = Palette.textPrimary.uiColor

        let navigation = UINavigationBarAppearance()
        navigation.configureWithOpaqueBackground()
        navigation.backgroundColor = background
        navigation.shadowColor = .clear
        navigation.titleTextAttributes = [.foregroundColor: primary]
        navigation.largeTitleTextAttributes = [.foregroundColor: primary]
        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().compactAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = navigation

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = background
        tab.shadowColor = Palette.border.uiColor
        let item = UITabBarItemAppearance()
        item.normal.iconColor = Palette.textSecondary.uiColor
        item.normal.titleTextAttributes = [.foregroundColor: Palette.textSecondary.uiColor]
        item.selected.iconColor = Palette.accent.uiColor
        item.selected.titleTextAttributes = [.foregroundColor: Palette.accent.uiColor]
        tab.stackedLayoutAppearance = item
        tab.inlineLayoutAppearance = item
        tab.compactInlineLayoutAppearance = item
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        UISwitch.appearance().onTintColor = Palette.accent.uiColor
        UISegmentedControl.appearance().selectedSegmentTintColor = Palette.surfaceRaised.uiColor
    }
}
