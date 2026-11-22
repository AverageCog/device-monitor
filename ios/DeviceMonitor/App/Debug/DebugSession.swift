#if DEBUG
import DMCore
import Foundation

/// A session "paired" with a demo hub that is made to behave one way, so that every phase can be
/// looked at without a real hub (`-dm-phase`). The enrollment is made up and kept in memory.
struct DebugSession {
    let session: SessionController
    let hub: DemoHubAPI

    init(phase: DebugLaunchOptions.Phase, preferences: Preferences) {
        // Left alone, `.connecting` turns into `.unreachable` after ten seconds; on a clock that
        // stands still it stays.
        let clock: any HubClock = phase == .connecting ? ManualHubClock() : SystemHubClock()
        let hub = DemoHubAPI(clock: clock)
        switch phase {
        case .onboarding, .live: break
        case .connecting: hub.setAvailability(.silent)
        case .unreachable: hub.setAvailability(.unreachable)
        case .revoked: hub.revokeEnrollment()
        }
        let defaults = Self.volatileDefaults()
        defaults.set(true, forKey: SessionController.Key.hasLaunched.rawValue)
        session = SessionController(
            credentials: InMemoryCredentialStore(Self.enrollment), preferences: preferences, defaults: defaults, clock: clock,
            // What a hub says to a code it does not know.
            pairing: { _, _ in throw HubError.http(status: 403, message: "Invitation is invalid, expired or already used.") },
            connecting: { _, _ in HubLink(api: hub) })
        self.hub = hub
    }

    /// Shaped like an enrollment and good for nothing: no hub issued these values.
    private static var enrollment: Enrollment? {
        guard let origin = try? HubOrigin("https://hub.demo.example") else { return nil }
        return try? Enrollment(
            origin: origin, id: DemoHubAPI.enrollmentID, client: String(repeating: "d", count: 43), proof: String(repeating: "e", count: 43),
            pin: String(repeating: "A", count: 43) + "=", name: "Debug iPhone", pairedAt: Date())
    }

    /// Defaults that start empty every time and are never the app's own.
    static func volatileDefaults() -> UserDefaults {
        let suite = "com.devicemonitor.ios.debug"
        guard let defaults = UserDefaults(suiteName: suite) else { return .standard }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
#endif
