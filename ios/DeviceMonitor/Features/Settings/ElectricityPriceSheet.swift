import DMCore
import SwiftUI

// INTERIM STUB — replaced by the Settings feature: the electricity price editor.
// Presented by the tab shell for `AppRouter.showElectricityPrice()`, from Settings and from
// Advanced; the environment is the tabs'. Saving goes through `store.saveEnergySettings(_:)`.
struct ElectricityPriceSheet: View {
    @Environment(HubStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FeaturePlaceholder(
                systemImage: "bolt",
                message: "The electricity price editor goes here.\n" + (store.energySettings.map { "Saved on the hub: \($0.region)." } ?? "Nothing saved on the hub."),
                identifier: "screen-electricity-price"
            )
            .navigationTitle("Electricity price")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("electricity-price-done-button")
                }
            }
            .dmScreen()
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ElectricityPriceSheet()
        .demoEnvironment()
}
