import SwiftUI
import UIKit

/// Design tokens shared by every screen. The dark values are the dashboard's `:root` variables and
/// recurring literals in public/index.html, so the app reads as the same product. The light values
/// are the app's own (the dashboard is dark only): the same warm greys turned over, and every hue a
/// step darker so that, wherever it is text, it keeps 4.5:1 on the page and on every surface.
///
/// Each colour follows the colour scheme of the view it is drawn in, so `.preferredColorScheme`
/// at the root (`AppAppearance`) decides which half every screen shows.
nonisolated enum Theme {
    // MARK: Surfaces

    /// Screen background (`--page`).
    static let page = Color(light: 0xF3F2EE, dark: 0x0D0D0D)
    /// Cards and tiles (`--surface-1`).
    static let surface1 = Color(light: 0xFFFFFF, dark: 0x1A1A19)
    /// Controls, pills and menus (`--surface-2`).
    static let surface2 = Color(light: 0xE9E8E3, dark: 0x232321)
    /// A pressed secondary control (`.btn:hover`).
    static let surfacePressed = Color(light: 0xDDDCD6, dark: 0x2C2C2A)
    /// Tooltip and code-block background (`.tip`, `.cmd code`).
    static let inset = Color(light: 0xF6F5F2, dark: 0x0B0B0B)

    // MARK: Text

    static let textPrimary = Color(light: 0x1A1A19, dark: 0xF0EFEC)
    static let textSecondary = Color(light: 0x44433E, dark: 0xC3C2B7)
    /// Labels and hints. Light: 4.75:1 on surface-2, 5.2 on the page, 5.83 on surface-1.
    static let textMuted = Color(light: 0x67655F, dark: 0x898781)
    /// Muted text on surface-2 (the word in a pill, a field's placeholder). In the dark there
    /// `textMuted` is 4.38:1, short of the 4.5:1 WCAG AA asks of small text; this is 4.62:1, four
    /// steps lighter. On the page, surface-1 and inset `textMuted` itself passes (5.41, 4.85 and
    /// 5.48:1). In the light `textMuted` already passes on surface-2; this is 4.97:1.
    static let textMutedOnSurface2 = Color(light: 0x64625C, dark: 0x8D8B85)
    /// Text and glyphs on an accent fill (`.btn.primary`). Light: 6.25:1 on the accent.
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x0B0B0B)
    /// Destructive menu items and buttons (`.menu .danger`).
    static let dangerText = Color(light: 0xB3261E, dark: 0xE66767)

    // MARK: Lines

    /// Gauge track, chart grid lines, bar track.
    static let grid = Color(light: 0xE3E2DC, dark: 0x2C2C2A)
    /// Chart baseline.
    static let axis = Color(light: 0xC9C8C1, dark: 0x383835)
    /// One-point hairlines around and between surfaces.
    static let border = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 0, alpha: 0.10)
    })
    /// Under a card lifted to be moved (`box-shadow: 0 24px 60px rgba(0,0,0,.65)`); softer in the light.
    static let liftShadow = Color(uiColor: UIColor { traits in
        UIColor(white: 0, alpha: traits.userInterfaceStyle == .dark ? 0.65 : 0.18)
    })

    // MARK: Series

    static let cpu = Color(light: 0x1E64BA, dark: 0x3987E5)
    static let gpu = Color(light: 0xAA4316, dark: 0xD95926)
    static let mem = Color(light: 0x0C7150, dark: 0x199E70)

    // MARK: Status

    static let good = Color(light: 0x127212, dark: 0x0CA30C)
    static let warning = Color(light: 0x8A5D00, dark: 0xFAB219)
    static let serious = Color(light: 0xA8461C, dark: 0xEC835A)
    static let critical = Color(light: 0xB82E2E, dark: 0xD03B3B)

    /// Primary buttons and selection.
    static let accent = Color(light: 0x5B4FC4, dark: 0x9085E9)

    /// Per-device colours of the Advanced view (`DEVICE_COLORS`), cycled when there are more devices.
    static let deviceSeries: [Color] = [
        cpu, gpu, mem, accent, warning, serious, Color(light: 0x1A6F79, dark: 0x4FB3BF), Color(light: 0x9447A0, dark: 0xC97FD0),
    ]

    static func deviceSeriesColor(at index: Int) -> Color {
        deviceSeries[((index % deviceSeries.count) + deviceSeries.count) % deviceSeries.count]
    }

    // MARK: Metrics

    enum Radius {
        static let card: CGFloat = 14
        static let tile: CGFloat = 12
        static let banner: CGFloat = 10
        static let control: CGFloat = 8
        static let small: CGFloat = 6
        static let bar: CGFloat = 4
        static let pill: CGFloat = 99
    }

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 22
        static let xxl: CGFloat = 32
    }

    enum Layout {
        /// The device grid uses as many columns of at least this width as fit (`minmax(290px, 1fr)`).
        static let cardMinWidth: CGFloat = 290
        /// Gap between cards in the grid.
        static let gridSpacing: CGFloat = 16
        /// Gap between tiles.
        static let tileSpacing: CGFloat = 12
        /// Smallest tile that still shows a value and its sub line; two fit side by side on every iPhone.
        static let tileMinWidth: CGFloat = 150
        /// Screen edge padding on a phone-width layout (the dashboard's ≤ 520 px rule).
        static let screenPaddingCompact: CGFloat = 12
        /// Screen edge padding on wider layouts.
        static let screenPaddingRegular: CGFloat = 22
        /// History and Advanced stop growing at this width (`max-width: 1280px`).
        static let maxContentWidth: CGFloat = 1280
        /// Width of a hairline.
        static let hairline: CGFloat = 1
        /// Padding inside a card (`15px 18px 13px`).
        static var cardPadding: EdgeInsets { EdgeInsets(top: 15, leading: 18, bottom: 13, trailing: 18) }
        /// Padding inside a tile (`12px 14px`).
        static var tilePadding: EdgeInsets { EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14) }
        /// Padding inside a chart panel (`14px 16px 10px`).
        static var panelPadding: EdgeInsets { EdgeInsets(top: 14, leading: 16, bottom: 10, trailing: 16) }
        /// Opacity of an offline device's card.
        static let offlineOpacity: Double = 0.55

        static func screenPadding(for sizeClass: UserInterfaceSizeClass?) -> CGFloat {
            sizeClass == .regular ? screenPaddingRegular : screenPaddingCompact
        }
    }
}

