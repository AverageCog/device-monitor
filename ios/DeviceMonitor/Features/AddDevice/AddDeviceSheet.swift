import DMCore
import SwiftUI

// INTERIM — replaced by the Add Device feature.
// Presented by the tab shell for `AppRouter.showAddDevice()`; the environment is the tabs'.
struct AddDeviceSheet: View {
    @Environment(HubStore.self) private var store
    @Environment(SessionController.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FeaturePlaceholder(
                systemImage: "plus.circle",
                message: "Sharing a browser link and the steps to add computers go here.\nHub: \(session.hubOriginText ?? "none")" + (store.info?.canShare == true ? ", can share." : "."),
                identifier: "screen-add-device"
            )
            .navigationTitle("Add a device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("add-device-done-button")
                }
            }
            .dmScreen()
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    AddDeviceSheet()
        .demoEnvironment()
}
