import SwiftUI

// PLACEHOLDER — the Alerts feature replaces this file wholesale.
struct AlertsScreen: View {
    var body: some View {
        FeaturePlaceholder(systemImage: AppTab.alerts.systemImage, message: "Active alerts, the event log and alert rules go here.", identifier: "screen-alerts")
            .navigationTitle("Alerts")
    }
}

#Preview {
    NavigationStack { AlertsScreen().dmScreen() }
        .preferredColorScheme(.dark)
}