nonisolated extension Color {
    /// An opaque sRGB colour from `0xRRGGBB`.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

nonisolated extension Color {
    /// `light` in the light colour scheme and `dark` in the dark one, both opaque sRGB `0xRRGGBB`.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

nonisolated extension UIColor {
    /// An opaque sRGB colour from `0xRRGGBB`.
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

nonisolated extension Theme {
    /// `fmtPct` from the dashboard: a rounded percentage, or an en dash when there is no reading.
    static func percentText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        // Math.round rounds halves up, which differs from Swift's default for negative numbers.
        let rounded = (value + 0.5).rounded(.down)
        // The hub relays any finite number, and used / total with a tiny total is far beyond what
        // Int holds. Int(_:) traps there; print the number as it is instead ("1e+23%", which is
        // also what the dashboard shows).
        guard let whole = Int(exactly: rounded) else { return "\(rounded)%" }
        return "\(whole)%"
    }

    /// A percentage as a bar or an arc can show it: 0–100, and 0 when it is not a number.
    static func clampedPercent(_ value: Double) -> Double {
        value.isFinite ? min(100, max(0, value)) : 0
    }
}

#Preview("Colours") {
    let rows: [[(String, Color)]] = [
        [("page", Theme.page), ("surface1", Theme.surface1), ("surface2", Theme.surface2), ("grid", Theme.grid), ("axis", Theme.axis)],
        [("cpu", Theme.cpu), ("gpu", Theme.gpu), ("mem", Theme.mem), ("accent", Theme.accent), ("danger", Theme.dangerText)],
        [("good", Theme.good), ("warning", Theme.warning), ("serious", Theme.serious), ("critical", Theme.critical)],
    ]
    VStack(spacing: Theme.Spacing.m) {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            HStack(spacing: Theme.Spacing.s) {
                ForEach(row, id: \.0) { name, color in
                    VStack(spacing: Theme.Spacing.xs) {
                        RoundedRectangle(cornerRadius: Theme.Radius.small)
                            .fill(color)
                            .frame(height: 32)
                            .overlay { RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(Theme.border) }
                        Text(name).font(.caption2).foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.surface1)
}
