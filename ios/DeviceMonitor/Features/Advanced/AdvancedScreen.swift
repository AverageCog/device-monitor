import DMCore
import SwiftUI

// INTERIM — replaced by the Advanced feature (electricity and usage).
struct AdvancedScreen: View {
    @Environment(HubStore.self) private var store
    @Environment(AppRouter.self) private var router

    var body: some View {
        FeaturePlaceholder(systemImage: AppTab.advanced.systemImage, message: "Electricity cost and usage totals go here.\n\(price)", identifier: "screen-advanced") {
            Button("Electricity price") { router.showElectricityPrice() }
                .buttonStyle(.dm())
                .accessibilityIdentifier("advanced-price-button")
        }
        .navigationTitle("Advanced")
    }

    private var price: String {
        guard store.isEnergySettingsLoaded else { return "Asking the hub for the electricity price…" }
        guard let saved = store.energySettings else { return "No electricity price saved on the hub." }
        return "Price saved on the hub: \(saved.region)."
    }
}

#Preview {
    NavigationStack { AdvancedScreen().dmScreen() }
        .demoEnvironment()
}
