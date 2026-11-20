import SwiftUI

/// Body of a screen whose feature has not been built yet. Each placeholder screen in Features/ is
/// replaced wholesale by its feature; this view goes away with the last of them.
struct FeaturePlaceholder<Extras: View>: View {
    private let systemImage: String
    private let message: String
    private let identifier: String
    private let extras: Extras

    /// - Parameters:
    ///   - identifier: Accessibility identifier of the screen, e.g. "screen-devices".
    ///   - extras: Extra content under the message (the Devices placeholder hosts the debug tools).
    init(systemImage: String, message: String, identifier: String, @ViewBuilder extras: () -> Extras) {
        self.systemImage = systemImage
        self.message = message
        self.identifier = identifier
        self.extras = extras()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.l) {
                EmptyStateView(message: message, systemImage: systemImage)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(identifier)
                extras
            }
            .frame(maxWidth: 560)
            .padding(Theme.Layout.screenPaddingCompact)
            .frame(maxWidth: .infinity)
        }
    }
}

extension FeaturePlaceholder where Extras == EmptyView {
    init(systemImage: String, message: String, identifier: String) {
        self.init(systemImage: systemImage, message: message, identifier: identifier) { EmptyView() }
    }
}
