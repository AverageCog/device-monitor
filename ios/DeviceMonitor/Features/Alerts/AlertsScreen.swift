import DMCore
import SwiftUI

// INTERIM — replaced by the Alerts feature (this file and AlertsIntegration.swift).
// The tab's badge (active alerts) is drawn by the tab shell.
struct AlertsScreen: View {
    @Environment(HubStore.self) private var store

    var body: some View {
        FeaturePlaceholder(
            systemImage: AppTab.alerts.systemImage,
            message: "Active alerts, the event log and alert rules go here.\n\(store.alerts.active.count) active, \(store.alerts.events.count) in the log.",
            identifier: "screen-alerts"
        )
        .navigationTitle("Alerts")
    }
}

#Preview {
    NavigationStack { AlertsScreen().dmScreen() }
        .demoEnvironment()
}
