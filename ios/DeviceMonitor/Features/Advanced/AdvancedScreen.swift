import SwiftUI

// PLACEHOLDER — the Advanced feature (electricity and usage) replaces this file wholesale.
struct AdvancedScreen: View {
    var body: some View {
        FeaturePlaceholder(systemImage: AppTab.advanced.systemImage, message: "Electricity cost and usage totals go here.", identifier: "screen-advanced")
            .navigationTitle("Advanced")
    }
}

#Preview {
    NavigationStack { AdvancedScreen().dmScreen() }
        .preferredColorScheme(.dark)
}
