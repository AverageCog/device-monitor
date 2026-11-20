import Foundation
import Observation

/// What the app as a whole is showing.
nonisolated enum AppPhase: String, Equatable, Sendable, CaseIterable {
    /// No enrollment: pair with a hub.
    case onboarding
    /// Enrolled; the first connection to the hub is in progress.
    case connecting
    /// Connected: the tabs.
    case live
    /// The hub cannot be reached or verified. Retries automatically, like app/offline.html.
    case unreachable
    /// The verified hub answered 401/403: this enrollment is gone and the app must pair again.
    case revoked
}

// PLACEHOLDER — the next wave replaces this class with the DMCore-backed store. RootView only needs
// `phase` and the three actions below, so the store can adopt the same shape and this file's
// placeholder half can be deleted.
@Observable
final class PlaceholderSession {
    var phase: AppPhase

    init(phase: AppPhase = .onboarding) {
        self.phase = phase
    }

    /// "Try again" on the unreachable screen. Pretends the hub came back after a moment.
    func retry() {
        phase = .connecting
        Task {
            try? await Task.sleep(for: .seconds(1))
            if phase == .connecting { phase = .live }
        }
    }

    /// "Pair again" / "Change setup": back to onboarding.
    func pairAgain() {
        phase = .onboarding
    }

    /// Stands in for a successful pairing.
    func finishOnboarding() {
        phase = .live
    }
}

