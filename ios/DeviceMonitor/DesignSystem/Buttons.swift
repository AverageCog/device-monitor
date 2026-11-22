import SwiftUI

/// The dashboard's buttons (`.btn`, `.btn.primary`).
///
///     Button("Try again") { … }.buttonStyle(.dm(.primary))
///     Button("Wake") { … }.buttonStyle(.dm(.secondary, size: .small))
struct DMButtonStyle: ButtonStyle {
    nonisolated enum Kind: Sendable {
        /// Accent fill with dark text.
        case primary
        /// Surface-2 fill with a hairline border.
        case secondary
        /// Secondary, with the danger text colour.
        case destructive
    }

    nonisolated enum Size: Sendable {
        /// In-row actions such as "Wake" or "Copy" (`.off-row .btn`).
        case small
        /// The standard button.
        case regular
        /// The main action of a full screen, e.g. onboarding.
        case large
    }

    var kind: Kind = .secondary
    var size: Size = .regular
    /// Stretches the button across the available width.
    var fillsWidth = false

    func makeBody(configuration: Configuration) -> some View {
        DMButtonBody(configuration: configuration, kind: kind, size: size, fillsWidth: fillsWidth)
    }
}

extension ButtonStyle where Self == DMButtonStyle {
    static func dm(_ kind: DMButtonStyle.Kind = .secondary, size: DMButtonStyle.Size = .regular, fillsWidth: Bool = false) -> DMButtonStyle {
        DMButtonStyle(kind: kind, size: size, fillsWidth: fillsWidth)
    }
}

private struct DMButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: DMButtonStyle.Kind
    let size: DMButtonStyle.Size
    let fillsWidth: Bool

    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    private var metrics: (height: CGFloat, horizontal: CGFloat, radius: CGFloat, style: DMTextStyle) {
        switch size {
        case .small: (30, 10, Theme.Radius.control, .statValue)
        case .regular: (38, 14, Theme.Radius.control, kind == .primary ? .bodyStrong : .body)
        case .large: (50, 18, Theme.Radius.tile, .bodyStrong)
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: Theme.onAccent
        case .secondary: Theme.textPrimary
        case .destructive: Theme.dangerText
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: Theme.accent
        case .secondary, .destructive: configuration.isPressed ? Theme.surfacePressed : Theme.surface2
        }
    }

    var body: some View {
        let metrics = metrics
        // Small buttons keep their compact look but still offer a 44-point target.
        let reach = max(0, (44 - metrics.height * scale) / 2)
        configuration.label
            .dmFont(metrics.style)
            .labelStyle(DMButtonLabelStyle())
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, metrics.horizontal)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: metrics.height * scale)
            .background(fill, in: RoundedRectangle(cornerRadius: metrics.radius, style: .continuous))
            .overlay {
                if kind != .primary {
                    RoundedRectangle(cornerRadius: metrics.radius, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: Theme.Layout.hairline)
                }
            }
            .brightness(kind == .primary && configuration.isPressed ? -0.08 : 0)
            .opacity(isEnabled ? 1 : 0.5)
            .padding(.vertical, reach)
            .contentShape(Rectangle())
            .padding(.vertical, -reach)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Icon and title side by side with the dashboard's 6-point gap.
private struct DMButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

/// A bare icon button (`.icon-btn`, the header's `.view-btn`): muted glyph with a 44-point target,
/// a surface-2 plate while pressed, and optional lit or filled states.
///
///     Button { … } label: { Image(systemName: "ellipsis") }
///         .buttonStyle(.dmIcon)
///         .accessibilityLabel("Device options")
///
/// Toolbar items should stay plain system buttons: the navigation bar draws its own plates.
struct DMIconButtonStyle: ButtonStyle {
    nonisolated enum Kind: Sendable {
        /// Muted glyph, no plate.
        case plain
        /// Accent glyph on a tinted, accent-bordered plate (`.view-btn.on`).
        case active
        /// Dark glyph on an accent plate (the dashboard's "+" button).
        case primary
    }

    var kind: Kind = .plain

    func makeBody(configuration: Configuration) -> some View {
        DMIconButtonBody(configuration: configuration, kind: kind)
    }
}

extension ButtonStyle where Self == DMIconButtonStyle {
    static var dmIcon: DMIconButtonStyle { DMIconButtonStyle() }

    static func dmIcon(_ kind: DMIconButtonStyle.Kind) -> DMIconButtonStyle {
        DMIconButtonStyle(kind: kind)
    }
}

private struct DMIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: DMIconButtonStyle.Kind

    @Environment(\.isEnabled) private var isEnabled

    private var foreground: Color {
        switch kind {
        case .plain: configuration.isPressed ? Theme.textPrimary : Theme.textMuted
        case .active: Theme.accent
        case .primary: Theme.onAccent
        }
    }

    private var plate: Color {
        switch kind {
        case .plain: configuration.isPressed ? Theme.surface2 : .clear
        case .active: Theme.accent.opacity(configuration.isPressed ? 0.22 : 0.14)
        case .primary: Theme.accent
        }
    }

    var body: some View {
        configuration.label
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(foreground)
            .frame(width: 34, height: 34)
            .background(plate, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay {
                if kind == .active {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.45), lineWidth: Theme.Layout.hairline)
                }
            }
            .brightness(kind == .primary && configuration.isPressed ? -0.08 : 0)
            .opacity(isEnabled ? 1 : 0.5)
            // Lays out as the 34-point plate; the touch target reaches 44 points.
            .padding(5)
            .contentShape(Rectangle())
            .padding(-5)
    }
}

#Preview("Buttons") {
    VStack(spacing: 16) {
        HStack(spacing: 8) {
            Button("Try again") {}.buttonStyle(.dm(.primary))
            Button("Change setup") {}.buttonStyle(.dm())
            Button("Remove") {}.buttonStyle(.dm(.destructive))
        }
        HStack(spacing: 8) {
            Button("Wake") {}.buttonStyle(.dm(size: .small))
            Button {} label: { Label("Copy", systemImage: "doc.on.doc") }.buttonStyle(.dm(size: .small))
            Button("Disabled") {}.buttonStyle(.dm(.primary, size: .small)).disabled(true)
        }
        Button("Pair with hub") {}.buttonStyle(.dm(.primary, size: .large, fillsWidth: true))
        HStack(spacing: 4) {
            Button {} label: { Image(systemName: "ellipsis") }.buttonStyle(.dmIcon).accessibilityLabel("Device options")
            Button {} label: { Image(systemName: "bolt") }.buttonStyle(.dmIcon(.active)).accessibilityLabel("Advanced")
            Button {} label: { Image(systemName: "plus") }.buttonStyle(.dmIcon(.primary)).accessibilityLabel("Add device")
        }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.page)
}
