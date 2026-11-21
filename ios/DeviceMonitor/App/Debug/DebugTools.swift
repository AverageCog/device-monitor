#if DEBUG
import SwiftUI

/// Debug-only entry points: the component gallery, a routing check, the PhaseContainer check and a
/// phase switcher.
/// Lives on the placeholder Devices tab; whoever replaces that screen should keep it reachable
/// in DEBUG builds (the Settings screen is a good home).
struct DebugTools: View {
    @Environment(AppRouter.self) private var router
    @Environment(PlaceholderSession.self) private var session

    /// `-dm-gallery` opens the gallery straight away.
    @State private var showsGallery = DebugLaunchOptions.current.showsGallery
    /// `-dm-probe phase-container` opens the PhaseContainer check straight away.
    @State private var showsPhaseProbe = DebugLaunchOptions.current.probe == "phase-container"

    var body: some View {
        SettingsSection("Debug", footer: "Only in DEBUG builds.") {
            Button {
                showsGallery = true
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
            .navigationDestination(isPresented: $showsGallery) {
                ComponentGallery(initialSection: DebugLaunchOptions.current.gallerySection)
            }

            SettingsRow("History routing", description: "Opens the History tab for a made-up device through AppRouter.") {
                Button("Open") { router.openHistory(for: "demo-device") }
                    .buttonStyle(.dm(size: .small))
                    .accessibilityIdentifier("debug-open-history")
            }

            SettingsRow("Phase container", description: "Checks that a phase screen keeps its state when it starts scrolling.") {
                Button("Open") { showsPhaseProbe = true }
                    .buttonStyle(.dm(size: .small))
                    .accessibilityIdentifier("debug-open-phase-probe")
            }
            .fullScreenCover(isPresented: $showsPhaseProbe) {
                PhaseContainerProbe()
            }

            SettingsRow("App phase", description: "Switches RootView to another phase.") {
                Menu {
                    ForEach(AppPhase.allCases, id: \.self) { phase in
                        Button(phase.rawValue.capitalized) { session.phase = phase }
                    }
                } label: {
                    Label(session.phase.rawValue.capitalized, systemImage: "chevron.up.chevron.down")
                }
                .buttonStyle(.dm(size: .small))
                .accessibilityIdentifier("debug-phase-menu")
            }
        }
    }
}
#endif
