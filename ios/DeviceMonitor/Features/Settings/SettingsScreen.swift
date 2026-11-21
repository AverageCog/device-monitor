import DMCore
import SwiftUI

// INTERIM — replaced by the Settings feature (this file and ElectricityPriceSheet.swift).
// Build it from SettingsSection / SettingsRow / SettingsToggleRow in DesignSystem/FormRows.swift.
// What is here is the least the slice needs: which hub, and the way out. Asking "are you sure?"
// before disconnecting is the Settings feature's job.
struct SettingsScreen: View {
    @Environment(SessionController.self) private var session
    @Environment(AppRouter.self) private var router

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.l) {
                SettingsSection("Hub", footer: "interim — replaced by the Settings feature") {
                    SettingsRow(session.isDemo ? "Demo hub" : "Paired with", description: session.hubOriginText, isMonospaced: true)
                    if let name = session.hub?.name {
                        SettingsRow("This device", description: name)
                    }
                    SettingsRow("Electricity price") {
                        Button("Edit") { router.showElectricityPrice() }
                            .buttonStyle(.dm(size: .small))
                            .accessibilityIdentifier("settings-price-button")
                    }
                    SettingsRow(session.isDemo ? "Leave the demo" : "Disconnect from this hub") {
                        Button(session.isDemo ? "Exit demo" : "Disconnect") {
                            Task { await session.disconnect() }
                        }
                        .buttonStyle(.dm(.destructive, size: .small))
                        .disabled(session.isDisconnecting)
                        .accessibilityIdentifier("settings-disconnect-button")
                    }
                }
            }
            .frame(maxWidth: 560)
            .padding(Theme.Layout.screenPaddingCompact)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("screen-settings")
        .navigationTitle("Settings")
    }
}

#Preview {
    NavigationStack { SettingsScreen().dmScreen() }
        .demoEnvironment()
}
