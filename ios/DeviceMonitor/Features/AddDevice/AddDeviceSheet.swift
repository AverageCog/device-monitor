import SwiftUI

// PLACEHOLDER — the Add Device feature replaces this file wholesale.
// Presented as a sheet from the Devices tab's "+" button.
struct AddDeviceSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FeaturePlaceholder(systemImage: "plus.circle", message: "Sharing a browser link and the steps to add computers go here.", identifier: "screen-add-device")
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
        .tint(Theme.accent)
}
