import SwiftUI

/// The product mark: the gauge of the app icon, drawn live so it can also show what the app is
/// doing. Geometry and colours are those of Resources/make-app-icon.js (and build/make-icon.js).
struct OnboardingMark: View {
    enum Mode: Equatable {
        /// The icon as it is.
        case brand
        /// The needle sweeps back and forth: the app is looking for the hub.
        case seeking
        /// No reading: an unlit dial with the needle at rest.
        case idle
    }

    /// A small status glyph on the mark's corner.
    struct Badge: Equatable {
        let systemImage: String
        let color: Color

        static let unreachable = Badge(systemImage: "wifi.slash", color: Theme.warning)
        static let revoked = Badge(systemImage: "lock.fill", color: Theme.serious)
    }

    var mode: Mode = .brand
    var size: CGFloat = 72
    var badge: Badge?

    /// Where the icon's needle rests: the end of its coloured sweep, 205° of the dial's 270°.
    private static let rest = 205.0 / 270.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var level = OnboardingMark.rest

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        OnboardingDial(level: mode == .idle ? 0 : level, isLit: mode != .idle)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Theme.surface1, Theme.page], startPoint: .top, endPoint: .bottom), in: shape)
            .overlay { shape.strokeBorder(Theme.border, lineWidth: Theme.Layout.hairline) }
            // A lit dial throws a little of its light on the page.
            .shadow(color: Theme.accent.opacity(mode == .idle ? 0 : 0.22), radius: size * 0.3, y: size * 0.08)
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Image(systemName: badge.systemImage)
                        .font(.system(size: size * 0.2, weight: .semibold))
                        .foregroundStyle(badge.color)
                        .frame(width: size * 0.42, height: size * 0.42)
                        .background(Theme.surface2, in: Circle())
                        .overlay { Circle().strokeBorder(Theme.page, lineWidth: 3) }
                        .offset(x: size * 0.14, y: size * 0.14)
                }
            }
            .accessibilityHidden(true)
            .onAppear(perform: animate)
            .onChange(of: mode) { animate() }
            .onChange(of: reduceMotion) { animate() }
    }

    private func animate() {
        guard mode == .seeking, !reduceMotion else {
            withAnimation(nil) { level = Self.rest }
            return
        }
        level = 0.2
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { level = 0.86 }
    }
}

/// The dial: a 270° track, the three-colour sweep up to `level`, and the needle.
private struct OnboardingDial: View, Animatable {
    /// 0–1 along the arc, from bottom left, clockwise.
    var level: Double
    var isLit: Bool

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    var body: some View {
        let level = min(1, max(0, level))
        let isLit = isLit
        Canvas { context, size in
            // make-app-icon.js: CY, R, W, HUB, NEEDLE_W, as fractions of the icon's side.
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2 + side * 0.038)
            let radius = side * 0.305
            let width = side * 0.074

            func arc(from: Double, to: Double) -> Path {
                var path = Path()
                path.addArc(center: center, radius: radius, startAngle: .degrees(135 + from), endAngle: .degrees(135 + to), clockwise: false)
                return path
            }

            context.stroke(arc(from: 0, to: 270), with: .color(Theme.axis), lineWidth: width)
            if isLit {
                let end = level * 270
                let sweep: [(Double, Double, Color)] = [(0, 95, Theme.cpu), (95, 185, Theme.accent), (185, 270, Theme.gpu)]
                for (from, to, color) in sweep where end > from {
                    context.stroke(arc(from: from, to: min(to, end)), with: .color(color), lineWidth: width)
                }
            }

            let needleColor = isLit ? Theme.textPrimary : Theme.textMuted
            let angle = (135 + level * 270) * .pi / 180
            let reach = radius - width
            var needle = Path()
            needle.move(to: center)
            needle.addLine(to: CGPoint(x: center.x + cos(angle) * reach, y: center.y + sin(angle) * reach))
            context.stroke(needle, with: .color(needleColor), lineWidth: side * 0.04)
            let hub = side * 0.05
            context.fill(Path(ellipseIn: CGRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2)), with: .color(needleColor))
        }
    }
}

#Preview("Mark") {
    HStack(spacing: 28) {
        OnboardingMark()
        OnboardingMark(mode: .seeking)
        OnboardingMark(mode: .idle, badge: .unreachable)
        OnboardingMark(mode: .idle, badge: .revoked)
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.page)
    .preferredColorScheme(.dark)
}
