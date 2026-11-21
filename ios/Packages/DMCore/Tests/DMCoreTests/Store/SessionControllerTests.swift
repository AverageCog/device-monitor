import Foundation
import os
import Testing
@testable import DMCore

/// A credential store that notes what was asked of it and can be made to fail.
final class RecordingCredentials: CredentialStore {
    struct Failures: Sendable {
        var load: CredentialStoreError?
        var save: CredentialStoreError?
        var clear: CredentialStoreError?
    }

    private struct State: Sendable {
        var enrollment: Enrollment?
        var calls: [String] = []
        var failures = Failures()
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ enrollment: Enrollment? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(enrollment: enrollment))
    }

    var enrollment: Enrollment? { state.withLock { $0.enrollment } }
    /// "load", "save", "clear", in order, failed ones included.
    var calls: [String] { state.withLock { $0.calls } }
    func fail(_ change: @Sendable (inout Failures) -> Void) { state.withLock { change(&$0.failures) } }

    func load() throws -> Enrollment? {
        try state.withLock { state in
            state.calls.append("load")
            if let failure = state.failures.load { throw failure }
            return state.enrollment
        }
    }

    func save(_ enrollment: Enrollment) throws {
        try state.withLock { state in
            state.calls.append("save")
            if let failure = state.failures.save { throw failure }
            state.enrollment = enrollment
        }
    }

    func clear() throws {
        try state.withLock { state in
            state.calls.append("clear")
            if let failure = state.failures.clear { throw failure }
            state.enrollment = nil
        }
    }
}

/// What the session asked of pairing and of the connection factory.
final class SessionLog: Sendable {
    struct Attempt: Sendable, Equatable {
        var origin: String
        var code: String
        var name: String
    }

    private struct State: Sendable {
        var attempts: [Attempt] = []
        var opened: [String] = []
        var closed = 0
        var answer: @Sendable (Invitation, String) async throws -> Enrollment = { _, _ in throw HubError.notDeviceMonitorHub }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var attempts: [Attempt] { state.withLock { $0.attempts } }
    /// The enrollment id of every link opened, in order.
    var opened: [String] { state.withLock { $0.opened } }
    var closed: Int { state.withLock { $0.closed } }

    func answerPairing(_ answer: @escaping @Sendable (Invitation, String) async throws -> Enrollment) {
        state.withLock { $0.answer = answer }
    }

    func pair(_ invitation: Invitation, _ name: String) async throws -> Enrollment {
        let answer = state.withLock { state in
            state.attempts.append(Attempt(origin: invitation.origin.string, code: invitation.code, name: name))
            return state.answer
        }
        return try await answer(invitation, name)
    }

    func link(_ enrollment: Enrollment, to hub: any HubAPI) -> HubLink {
        state.withLock { $0.opened.append(enrollment.id) }
        return HubLink(api: hub) { [self] in state.withLock { $0.closed += 1 } }
    }
}

enum SessionFixtures {
    static let origin = "https://hub.test:8443"
    static let code = String(repeating: "j", count: 43)
    static let invitation = origin + "/mobile#join=" + code
    static let unreachableMessage = "Could not connect to https://hub.test:8443 and verify its identity. Retrying automatically."
    static let refusal = HubError.unauthorized(status: 401, message: "Open a fresh dashboard invitation.")
    static let noConnection = HubError.unreachable("Could not connect to the hub.")

    static func enrollment(origin: String = SessionFixtures.origin, id: String = "0b0e2f6e-7a51-4d0c-9a0b-0f3c5d1e2a44", name: String = "Test iPhone") -> Enrollment {
        try! Enrollment(
            origin: try! HubOrigin(origin), id: id, client: String(repeating: "c", count: 43), proof: String(repeating: "p", count: 43),
            pin: String(repeating: "A", count: 43) + "=", name: name, pairedAt: Date(timeIntervalSince1970: 1_795_000_000))
    }

    static let devices = [StoreFixtures.device("a", order: 0), StoreFixtures.device("b", order: 1)]
}

/// A session over a scripted hub, a hand-moved clock and stores the test can read.
@MainActor
struct SessionHarness {
    let hub = ScriptedHub()
    let clock = ManualHubClock(now: StoreFixtures.now)
    let log = SessionLog()
    let credentials: RecordingCredentials
    let preferences: Preferences
    let defaults: UserDefaults
    let session: SessionController

    /// - Parameters:
    ///   - stored: what the credential store holds at launch.
    ///   - launchedBefore: whether the app has run since it was installed.
    init(stored: Enrollment? = nil, launchedBefore: Bool = true) {
        credentials = RecordingCredentials(stored)
        (preferences, defaults) = StoreFixtures.preferences()
        if launchedBefore { defaults.set(true, forKey: SessionController.Key.hasLaunched.rawValue) }
        session = Self.session(hub: hub, clock: clock, log: log, credentials: credentials, preferences: preferences, defaults: defaults)
    }

    static func session(
        hub: ScriptedHub, clock: ManualHubClock, log: SessionLog, credentials: RecordingCredentials, preferences: Preferences, defaults: UserDefaults
    ) -> SessionController {
        SessionController(
            credentials: credentials, preferences: preferences, defaults: defaults, clock: clock,
            pairing: { try await log.pair($0, $1) },
            connecting: { enrollment, _ in log.link(enrollment, to: hub) },
            demo: { DemoHubAPI(clock: $0) })
    }

    /// A second launch of the app: a new session over the same stores.
    func relaunched() -> SessionController {
        Self.session(hub: hub, clock: clock, log: log, credentials: credentials, preferences: Preferences(defaults: defaults), defaults: defaults)
    }

