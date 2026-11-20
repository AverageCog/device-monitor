import SwiftUI

extension View {
    /// A filled, hairline-bordered rounded surface: the look shared by cards, tiles, panels and menus.
    func dmSurface(_ fill: Color = Theme.surface1, radius: CGFloat = Theme.Radius.card, border: Color = Theme.border) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(border, lineWidth: Theme.Layout.hairline)
            }
    }

    /// Page background and dark bars for a top-level screen. Apply inside the `NavigationStack`.
    func dmScreen() -> some View {
        background(Theme.page.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .toolbarBackground(Theme.page.opacity(0.9), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

/// The card container of the device grid (`.card`): surface-1, hairline border, radius 14.
/// An offline card is dimmed as a whole, exactly like `.card.offline`.
struct DMCard<Content: View>: View {
    private let isOffline: Bool
    private let spacing: CGFloat
    private let padding: EdgeInsets
    private let content: Content

    init(
        isOffline: Bool = false,
        spacing: CGFloat = Theme.Spacing.m,
        padding: EdgeInsets = Theme.Layout.cardPadding,
        @ViewBuilder content: () -> Content
    ) {
        self.isOffline = isOffline
        self.spacing = spacing
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(padding)
        .dmSurface(Theme.surface1, radius: Theme.Radius.card)
        .opacity(isOffline ? Theme.Layout.offlineOpacity : 1)
    }
}

/// A one-point separator in the border colour.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(height: Theme.Layout.hairline)
            .accessibilityHidden(true)
    }
}

#Preview("Card") {
    VStack(spacing: 16) {
        DMCard {
            Text("Gaming PC").dmFont(.cardTitle).foregroundStyle(Theme.textPrimary)
            Text("Windows 11 Pro · up 5h 12m · v1.2.27").dmFont(.caption).foregroundStyle(Theme.textMuted)
        }
        DMCard(isOffline: true) {
            Text("Home Server").dmFont(.cardTitle).foregroundStyle(Theme.textPrimary)
            Hairline()
            Text("offline · last seen 3h ago").dmFont(.caption).foregroundStyle(Theme.textMuted)
        }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.page)
    .preferredColorScheme(.dark)
}
