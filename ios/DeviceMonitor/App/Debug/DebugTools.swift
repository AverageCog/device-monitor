#if DEBUG
import DMCore
import SwiftUI

/// Debug-only entry points: the component gallery, a routing check, the PhaseContainer check and,
/// when the app runs on a demo hub, ways to take that hub away.
///
/// A section for any screen to embed (the Devices tab has it at the end of its grid).
/// The gallery and the probe open over the tabs whether or not this section is on screen
/// (`-dm-gallery`, `-dm-probe`), so nothing breaks if a screen leaves it out.
struct DebugTools: View {
    @Environment(AppRouter.self) private var router
    @Environment(SessionController.self) private var session

    var body: some View {
        SettingsSection("Debug", footer: "Only in DEBUG builds.") {
            Button {
                router.debugScreen = .gallery
            } label: {
                SettingsRow("Component gallery", description: "Every design-system component with sample values.") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("debug-gallery-link")

            SettingsRow("History routing", description: "Opens the History tab for the first device through AppRouter.") {
                Button("Open") { router.openHistory(deviceID: session.store?.devices.first?.id ?? "nobody") }
                    .buttonStyle(.dm(size: .small))
                    .accessibilityIdentifier("debug-open-history")
            }

            SettingsRow("Phase container", description: "Checks that a phase screen keeps its state when it starts scrolling.") {
                Button("Open") { router.debugScreen = .phaseContainer }
                    .buttonStyle(.dm(size: .small))
                    .accessibilityIdentifier("debug-open-phase-probe")
            }

            if let hub = session.demoHub ?? AppModel.shared.debugHub {
                SettingsRow("Demo hub", description: "Takes the demo hub away or has it refuse this app. Ten seconds unreachable brings up the unreachable screen.") {
                    Menu {
                        Button("Reachable") { hub.setAvailability(.reachable) }
                        Button("Unreachable") { hub.setAvailability(.unreachable) }
                        Button("Unreachable for 20 s") { Self.interrupt(hub, for: .seconds(20)) }
                        Button("Silent") { hub.setAvailability(.silent) }
                        Button("Revoke this enrollment", role: .destructive) { hub.revokeEnrollment() }
                        Button("Fire a disk alert") { hub.simulateDiskAlert() }
                    } label: {
                        Label("Direct", systemImage: "chevron.up.chevron.down")
                    }
                    .buttonStyle(.dm(size: .small))
                    .accessibilityIdentifier("debug-hub-menu")
                }
            }
        }
    }

    /// Long enough to see the banner, then the unreachable screen, then the way back.
    static func interrupt(_ hub: DemoHubAPI, for duration: Duration) {
        hub.setAvailability(.unreachable)
        Task {
            try? await Task.sleep(for: duration)
            hub.setAvailability(.reachable)
        }
    }
}

/// A debug screen over the tabs, in a navigation stack of its own.
struct DebugScreenHost: View {
    let screen: DebugScreen
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch screen {
        case .gallery:
            NavigationStack {
                ComponentGallery(initialSection: DebugLaunchOptions.current.gallerySection)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { dismiss() }
                                .accessibilityIdentifier("gallery-close-button")
                        }
                    }
            }
            .preferredColorScheme(.dark)
        case .phaseContainer:
            PhaseContainerProbe()
                .preferredColorScheme(.dark)
        }
    }
}
#endif
