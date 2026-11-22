import SwiftUI

/// A tab's title as the first thing on its page, set like a large navigation title, with room for
/// a button at the end of the line. It scrolls away with the page like the rest of it, instead of
/// shrinking into a bar that stays; the page gives up its navigation bar for it (`dmTitledPage()`).
///
/// From iOS 26, as `dmTitledPage()` is; before that the tab keeps its navigation bar and the large
/// title in it, and this draws nothing.
struct DMPageTitle<Accessory: View>: View {
    private let title: String
    private let accessory: Accessory

    init(_ title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        if #available(iOS 26, *) {
            HStack(spacing: Theme.Spacing.m) {
                Text(title)
                    // The navigation bar's large title, which this one stands in for.
                    .font(.largeTitle.bold())
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("page-title")
                Spacer(minLength: 0)
                accessory
            }
            .padding(.bottom, Theme.Spacing.m)
        }
    }
}

extension DMPageTitle where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}
