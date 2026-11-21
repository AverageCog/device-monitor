import DMCore
import SwiftUI

/// A session of its own with nothing real behind it, for SwiftUI previews: the demo hub, an
/// in-memory credential store and preferences that are thrown away. It is the same
/// `SessionController`, `HubStore`, `Preferences` and `AppRouter` the app injects, so a screen
/// previews exactly as it runs in demo mode.
///
/// ```swift
/// #Preview {
///     NavigationStack { DashboardScreen().dmScreen() }
///         .demoEnvironment()
/// }
/// ```
final class DemoEnvironment {
    nonisolated enum Start: Sendable {
        /// The demo is running: `HubStore` is in the environment and goes live at once.
        case demo
        /// Not paired, as on first launch. There is no `HubStore`.
        case onboarding
    }

    let session: SessionController
    let router = AppRouter()

    init(_ start: Start = .demo, tab: AppTab = .devices) {
        // A suite of its own, emptied, so a preview neither reads nor leaves anything behind.
        let suite = "com.devicemonitor.ios.preview"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        session = SessionController(credentials: InMemoryCredentialStore(), preferences: Preferences(defaults: defaults), defaults: defaults)
        router.selectedTab = tab
        session.launch()
        if start == .demo { session.startDemo() }
    }
}

extension View {
    /// Everything a screen reads from the environment, backed by the demo hub. See `DemoEnvironment`.
    func demoEnvironment(_ start: DemoEnvironment.Start = .demo, tab: AppTab = .devices) -> some View {
        modifier(DemoEnvironmentModifier(environment: DemoEnvironment(start, tab: tab)))
    }
}

private struct DemoEnvironmentModifier: ViewModifier {
    @State var environment: DemoEnvironment

    func body(content: Content) -> some View {
        content
            // Nil while onboarding; the app itself only injects the store under the tabs.
            .environment(environment.session.store)
            .appEnvironment(session: environment.session, router: environment.router)
    }
}
