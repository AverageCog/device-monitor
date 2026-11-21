import DMCore
import SwiftUI

/// The electricity price editor on its own, for the Advanced tab's "Change…" (the dashboard opens
/// its settings dialog at the price row for that). Presented by the tab shell for
/// `AppRouter.showElectricityPrice()`; the environment is the tabs'.
struct ElectricityPriceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    SettingsPriceEditor(placement: .sheet)
                        .padding(Theme.Spacing.l)
                        .dmSurface(Theme.surface1, radius: Theme.Radius.card)
                    Text(PriceEditorNotes.shared)
                        .dmFont(.caption)
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Theme.Spacing.xs)
                }
                .frame(maxWidth: 560)
                .padding(Theme.Layout.screenPadding(for: sizeClass))
                .settingsDebugWidth()
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("screen-electricity-price")
            .navigationTitle(PriceEditor.Labels.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(PriceEditorNotes.done) { dismiss() }
                        .accessibilityIdentifier("electricity-price-done-button")
                }
            }
            .dmScreen()
        }
        .preferredColorScheme(.dark)
    }
}

#Preview("Electricity price") {
    ElectricityPriceSheet()
        .demoEnvironment()
}
