import SwiftUI

// PLACEHOLDER — the Dashboard feature replaces this file wholesale.
// Keep: the "Devices" title, the "+" toolbar button presenting AddDeviceSheet, and (in DEBUG) a way
// to reach DebugTools, which hosts the component gallery.
struct DashboardScreen: View {
    @State private var isAddingDevice = false

    var body: some View {
        FeaturePlaceholder(systemImage: AppTab.devices.systemImage, message: "The device grid goes here.", identifier: "screen-devices") {
            #if DEBUG
            DebugTools()
            #endif
        }
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingDevice = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add device")
                .accessibilityIdentifier("add-device-button")
            }
        }
        .sheet(isPresented: $isAddingDevice) {
            AddDeviceSheet()
        }
    }
}

#Preview {
    NavigationStack { DashboardScreen().dmScreen() }
        .environment(AppRouter())
        .environment(PlaceholderSession(phase: .live))
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
}