    var store: HubStore {
        get throws { try #require(session.store) }
    }

    func connection(_ index: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws -> ScriptedHub.Connection {
        try await eventually("connection \(index) is opened", sourceLocation: sourceLocation) { hub.connections.count > index }
        return hub.connections[index]
    }

    /// Launches with the stored enrollment and takes the session live.
    @discardableResult
    func goLive(sourceLocation: SourceLocation = #_sourceLocation) async throws -> ScriptedHub.Connection {
        session.launch()
        let connection = try await connection(hub.connections.count, sourceLocation: sourceLocation)
        connection.send(.snapshot(SessionFixtures.devices))
        try await eventually("the session is live", sourceLocation: sourceLocation) { session.phase == .live }
        // Only the store's series timer is left waiting: the session's own timer was put away.
        try await sleepers(1, sourceLocation: sourceLocation)
        return connection
    }

    /// Waits until exactly `count` tasks wait on the clock.
    func sleepers(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await eventually("\(count) tasks wait on the clock", sourceLocation: sourceLocation) { clock.sleeperCount == count }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionControllerTests {
    let enrollment = SessionFixtures.enrollment()

    // MARK: Launch

    @Test func nothingHappensBeforeLaunch() async {
        let h = SessionHarness()
        #expect(h.session.phase == .connecting && h.session.store == nil && h.session.hub == nil && !h.session.isDemo)
        #expect(await h.session.pair(invitationText: SessionFixtures.invitation, name: "x") == false)
        h.session.startDemo()
        h.session.retryNow()
        h.session.pairAgain()
        await h.session.disconnect()
        #expect(h.session.store == nil && h.credentials.calls.isEmpty && h.log.attempts.isEmpty)
    }

    @Test func launchWithoutAnEnrollmentIsOnboarding() async {
        let h = SessionHarness()
        h.session.launch()
        #expect(h.session.phase == .onboarding && h.session.store == nil && h.session.hub == nil && h.session.pairingError == nil)
        #expect(h.credentials.calls == ["load"] && h.log.opened.isEmpty)
        h.session.launch()                                  // a second call does nothing
        #expect(h.credentials.calls == ["load"])
    }

    @Test func launchWithAnEnrollmentConnectsAndGoesLiveWithTheFirstSnapshot() async throws {
        let h = SessionHarness(stored: enrollment)
        h.session.launch()
        #expect(h.session.phase == .connecting)
        #expect(h.session.hub == PairedHub(enrollment) && h.session.hubOriginText == SessionFixtures.origin && !h.session.isDemo)
        #expect(h.log.opened == [enrollment.id] && h.credentials.calls == ["load"])
        let store = try h.store
        #expect(store.isRunning && store.connection == .connecting)

        let connection = try await h.connection(0)
        #expect(h.session.phase == .connecting)             // connected, but nothing has arrived
        connection.send(.snapshot(SessionFixtures.devices))
        try await eventually("the session is live") { h.session.phase == .live }
        #expect(store.devices.map(\.id) == ["a", "b"] && h.session.store === store)
        #expect(h.credentials.enrollment == enrollment)
    }

    @Test func theFirstLaunchAfterAnInstallForgetsAnEnrollmentLeftInTheKeychain() async throws {
        let h = SessionHarness(stored: enrollment, launchedBefore: false)
        h.session.launch()
        #expect(h.session.phase == .onboarding && h.session.store == nil && h.session.pairingError == nil)
        #expect(h.credentials.calls == ["load", "clear"] && h.credentials.enrollment == nil)
        // The old credential was never used.
        await settle()
        #expect(h.log.opened.isEmpty && h.hub.calls.isEmpty && h.hub.connections.isEmpty)
        #expect(h.defaults.bool(forKey: SessionController.Key.hasLaunched.rawValue))

        // From then on an enrollment is kept.
        h.log.answerPairing { [enrollment] _, _ in enrollment }
        #expect(await h.session.pair(invitationText: SessionFixtures.invitation, name: "x"))
        let next = h.relaunched()
        next.launch()
        #expect(next.phase == .connecting && h.credentials.enrollment == enrollment)
    }

    @Test func theFirstLaunchWithNothingStoredOnlyMarksTheInstall() {
        let h = SessionHarness(launchedBefore: false)
        h.session.launch()
        #expect(h.session.phase == .onboarding && h.credentials.calls == ["load"])
        #expect(h.defaults.bool(forKey: SessionController.Key.hasLaunched.rawValue))
    }

    @Test func anEnrollmentThatCannotBeDeletedOnTheFirstLaunchIsNotUsedEither() async {
        let h = SessionHarness(stored: enrollment, launchedBefore: false)
        h.credentials.fail { $0.clear = .keychain(status: -25300) }
        h.session.launch()
        #expect(h.session.phase == .onboarding && h.session.store == nil && h.log.opened.isEmpty)
        // Not marked, so the next launch tries to delete it again.
        #expect(h.defaults.object(forKey: SessionController.Key.hasLaunched.rawValue) == nil)
        h.credentials.fail { $0.clear = nil }
        let next = h.relaunched()
        next.launch()
        #expect(next.phase == .onboarding && h.credentials.enrollment == nil && h.log.opened.isEmpty)
    }

    @Test func pairingAfterAFailedCleanupSurvivesTheNextLaunch() async {
        let h = SessionHarness(stored: enrollment, launchedBefore: false)
        h.credentials.fail { $0.clear = .keychain(status: -25300) }
        h.session.launch()
        let fresh = SessionFixtures.enrollment(id: "11111111-2222-4333-8444-555555555555")
        h.log.answerPairing { _, _ in fresh }
        #expect(await h.session.pair(invitationText: SessionFixtures.invitation, name: "x"))
        h.credentials.fail { $0.clear = nil }
        let next = h.relaunched()
        next.launch()
        #expect(next.phase == .connecting && h.credentials.enrollment == fresh)
    }

    @Test func aKeychainThatCannotBeReadIsAskedAgainInTheForegroundAndNeverWiped() async throws {
        // Before the phone is first unlocked neither the Keychain nor the defaults can be read,
        // so the launch looks like the first one.
        let h = SessionHarness(stored: enrollment, launchedBefore: false)
        h.credentials.fail { $0.load = .keychain(status: -25308) }
        h.session.enterBackground()
        h.session.launch()
        #expect(h.session.phase == .onboarding && h.session.store == nil && h.credentials.calls == ["load"])
        #expect(h.session.pairingError == "The Keychain is unavailable (error -25308).")
        #expect(h.defaults.object(forKey: SessionController.Key.hasLaunched.rawValue) == nil)

        h.credentials.fail { $0.load = nil }
        h.session.enterForeground()
        #expect(h.session.phase == .connecting && h.session.store != nil && h.session.pairingError == nil)
        #expect(h.credentials.calls == ["load", "load"] && h.credentials.enrollment == enrollment)
        try await h.connection(0).send(.snapshot(SessionFixtures.devices))
        try await eventually("the session is live") { h.session.phase == .live }
        h.session.enterForeground()                         // read once is enough
        #expect(h.credentials.calls == ["load", "load"])
    }

    @Test func aKeychainThatStaysOutOfReachIsSaidSoAndCostsNoInvitation() async throws {
        // What an app without a Keychain entitlement gets, for example.
        let h = SessionHarness()
        h.credentials.fail { $0.load = .keychain(status: -34018) }
        h.session.launch()
        #expect(h.session.phase == .onboarding && h.session.pairingError == "The Keychain is unavailable (error -34018).")
        h.session.enterForeground()
        #expect(h.session.phase == .onboarding && h.session.pairingError == "The Keychain is unavailable (error -34018).")
        #expect(h.credentials.calls == ["load", "load"])

        // Pairing looks first: an invitation works once, and the enrollment could not be kept.
        h.log.answerPairing { [enrollment] _, _ in enrollment }
        #expect(await h.session.pair(invitationText: SessionFixtures.invitation, name: "x") == false)
        #expect(h.log.attempts.isEmpty && h.session.pairingError == "The Keychain is unavailable (error -34018).")
        #expect(h.credentials.calls == ["load", "load", "load"] && h.session.phase == .onboarding)

        // The demo needs no Keychain.
        h.session.startDemo()
        #expect(h.session.isDemo && h.session.pairingError == nil)
        h.session.stopDemo()

        // Once the Keychain answers, pairing goes ahead.
        h.credentials.fail { $0.load = nil }
        #expect(await h.session.pair(invitationText: SessionFixtures.invitation, name: "x"))
        #expect(h.log.attempts.count == 1 && h.credentials.enrollment == enrollment && h.session.phase == .connecting)
        #expect(h.credentials.calls == ["load", "load", "load", "load", "save"])
    }

    @Test func pairingFindsTheEnrollmentThatCouldNotBeReadBeforeAndKeepsTheInvitation() async throws {
        let h = SessionHarness(stored: enrollment)
        h.credentials.fail { $0.load = .keychain(status: -25308) }
        h.session.launch()
        #expect(h.session.phase == .onboarding)
        h.credentials.fail { $0.load = nil }
        #expect(await h.session.pair(invitationText: SessionFixtures.invitation, name: "x") == false)
        #expect(h.log.attempts.isEmpty && h.session.pairingError == nil)
        #expect(h.session.phase == .connecting && h.session.hub == PairedHub(enrollment) && h.credentials.enrollment == enrollment)
    }

    @Test func anUnreadableEnrollmentIsExplainedAndLeftForPairingToReplace() async {
        let h = SessionHarness(stored: enrollment)
        h.credentials.fail { $0.load = .corrupted }
        h.session.launch()
        #expect(h.session.phase == .onboarding && h.session.store == nil)
        #expect(h.session.pairingError == "The saved hub connection is unreadable. Pair with the hub again.")
        #expect(h.credentials.calls == ["load"])

        let fresh = SessionFixtures.enrollment(id: "11111111-2222-4333-8444-555555555555")
        h.log.answerPairing { _, _ in fresh }
        #expect(await h.session.pair(invitationText: SessionFixtures.invitation, name: "x"))
        #expect(h.session.pairingError == nil && h.credentials.enrollment == fresh)
    }

    @Test func anUnreadableEnrollmentIsDeletedOnTheFirstLaunch() {
        let h = SessionHarness(stored: enrollment, launchedBefore: false)
        h.credentials.fail { $0.load = .corrupted }
        h.session.launch()
        #expect(h.session.phase == .onboarding && h.session.pairingError == nil)
        #expect(h.credentials.calls == ["load", "clear"] && h.credentials.enrollment == nil)
    }

    // MARK: Pairing

    @Test func pairingStoresTheEnrollmentAndConnects() async throws {
        let h = SessionHarness()
        h.session.launch()
        let gate = Gate<Enrollment>()
        h.log.answerPairing { _, _ in try await gate.wait() }

        let pairing = Task { await h.session.pair(invitationText: "  " + SessionFixtures.invitation + "\n", name: "Jay's iPhone") }
        try await eventually("the hub is asked") { gate.arrivals == 1 }
        #expect(h.session.isPairing && h.session.phase == .onboarding && h.session.pairingError == nil)
        #expect(h.log.attempts == [.init(origin: SessionFixtures.origin, code: SessionFixtures.code, name: "Jay's iPhone")])
        // One at a time.
        #expect(await h.session.pair(invitationText: SessionFixtures.invitation, name: "again") == false)
        h.session.startDemo()
        #expect(h.session.store == nil && h.log.attempts.count == 1)

        gate.open(enrollment)
        #expect(await pairing.value)
        #expect(!h.session.isPairing && h.session.pairingError == nil && h.session.phase == .connecting)
        #expect(h.credentials.enrollment == enrollment && h.credentials.calls == ["load", "save"])
        #expect(h.log.opened == [enrollment.id] && h.session.hub == PairedHub(enrollment))

        try await h.connection(0).send(.snapshot(SessionFixtures.devices))
        try await eventually("the session is live") { h.session.phase == .live }
        // Paired: there is nothing to pair.
        #expect(await h.session.pair(invitationText: SessionFixtures.invitation, name: "x") == false)
        #expect(h.log.attempts.count == 1)
    }

    nonisolated static let notInvitations: [(String, String)] = [
        ("", "Scan or paste the complete invitation shown on the hub."),
        ("https://hub.test:8443/mobile", "Scan or paste the complete invitation shown on the hub."),
        ("https://hub.test:8443/mobile#join=short", "Scan or paste the complete invitation shown on the hub."),
        ("http://hub.test:8443/mobile#join=" + SessionFixtures.code, "Scan or paste the complete invitation shown on the hub."),
        ("https://hub.test:8443/pair#join=" + SessionFixtures.code,
         "This invitation is for a computer. On the hub, choose + → iPhone / iPad app and use that invitation instead."),
        ("https://hub.test:8443/unlock#join=" + SessionFixtures.code,
         "This link opens the dashboard in a browser. On the hub, choose + → iPhone / iPad app and use that invitation instead."),
    ]

    @Test(arguments: notInvitations)
    func textThatIsNotAnInvitationIsRefusedWithoutAskingAnyHub(text: String, message: String) async {
        let h = SessionHarness()
        h.session.launch()
        #expect(await h.session.pair(invitationText: text, name: "x") == false)
        #expect(h.session.pairingError == message && h.session.phase == .onboarding && !h.session.isPairing)
        #expect(h.log.attempts.isEmpty && h.credentials.calls == ["load"] && h.session.store == nil)
    }

    nonisolated static let refusedPairings: [(HubError, String)] = [
        (.http(status: 403, message: "Invitation is invalid, expired or already used."), "Invitation is invalid, expired or already used."),
        (.notDeviceMonitorHub, "The address is not a verified Device Monitor hub."),
        (.invalidEnrollmentResponse, "Invalid enrollment response."),
        (.unreachable("Could not connect to the hub."), "Could not connect to the hub."),
        (.untrustedCertificate("It is not trusted."), "The hub's certificate could not be verified. It is not trusted."),
        (.http(status: 400, message: "Too many enrolled devices"), "Too many enrolled devices"),
    ]

    @Test(arguments: refusedPairings)
    func aRefusedPairingStoresNothingAndSaysWhy(failure: HubError, message: String) async {
        let h = SessionHarness()
        h.session.launch()
        h.log.answerPairing { _, _ in throw failure }
        #expect(await h.session.pair(invitationText: SessionFixtures.invitation, name: "x") == false)
        #expect(h.session.pairingError == message && h.session.phase == .onboarding && !h.session.isPairing)
        #expect(h.credentials.calls == ["load"] && h.credentials.enrollment == nil && h.session.store == nil && h.log.opened.isEmpty)

        // The message goes when the next attempt starts, and stays away when it works.
        h.log.answerPairing { [enrollment] _, _ in enrollment }
        #expect(await h.session.pair(invitationText: SessionFixtures.invitation, name: "x"))
        #expect(h.session.pairingError == nil && h.session.phase == .connecting)
    }

    @Test func aPairingThatWasGivenUpLeavesNoMessage() async {
        let h = SessionHarness()
        h.session.launch()
        h.log.answerPairing { _, _ in throw CancellationError() }
        #expect(await h.session.pair(invitationText: SessionFixtures.invitation, name: "x") == false)
        #expect(h.session.pairingError == nil && h.session.phase == .onboarding)
    }

    @Test func anEnrollmentThatCannotBeStoredIsHandedBackToTheHub() async throws {
        let h = SessionHarness()
        h.session.launch()
        h.log.answerPairing { [enrollment] _, _ in enrollment }
        h.credentials.fail { $0.save = .keychain(status: -34018) }
        #expect(await h.session.pair(invitationText: SessionFixtures.invitation, name: "x") == false)
        #expect(h.session.pairingError == "The Keychain is unavailable (error -34018).")
        #expect(h.session.phase == .onboarding && h.session.store == nil && h.session.hub == nil && h.credentials.enrollment == nil)
        // The hub is told to forget the phone it has just enrolled, and no stream is opened.
        try await eventually("the hub is told") { h.hub.calls == ["unpairSelf"] && h.log.closed == 1 }
        #expect(h.log.opened == [enrollment.id] && h.hub.connections.isEmpty)
    }

    @Test func whatBelongsToOneHubIsForgottenWhenTheHubChanges() async throws {
        let h = SessionHarness()
        h.session.launch()
        h.preferences.temperatureUnit = .fahrenheit
        h.log.answerPairing { [enrollment] _, _ in enrollment }
        #expect(await h.session.pair(invitationText: SessionFixtures.invitation, name: "x"))
        h.preferences.setCardRange(.hour, for: "a")
        h.preferences.markAlertSeen(id: "e1", time: 5)

        // The same hub again, after a revocation: its choices are still good.
        h.session.pairAgain()
        #expect(h.session.phase == .onboarding)
        #expect(await h.session.pair(invitationText: SessionFixtures.invitation, name: "x"))
        #expect(h.preferences.cardRange(for: "a") == .hour && h.preferences.lastSeenAlertID == "e1")

        // Another hub: they are not.
        h.session.pairAgain()
        let other = SessionFixtures.enrollment(origin: "https://other.test", id: "11111111-2222-4333-8444-555555555555")
        h.log.answerPairing { _, _ in other }
        #expect(await h.session.pair(invitationText: "https://other.test/mobile#join=" + SessionFixtures.code, name: "x"))
        #expect(h.preferences.cardRange(for: "a") == .tenMinutes && h.preferences.lastSeenAlertID == nil)
        #expect(h.preferences.temperatureUnit == .fahrenheit && h.session.hubOriginText == "https://other.test")
        #expect(h.defaults.string(forKey: SessionController.Key.hubOrigin.rawValue) == "https://other.test")
    }

    // MARK: Losing the hub

    @Test func aLostStreamIsLiveForTenSecondsThenUnreachableUntilTheNextSnapshot() async throws {
        let h = SessionHarness(stored: enrollment)
        let first = try await h.goLive()
        let store = try h.store
        first.fail(.unreachable("The connection to the hub was lost."))
        try await eventually("the store is reconnecting") { store.connection == .reconnecting(since: StoreFixtures.now) }
        #expect(h.session.phase == .live && store.summaryText == "Reconnecting to hub…")

        // The series timer, the store's three seconds and the session's ten.
        try await h.sleepers(3)
        h.clock.advance(by: 9_999)
        let second = try await h.connection(1)              // the automatic retry, which gets no answer
        await settle()
        #expect(h.session.phase == .live)
        h.clock.advance(by: 1)
        try await eventually("the hub is declared unreachable") { h.session.phase == .unreachable(message: SessionFixtures.unreachableMessage) }
        #expect(h.session.unreachableReason == "The connection to the hub was lost." && h.session.store === store)
        #expect(store.devices.count == 2 && store.isRunning)            // what was known is kept, and retries go on

        second.send(.snapshot([StoreFixtures.device("a", order: 0)]))
        try await eventually("the session is live again") { h.session.phase == .live }
        #expect(store.devices.map(\.id) == ["a"] && h.session.store === store)

        // A second outage gets ten seconds of its own.
        try await h.sleepers(1)
        second.finish()
        try await eventually("the store is reconnecting") { store.connection == .reconnecting(since: StoreFixtures.now + 10_000) }
        try await h.sleepers(3)
        h.clock.advance(by: 9_999)
        await settle()
        #expect(h.session.phase == .live)
        h.clock.advance(by: 1)
        try await eventually("unreachable again") { h.session.phase == .unreachable(message: SessionFixtures.unreachableMessage) }
    }

    @Test func aStreamThatComesBackWithinTenSecondsNeverLeavesLive() async throws {
        let h = SessionHarness(stored: enrollment)
        let first = try await h.goLive()
        let store = try h.store
        first.finish()
        try await h.sleepers(3)
        h.clock.advance(by: 3_000)
        try await h.connection(1).send(.snapshot(SessionFixtures.devices))
        try await eventually("the store is live") { store.connection == .live }
        try await h.sleepers(1)                              // the ten-second timer was put away
        h.clock.advance(by: 60_000)
        await settle()
        #expect(h.session.phase == .live)
    }

    @Test func aFirstConnectionThatFailsIsUnreachableAtOnce() async throws {
        let h = SessionHarness(stored: enrollment)
        h.session.launch()
        try await h.connection(0).fail(SessionFixtures.noConnection)
        try await eventually("unreachable") { h.session.phase == .unreachable(message: SessionFixtures.unreachableMessage) }
        #expect(h.session.unreachableReason == "Could not connect to the hub." && h.clock.now == StoreFixtures.now)
        let store = try h.store
        #expect(store.isRunning && !store.hasSnapshot)

        // The store keeps trying every three seconds, and the first snapshot ends it.
        try await h.sleepers(3)
        h.clock.advance(by: 3_000)
        try await h.connection(1).fail(SessionFixtures.noConnection)
        try await eventually("a second failure") { store.failedAttempts == 2 }
        #expect(h.session.phase == .unreachable(message: SessionFixtures.unreachableMessage))
        try await h.sleepers(3)
        h.clock.advance(by: 3_000)
        try await h.connection(2).send(.snapshot(SessionFixtures.devices))
        try await eventually("live") { h.session.phase == .live }
    }

    @Test func aFirstConnectionThatGetsNoAnswerIsUnreachableAfterTenSeconds() async throws {
        let h = SessionHarness(stored: enrollment)
        h.session.launch()
        let connection = try await h.connection(0)
        try await h.sleepers(2)                              // the series timer and the session's ten seconds
        h.clock.advance(by: 9_999)
        await settle()
        #expect(h.session.phase == .connecting)
        h.clock.advance(by: 1)
        try await eventually("unreachable") { h.session.phase == .unreachable(message: SessionFixtures.unreachableMessage) }
        #expect(h.session.unreachableReason == nil)         // nothing has failed; nothing has answered
        connection.send(.snapshot(SessionFixtures.devices))
        try await eventually("live") { h.session.phase == .live }
    }

    @Test func tryAgainConnectsAtOnce() async throws {
        let h = SessionHarness(stored: enrollment)
        h.session.launch()
        try await h.connection(0).fail(SessionFixtures.noConnection)
        try await eventually("unreachable") { h.session.phase == .unreachable(message: SessionFixtures.unreachableMessage) }
        #expect(!h.session.isRetrying)

        h.session.retryNow()
        #expect(h.session.isRetrying)
        let second = try await h.connection(1)              // without the clock moving
        #expect(h.clock.now == StoreFixtures.now && h.session.phase == .unreachable(message: SessionFixtures.unreachableMessage))
        second.fail(SessionFixtures.noConnection)
        try await eventually("the attempt has failed") { !h.session.isRetrying }
        #expect(h.session.phase == .unreachable(message: SessionFixtures.unreachableMessage))

        h.session.retryNow()
        try await h.connection(2).send(.snapshot(SessionFixtures.devices))
        try await eventually("live") { h.session.phase == .live }
        #expect(!h.session.isRetrying)
        h.session.retryNow()                                // nothing to retry while live
        await settle()
        #expect(!h.session.isRetrying && h.hub.connections.count == 3)
    }

    // MARK: Revoked

    @Test func aRefusedStreamIsRevokedAndKeepsTheEnrollment() async throws {
        let h = SessionHarness(stored: enrollment)
        let first = try await h.goLive()
        let store = try h.store
        first.fail(SessionFixtures.refusal)
        try await eventually("revoked") { h.session.phase == .revoked }
        #expect(!store.isRunning && store.connection == .unauthorized && h.session.store === store)
        #expect(h.credentials.enrollment == enrollment && h.credentials.calls == ["load"] && h.session.hub == PairedHub(enrollment))
        // Nothing is retried, however long it is left.
        try await h.sleepers(0)
        h.clock.advance(by: 60_000)
        await settle()
        #expect(h.session.phase == .revoked && h.hub.connections.count == 1)

        // The next launch asks the hub again rather than trusting a verdict from before.
        let next = h.relaunched()
        next.launch()
        #expect(next.phase == .connecting)
        try await h.connection(1).fail(SessionFixtures.refusal)
        try await eventually("revoked again") { next.phase == .revoked }
        #expect(h.credentials.enrollment == enrollment)
    }

    @Test func aRefusedFirstConnectionIsRevokedNotUnreachable() async throws {
        let h = SessionHarness(stored: enrollment)
        h.session.launch()
        try await h.connection(0).fail(.unauthorized(status: 403, message: "HTTP 403"))
        try await eventually("revoked") { h.session.phase == .revoked }
        try await h.sleepers(0)
    }

    @Test func aRequestTheHubNoLongerAcceptsRevokesTheSession() async throws {
        let h = SessionHarness(stored: enrollment)
        try await h.goLive()
        let store = try h.store
        h.hub.on { $0.wake = { _ in throw SessionFixtures.refusal } }
        #expect(await storeError { try await store.wake(device: "a") } == SessionFixtures.refusal)
        #expect(h.session.phase == .revoked && h.credentials.enrollment == enrollment)
    }

    @Test func pairAgainForgetsTheEnrollmentAndReturnsToOnboarding() async throws {
        let h = SessionHarness(stored: enrollment)
        let first = try await h.goLive()
        let store = try h.store
        first.fail(SessionFixtures.refusal)
        try await eventually("revoked") { h.session.phase == .revoked }

        h.session.pairAgain()
        #expect(h.session.phase == .onboarding && h.session.store == nil && h.session.hub == nil && h.session.pairingError == nil)
        #expect(h.credentials.enrollment == nil && h.credentials.calls == ["load", "clear"])
        try await eventually("the connection is closed") { h.log.closed == 1 }
        #expect(!store.isRunning && h.hub.calls("unpairSelf").isEmpty)   // the hub has nothing left to be told

        // And a fresh invitation pairs again.
        let fresh = SessionFixtures.enrollment(id: "11111111-2222-4333-8444-555555555555")
        h.log.answerPairing { _, _ in fresh }
        #expect(await h.session.pair(invitationText: SessionFixtures.invitation, name: "x"))
        try await h.connection(1).send(.snapshot(SessionFixtures.devices))
        try await eventually("live") { h.session.phase == .live }
        #expect(h.session.store !== store && h.session.hub == PairedHub(fresh))
    }

    @Test func tryAgainAfterARevocationAsksTheHubOnceMore() async throws {
        let h = SessionHarness(stored: enrollment)
        let first = try await h.goLive()
        let store = try h.store
        first.fail(SessionFixtures.refusal)
        try await eventually("revoked") { h.session.phase == .revoked }

        h.session.retryNow()
        #expect(h.session.phase == .connecting && store.isRunning)
        try await h.connection(1).fail(SessionFixtures.refusal)
        try await eventually("revoked again") { h.session.phase == .revoked }

        h.session.retryNow()
        try await h.connection(2).send(.snapshot(SessionFixtures.devices))
        try await eventually("live") { h.session.phase == .live }
        #expect(h.session.store === store && h.credentials.calls == ["load"])
    }

    // MARK: Disconnect

    @Test func disconnectTellsTheHubThenForgetsIt() async throws {
        let h = SessionHarness(stored: enrollment)
        h.defaults.set(SessionFixtures.origin, forKey: SessionController.Key.hubOrigin.rawValue)
        let first = try await h.goLive()
        let store = try h.store
        h.preferences.setCardRange(.hour, for: "a")
        h.preferences.temperatureUnit = .fahrenheit
        let gate = Gate<Void>()
        h.hub.on { $0.unpairSelf = { try await gate.wait() } }

        let disconnecting = Task { await h.session.disconnect() }
        try await eventually("the hub is told") { gate.arrivals == 1 && first.isClosed }
        // Meanwhile the app looks as it did, the stream is closed, and nothing is forgotten yet.
        #expect(h.session.isDisconnecting && h.session.phase == .live && h.session.store === store)
        #expect(!store.isRunning && h.credentials.enrollment == enrollment)
        h.session.pairAgain()
        h.session.retryNow()
        h.session.enterBackground()
        h.session.enterForeground()
        #expect(h.session.phase == .live && h.credentials.enrollment == enrollment)

        gate.open(())
        await disconnecting.value
        #expect(h.session.phase == .onboarding && h.session.store == nil && h.session.hub == nil && !h.session.isDisconnecting)
        #expect(h.credentials.enrollment == nil && h.credentials.calls == ["load", "clear"] && h.log.closed == 1)
        #expect(h.hub.calls("unpairSelf").count == 1 && h.hub.connections.count == 1)
        // What belonged to that hub goes with it; what the user chose for the app stays.
        #expect(h.preferences.cardRange(for: "a") == .tenMinutes && h.preferences.temperatureUnit == .fahrenheit)
        #expect(h.defaults.string(forKey: SessionController.Key.hubOrigin.rawValue) == nil)
        await settle()
        #expect(h.log.closed == 1 && h.clock.sleeperCount == 0)

        let next = h.relaunched()
        next.launch()
        #expect(next.phase == .onboarding)
    }

    @Test func disconnectDoesNotWaitForAHubThatDoesNotAnswer() async throws {
        let h = SessionHarness(stored: enrollment)
        try await h.goLive()
        let gate = Gate<Void>()
        h.hub.on { $0.unpairSelf = { try await gate.wait() } }

        let disconnecting = Task { await h.session.disconnect() }
        try await eventually("the hub is told") { gate.arrivals == 1 }
        try await h.sleepers(1)                              // only the timeout is left
        h.clock.advance(by: SessionController.disconnectTimeout - 1)
        await settle()
        #expect(h.session.isDisconnecting && h.credentials.enrollment == enrollment)
        h.clock.advance(by: 1)
        await disconnecting.value
        #expect(h.session.phase == .onboarding && h.credentials.enrollment == nil && h.log.closed == 1)
    }

    @Test(arguments: [HubError.unreachable("Could not connect to the hub."), .http(status: 500, message: "HTTP 500"), SessionFixtures.refusal])
    func disconnectForgetsTheHubWhateverTheHubSays(failure: HubError) async throws {
        let h = SessionHarness(stored: enrollment)
        try await h.goLive()
        h.hub.on { $0.unpairSelf = { throw failure } }
        await h.session.disconnect()
        #expect(h.session.phase == .onboarding && h.session.store == nil && h.credentials.enrollment == nil && h.log.closed == 1)
        #expect(h.clock.now == StoreFixtures.now)
    }

    @Test func disconnectFromTheUnreachableScreenKeepsThatScreenUntilItIsDone() async throws {
        let h = SessionHarness(stored: enrollment)
        h.session.launch()
        try await h.connection(0).fail(SessionFixtures.noConnection)
        try await eventually("unreachable") { h.session.phase == .unreachable(message: SessionFixtures.unreachableMessage) }
        let gate = Gate<Void>()
        h.hub.on { $0.unpairSelf = { try await gate.wait() } }

        let disconnecting = Task { await h.session.disconnect() }
        try await eventually("the hub is told") { gate.arrivals == 1 }
        #expect(h.session.phase == .unreachable(message: SessionFixtures.unreachableMessage) && h.session.isDisconnecting)
        gate.fail(SessionFixtures.noConnection)
        await disconnecting.value
        #expect(h.session.phase == .onboarding && h.credentials.enrollment == nil)
    }

    @Test func disconnectAfterARevocationDoesNotAskTheHub() async throws {
        let h = SessionHarness(stored: enrollment)
        let first = try await h.goLive()
        first.fail(SessionFixtures.refusal)
        try await eventually("revoked") { h.session.phase == .revoked }
        await h.session.disconnect()
        #expect(h.session.phase == .onboarding && h.credentials.enrollment == nil && h.hub.calls("unpairSelf").isEmpty && h.log.closed == 1)
    }

    // MARK: Demo

    @Test func demoModeRunsWithoutTouchingTheCredentialStore() async throws {
        let h = SessionHarness()
        h.session.launch()
        h.preferences.temperatureUnit = .fahrenheit
        h.session.startDemo()
        #expect(h.session.isDemo && h.session.phase == .connecting && h.session.hub == nil)
        #expect(h.session.hubOriginText == "https://hub.demo.example")
        let store = try h.store
        try await eventually("the demo is live") { h.session.phase == .live && store.devices.count == 6 }
        #expect(store.onlineDevices.count == 5 && store.preferences === h.preferences)
        h.session.startDemo()                               // already running
        #expect(h.session.store === store)
        #expect(await h.session.pair(invitationText: SessionFixtures.invitation, name: "x") == false)

        // Reports flow when the demo's clock moves.
        try await advance(h.clock, until: "a report arrives") {
            store.series(for: DemoHubAPI.DeviceID.gamingPC).points.last?.t == StoreFixtures.now + 2_000
        }
        #expect(h.clock.now == StoreFixtures.now + 2_000)

        store.setRange(.hour, for: DemoHubAPI.DeviceID.gamingPC)
        h.session.stopDemo()
        #expect(h.session.phase == .onboarding && h.session.store == nil && !h.session.isDemo && h.session.demoHub == nil)
        #expect(!store.isRunning)
        // The demo's per-hub choices are dropped, the user's own are kept.
        #expect(h.preferences.cardRange(for: DemoHubAPI.DeviceID.gamingPC) == .tenMinutes && h.preferences.temperatureUnit == .fahrenheit)
        #expect(h.credentials.calls == ["load"] && h.log.opened.isEmpty && h.log.attempts.isEmpty)
        #expect(h.defaults.string(forKey: SessionController.Key.hubOrigin.rawValue) == nil)
        h.session.stopDemo()                                // nothing to stop
        #expect(h.session.phase == .onboarding)
    }

    @Test func disconnectInDemoModeLeavesTheDemo() async throws {
        let h = SessionHarness()
        h.session.launch()
        h.session.startDemo()
        try await eventually("the demo is live") { h.session.phase == .live }
        await h.session.disconnect()
        #expect(h.session.phase == .onboarding && !h.session.isDemo && h.credentials.calls == ["load"])
        h.session.pairAgain()                               // only for a paired hub
        #expect(h.credentials.calls == ["load"])
    }

    @Test func theDemoIsNotOfferedWhilePaired() async throws {
        let h = SessionHarness(stored: enrollment)
        try await h.goLive()
        let store = try h.store
        h.session.startDemo()
        #expect(!h.session.isDemo && h.session.store === store && h.session.phase == .live)
    }

    @Test func aDemoHubThatGoesAwayAndComesBackTakesTheSessionWithIt() async throws {
        let h = SessionHarness()
        h.session.launch()
        h.session.startDemo()
        let demo = try #require(h.session.demoHub)
        let store = try h.store
        try await eventually("the demo is live") { h.session.phase == .live }

        demo.setAvailability(.unreachable)
        try await eventually("the stream is lost") { store.connection == .reconnecting(since: StoreFixtures.now) }
        #expect(h.session.phase == .live)
        let message = "Could not connect to https://hub.demo.example and verify its identity. Retrying automatically."
        try await advance(h.clock, until: "unreachable") { h.session.phase == .unreachable(message: message) }
        #expect(h.clock.now == StoreFixtures.now + 10_000 && h.session.unreachableReason == "Could not connect to the hub.")

        demo.setAvailability(.reachable)
        try await advance(h.clock, until: "live again") { h.session.phase == .live }
        #expect(h.clock.now <= StoreFixtures.now + 13_000 && store.devices.count == 6)

        demo.revokeEnrollment()
        try await advance(h.clock, until: "revoked") { h.session.phase == .revoked }
        // Leaving the demo works from there too.
        await h.session.disconnect()
        #expect(h.session.phase == .onboarding)
    }

    // MARK: Background

    @Test func theStreamIsClosedInTheBackgroundAndReopenedInTheForeground() async throws {
        let h = SessionHarness(stored: enrollment)
        let first = try await h.goLive()
        let store = try h.store
        h.session.enterBackground()
        #expect(store.isSuspended && store.connection == .idle && h.session.phase == .live)
        try await eventually("the stream is closed") { first.isClosed }
        try await h.sleepers(0)
        h.clock.advance(by: 3_600_000)                      // an hour in the background: nothing ticks
        await settle()
        #expect(h.session.phase == .live && h.hub.connections.count == 1)
        h.session.enterBackground()                         // twice is once

        h.session.enterForeground()
        #expect(!store.isSuspended && store.connection == .reconnecting(since: StoreFixtures.now + 3_600_000) && h.session.phase == .live)
        try await h.connection(1).send(.snapshot(SessionFixtures.devices))
        try await eventually("live") { store.connection == .live }
        #expect(h.session.phase == .live)
        h.session.enterForeground()                         // already in front
        await settle()
        #expect(h.hub.connections.count == 2)
    }

    @Test func aHubThatStaysAwayAfterTheAppReturnsGetsTenSecondsFromThen() async throws {
        let h = SessionHarness(stored: enrollment)
        try await h.goLive()
        h.session.enterBackground()
        try await h.sleepers(0)
        h.clock.advance(by: 60_000)
        h.session.enterForeground()
        try await h.connection(1).fail(SessionFixtures.noConnection)
        try await h.sleepers(3)
        h.clock.advance(by: 9_999)
        await settle()
        #expect(h.session.phase == .live)
        h.clock.advance(by: 1)
        try await eventually("unreachable") { h.session.phase == .unreachable(message: SessionFixtures.unreachableMessage) }
    }

    @Test func theUnreachableScreenStaysWhileInTheBackground() async throws {
        let h = SessionHarness(stored: enrollment)
        h.session.launch()
        try await h.connection(0).fail(SessionFixtures.noConnection)
        try await eventually("unreachable") { h.session.phase == .unreachable(message: SessionFixtures.unreachableMessage) }
        h.session.enterBackground()
        #expect(h.session.phase == .unreachable(message: SessionFixtures.unreachableMessage))
        try await h.sleepers(0)

        // Back in front it connects afresh, with ten seconds to do it in.
        h.session.enterForeground()
        #expect(h.session.phase == .connecting)
        let second = try await h.connection(1)
        try await h.sleepers(2)
        h.clock.advance(by: 10_000)
        try await eventually("unreachable") { h.session.phase == .unreachable(message: SessionFixtures.unreachableMessage) }
        second.send(.snapshot(SessionFixtures.devices))
        try await eventually("live") { h.session.phase == .live }
    }

    @Test func aLaunchInTheBackgroundConnectsOnlyOnceTheAppIsInFront() async throws {
        let h = SessionHarness(stored: enrollment)
        h.session.enterBackground()
        h.session.launch()
        let store = try h.store
        #expect(h.session.phase == .connecting && store.isRunning && store.isSuspended)
        await settle()
        #expect(h.hub.connections.isEmpty && h.clock.sleeperCount == 0)
        // The store still answers when asked, which is what a background refresh does.
        h.hub.on { $0.alerts = { AlertsResponse(events: [StoreFixtures.alert("e1", t: 5)]) } }
        try await store.refreshAlerts()
        #expect(store.alerts.events.map(\.id) == ["e1"] && h.session.phase == .connecting)

        h.session.enterForeground()
        #expect(h.session.phase == .connecting && !store.isSuspended)
        try await h.connection(0).send(.snapshot(SessionFixtures.devices))
        try await eventually("live") { h.session.phase == .live }
    }

    @Test func aRevocationNoticedInTheBackgroundShowsWhenTheAppReturns() async throws {
        let h = SessionHarness(stored: enrollment)
        try await h.goLive()
        let store = try h.store
        h.session.enterBackground()
        h.hub.on { $0.alerts = { throw SessionFixtures.refusal } }
        #expect(await storeError { try await store.refreshAlerts() } == SessionFixtures.refusal)
        #expect(store.connection == .unauthorized)
        h.session.enterForeground()
        #expect(h.session.phase == .revoked)
    }

    // MARK: Notifier and lifetime

    @Test func everyStoreGetsTheSessionsNotifier() async throws {
        let h = SessionHarness(stored: enrollment)
        let probe = NotifierProbe()
        h.session.alertNotifier = probe
        let connection = try await h.goLive()
        let store = try h.store
        connection.send(.alert(event: StoreFixtures.alert("e1", t: 5), notify: true, active: []))
        try await eventually("the alert is announced") { probe.events.map(\.id) == ["e1"] }

        // Replaced later, it reaches the running store as well.
        let other = NotifierProbe()
        h.session.alertNotifier = other
        connection.send(.alert(event: StoreFixtures.alert("e2", t: 6), notify: true, active: []))
        try await eventually("the alert is announced") { other.events.map(\.id) == ["e2"] }
        #expect(probe.events.count == 1 && store.alerts.events.count == 2)

        await h.session.disconnect()
        h.session.startDemo()
        #expect(try h.store.alertNotifier as? NotifierProbe === other)
    }

    @Test func aSessionThatIsLetGoOfTakesItsStoreAndItsTimersWithIt() async throws {
        let hub = ScriptedHub(), clock = ManualHubClock(now: StoreFixtures.now), log = SessionLog()
        let credentials = RecordingCredentials(enrollment)
        let (preferences, defaults) = StoreFixtures.preferences()
        defaults.set(true, forKey: SessionController.Key.hasLaunched.rawValue)
        var session: SessionController? = SessionHarness.session(hub: hub, clock: clock, log: log, credentials: credentials, preferences: preferences, defaults: defaults)
        let sessionReference = WeakReference(session)
        session?.launch()
        let storeReference = WeakReference(session?.store)
        #expect(storeReference.object != nil)
        try await eventually("the stream is open") { hub.connections.count == 1 }
        hub.connections[0].fail(.unreachable("The connection to the hub was lost."))
        try await eventually("everything waits on the clock") { clock.sleeperCount == 3 }

        session = nil
        try await eventually("the session and its store are gone") { sessionReference.object == nil && storeReference.object == nil }
        try await eventually("nothing waits on the clock") { clock.sleeperCount == 0 }
    }
}

/// Moves the clock on in small steps until `condition` holds, letting whatever each step wakes run.
@MainActor
func advance(
    _ clock: ManualHubClock, by step: Double = 500, until what: String, limit: Double = 60_000,
    sourceLocation: SourceLocation = #_sourceLocation, _ condition: @MainActor () -> Bool
) async throws {
    var moved = 0.0
    while !condition() {
        guard moved < limit else {
            Issue.record("the clock moved \(Int(limit)) ms without reaching: \(what)", sourceLocation: sourceLocation)
            throw TimedOut()
        }
        await settle()
        if condition() { return }
        clock.advance(by: step)
        moved += step
        await settle()
    }
}
