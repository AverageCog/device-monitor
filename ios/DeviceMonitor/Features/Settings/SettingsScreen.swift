import SwiftUI

// PLACEHOLDER — the Settings feature replaces this file wholesale.
// Build it from SettingsSection / SettingsRow / SettingsToggleRow in DesignSystem/FormRows.swift.
struct SettingsScreen: View {
    var body: some View {
        FeaturePlaceholder(systemImage: AppTab.settings.systemImage, message: "Temperature unit, electricity price, hub details and Disconnect go here.", identifier: "screen-settings")
            .navigationTitle("Settings")
    }
}

#Preview {
    NavigationStack { SettingsScreen().dmScreen() }
        .preferredColorScheme(.dark)
}
