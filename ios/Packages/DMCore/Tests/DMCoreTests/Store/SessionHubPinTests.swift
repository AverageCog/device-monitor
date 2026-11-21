import Foundation
import Testing
@testable import DMCore

/// `SessionController.hubPin`: the TLS identity Settings shows.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionHubPinTests {
    let enrollment = SessionFixtures.enrollment()

    @Test func aPairedSessionShowsTheEnrolledPin() async throws {
        let h = SessionHarness(stored: enrollment)
        #expect(h.session.hubPin == nil, "Nothing is known before launch")
        try await h.goLive()
        #expect(h.session.hubPin == enrollment.pin)
    }

    @Test func aPinTheHubProvedLaterIsTheOneShown() async throws {
        let h = SessionHarness(stored: enrollment)
        try await h.goLive()
        // What HubClient does after a rotation proof: the same enrollment with the new pin.
        let rotated = String(repeating: "B", count: 43) + "="
        try h.credentials.save(try enrollment.withPin(rotated))
        #expect(h.session.hubPin == rotated)
    }

    @Test func thereIsNoPinWithoutAPairing() {
        let h = SessionHarness()
        h.session.launch()
        #expect(h.session.phase == .onboarding && h.session.hubPin == nil)
        h.session.startDemo()
        #expect(h.session.isDemo && h.session.hubPin == nil, "The demo hub has no TLS key")
    }

    @Test func aCredentialStoreThatCannotBeReadShowsNoPin() async throws {
        let h = SessionHarness(stored: enrollment)
        try await h.goLive()
        h.credentials.fail { $0.load = .keychain(status: -25308) }
        #expect(h.session.hubPin == nil)
    }

    @Test func disconnectingForgetsThePin() async throws {
        let h = SessionHarness(stored: enrollment)
        try await h.goLive()
        await h.session.disconnect()
        #expect(h.session.phase == .onboarding && h.session.hubPin == nil)
    }
}
