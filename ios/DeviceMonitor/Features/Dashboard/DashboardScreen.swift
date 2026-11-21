import DMCore
import SwiftUI

// INTERIM — replaced by the Dashboard feature.
// Keep: the "Devices" title and the "+" toolbar button calling `router.showAddDevice()`.
// A plain list of devices, to show that the store's state arrives and keeps changing.
struct DashboardScreen: View {
    @Environment(HubStore.self) private var store
    @Environment(SessionController.self) private var session
    @Environment(AppRouter.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text(store.summaryText)
                    .dmFont(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("devices-summary")
                if session.isDemo {
                    BannerView("Demo mode: these devices are simulated.", kind: .info)
                        .accessibilityIdentifier("demo-banner")
                }
                VStack(spacing: 0) {
                    ForEach(store.devices) { device in
                        Button {
                            router.openHistory(deviceID: device.id)
                        } label: {
                            DeviceRow(device: device)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("device-row-\(device.id)")
                        if device.id != store.devices.last?.id { Hairline() }
                    }
                }
                .dmSurface()
                Text("interim — replaced by the Dashboard feature")
                    .dmFont(.caption)
                    .foregroundStyle(Theme.textMuted)
                #if DEBUG
                DebugTools()
                #endif
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(Theme.Layout.screenPaddingCompact)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("screen-devices")
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    router.showAddDevice()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add device")
                .accessibilityIdentifier("add-device-button")
            }
        }
    }
}

/// Name, whether it is online, and the CPU load of its latest report.
private struct DeviceRow: View {
    let device: Device

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            StatusDot(isOnline: device.online)
            Text(device.displayName)
                .dmFont(.rowTitle)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: Theme.Spacing.s)
            Text(status)
                .dmFont(.statValue)
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.m)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(device.displayName)
        .accessibilityValue(status)
    }

    private var status: String {
        device.online ? "online, CPU \(Theme.percentText(device.latest?.cpu.usage))" : "offline"
    }
}

#Preview {
    NavigationStack { DashboardScreen().dmScreen() }
        .demoEnvironment()
}
