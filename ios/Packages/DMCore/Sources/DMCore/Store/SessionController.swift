import Foundation
import Observation

/// What the app as a whole is showing.
public enum SessionPhase: Sendable, Equatable {
    /// Not paired: scan or paste an invitation (or try the demo).
    case onboarding
    /// Paired, and the hub's first snapshot has not arrived yet.
    case connecting
    /// The tabs. `SessionController.store` holds the hub's state; while its `connection` is
    /// `.reconnecting` the stream is down and what is on show is the last known state.
    case live
    /// The hub could not be reached: the first connection failed, or a lost one has not come
    /// back for ten seconds. The store keeps trying and the phase returns to `.live` with the
    /// next snapshot. `message` is app/offline.js's sentence for this hub.
    case unreachable(message: String)
    /// The verified hub no longer accepts this enrollment. Nothing is retried; the stored
    /// enrollment stays until the user pairs again or disconnects.
    case revoked
}

/// The hub the app is paired with, as much of the enrollment as may be shown.
public struct PairedHub: Sendable, Equatable {
    public let origin: HubOrigin
    /// The id the hub lists this phone under.
    public let enrollmentID: String
    /// The label the hub stored for this phone.
    public let name: String
    public let pairedAt: Date

    public init(_ enrollment: Enrollment) {
        origin = enrollment.origin
        enrollmentID = enrollment.id
        name = enrollment.name
        pairedAt = enrollment.pairedAt
    }
}

/// One enrollment's way to its hub: the API over it, and how to end it.
public struct HubLink: Sendable {
    public let api: any HubAPI
    /// Ends everything in flight on the connection. Called once the store has stopped.
    public let close: @Sendable () async -> Void

    public init(api: any HubAPI, close: @escaping @Sendable () async -> Void = {}) {
        self.api = api
        self.close = close
    }

    /// The real thing: a pinned `HubClient` for the enrollment and `LiveHubAPI` on top of it.
    /// `credentials` must already hold `enrollment`; a verified new TLS pin is written back to it.
    public static func live(enrollment: Enrollment, credentials: any CredentialStore) -> HubLink {
        let client = HubClient(enrollment: enrollment, store: credentials)
        return HubLink(api: LiveHubAPI(client: client), close: { await client.close() })
    }
}

/// Owns the app's phase: whether it is paired, the connection to the hub it is paired with and
/// the `HubStore` on top of it, and demo mode. It is what main.js does around the dashboard for a
/// desktop in "Connect to a hub" mode: restore the enrollment, pair (`pairWithHub`), show the
/// offline or repair page (`offlineFor`), change setup.
///
/// ```swift
/// let session = SessionController(credentials: KeychainCredentialStore(), preferences: Preferences())
/// session.launch()                      // onboarding, or connecting and then live
/// switch session.phase { … }            // observable
/// await session.pair(invitationText: pasted, name: "My iPhone")
/// ```
///
/// `store` is non-nil in every phase but `.onboarding` (and before `launch()`), and is the same
/// object from pairing to disconnecting, through any outage. Only "Try again" after a revocation
/// replaces it, with an empty one: what the old one held is from before the hub refused this phone.
@MainActor
@Observable
public final class SessionController {
    public typealias Pairing = @Sendable (_ invitation: Invitation, _ name: String) async throws -> Enrollment
    public typealias Connecting = @MainActor (_ enrollment: Enrollment, _ credentials: any CredentialStore) -> HubLink
    public typealias DemoFactory = @MainActor (_ clock: any HubClock) -> DemoHubAPI

    /// How long a lost hub is waited for before the phase becomes `.unreachable`. app/offline.js
    /// works in the same ten seconds, from the other side: its page retries that often.
    public nonisolated static let unreachableAfter: Double = 10_000
    /// The longest `disconnect()` waits for the hub to confirm.
    public nonisolated static let disconnectTimeout: Double = 4_000

    /// What the session keeps in `UserDefaults`. Neither value is a secret.
    public enum Key: String, CaseIterable, Sendable {
        /// Set once the app has started for the first time since it was installed.
        case hasLaunched = "dm.hasLaunched"
        /// The origin of the hub the per-hub preferences belong to.
        case hubOrigin = "dm.hubOrigin"
    }

    // MARK: State

    /// The hub's state: the paired hub's, or the demo's. Nil while onboarding.
    public private(set) var store: HubStore?
    /// The hub the app is paired with. Nil while onboarding and in demo mode.
    public private(set) var hub: PairedHub?
    /// The demo hub while the demo runs, for directing it (`simulateDiskAlert()`, `setAvailability(_:)`).
    public private(set) var demoHub: DemoHubAPI?
    /// True while `pair(invitationText:name:)` is waiting for the hub.
    public private(set) var isPairing = false
    /// Why the last pairing attempt failed, or why the stored enrollment could not be used, in
    /// words for the user. Nil after a success and while an attempt is running.
    public private(set) var pairingError: String?
    /// True while `disconnect()` is telling the hub.
    public private(set) var isDisconnecting = false

    public let preferences: Preferences
    public let clock: any HubClock
    /// Given to every store the session creates, the demo's included.
    @ObservationIgnored public var alertNotifier: (any AlertNotifier)? {
        didSet { store?.alertNotifier = alertNotifier }
    }

    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let pairing: Pairing
    @ObservationIgnored private let connecting: Connecting
    @ObservationIgnored private let demoFactory: DemoFactory

    /// A stretch without the hub, named so that a timer set for one cannot speak for another.
    private enum Outage: Equatable {
        /// Waiting for the first event since the store was (re)started; counted by the session.
        case first(Int)
        /// The stream was lost at `since`.
        case lost(since: Double)
    }

    /// Whether `launch()` has been called.
    private var isLaunched = false
    /// The phase to keep showing while the store is stopped on purpose: in the background, and
    /// while disconnecting.
    private var heldPhase: SessionPhase?
    /// The outage that has lasted `unreachableAfter`.
    private var overdue: Outage?
    private var connectingCount = 0
    /// `store.failedAttempts` when "Try again" was pressed.
    private var retryMark: Int?

    @ObservationIgnored private var link: HubLink?
    @ObservationIgnored private var armed: Outage?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var isForeground = true
    /// False once the Keychain could not be read in this process: what looks like a first
    /// launch may then be a phone that had not been unlocked yet.
    @ObservationIgnored private var mayForget = true
    /// The stored enrollment could not be looked up yet.
    @ObservationIgnored private var needsRestore = false

    /// - Parameters:
    ///   - credentials: where the enrollment is kept (`KeychainCredentialStore` in the app).
    ///   - preferences: handed to every store; what belongs to one hub is forgotten when the hub changes.
    ///   - defaults: holds `Key.hasLaunched` and `Key.hubOrigin`.
    ///   - clock: times the ten seconds, the disconnect timeout, and everything in the stores.
    ///   - pairing: redeems an invitation (`HubPairing.pair`).
    ///   - connecting: opens the way to the hub for an enrollment (`HubLink.live`).
    ///   - demo: makes the hub demo mode runs on.
    ///   - alertNotifier: may also be set later.
    public init(
        credentials: any CredentialStore,
        preferences: Preferences,
        defaults: UserDefaults = .standard,
        clock: any HubClock = SystemHubClock(),
        pairing: @escaping Pairing = { try await HubPairing.pair(invitation: $0, name: $1) },
        connecting: @escaping Connecting = { HubLink.live(enrollment: $0, credentials: $1) },
        demo: @escaping DemoFactory = { DemoHubAPI(clock: $0) },
        alertNotifier: (any AlertNotifier)? = nil
    ) {
        self.credentials = credentials
        self.preferences = preferences
        self.defaults = defaults
        self.clock = clock
        self.pairing = pairing
        self.connecting = connecting
        self.demoFactory = demo
        self.alertNotifier = alertNotifier
    }

    deinit {
        // The store's own tasks end with the store; this one would sleep its ten seconds out.
        deadline?.cancel()
    }

    // MARK: - Phase

    public var phase: SessionPhase {
        guard let store else { return isLaunched ? .onboarding : .connecting }
        if let heldPhase { return heldPhase }
        switch store.connection {
        case .live: return .live
        case .unauthorized: return .revoked
        case .connecting: return overdue == .first(connectingCount) ? unreachable : .connecting
        case .reconnecting(let since):
            // With nothing to show, a failed first attempt is reason enough (main.js loads the
            // offline page on the first failed stream).
            return store.hasSnapshot && overdue != .lost(since: since) ? .live : unreachable
        case .idle: return store.hasSnapshot ? .live : .connecting
        }
    }

    /// True in demo mode: `store` runs on `demoHub`, and nothing is paired or stored.
    public var isDemo: Bool { demoHub != nil }

    /// The origin of the hub in use, the demo's included: "https://hub.example:8443".
    public var hubOriginText: String? { hub?.origin.string ?? demoHub?.configuration.origin }

    /// Why the hub could not be reached last time, in the transport's words ("The hub did not
    /// answer in time."), to go under the `.unreachable` message. Nil when nothing has failed.
    public var unreachableReason: String? { store?.lastErrorText }

    /// True from `retryNow()` until that attempt has failed or succeeded.
    public var isRetrying: Bool {
        guard let store, let retryMark else { return false }
        switch store.connection {
        case .connecting, .reconnecting: return retryMark == store.failedAttempts
        case .idle, .live, .unauthorized: return false
        }
    }

    /// app/offline.js: 'Could not connect to ' + hub + ' and verify its identity. Retrying automatically.'
    private var unreachable: SessionPhase {
        .unreachable(message: "Could not connect to \(hubOriginText ?? "the hub") and verify its identity. Retrying automatically.")
    }

    // MARK: - Launch

    /// Looks up the stored enrollment and connects when there is one. Call once at launch; a
    /// second call does nothing.
    ///
    /// Keychain items outlive the app. On the first launch after an install whatever enrollment
    /// is found is therefore deleted unused, so that a reinstalled app starts at onboarding
    /// instead of quietly using an old credential.
    public func launch() {
        guard !isLaunched else { return }
        isLaunched = true
        restore()
    }

    private func restore() {
        // Absent when the app has never run, and when the phone has not been unlocked since it
        // started: then defaults cannot be read, and neither can the Keychain.
        let firstLaunch = defaults.object(forKey: Key.hasLaunched.rawValue) == nil
        var stored: Enrollment?
        var unreadable = false
        do {
            stored = try credentials.load()
        } catch CredentialStoreError.corrupted {
            unreadable = true
        } catch {
            // The Keychain itself is out of reach: nothing is known, and nothing is deleted on
            // the strength of it. `enterForeground()` looks again; until then the app is as
            // good as unpaired, and says why.
            mayForget = false
            needsRestore = true
            pairingError = Self.message(for: error)
            return
        }
        needsRestore = false

        if firstLaunch, mayForget {
            if stored != nil || unreadable {
                // Left unmarked when the item cannot be deleted, to be tried at the next launch.
                guard (try? credentials.clear()) != nil else { return }
            }
            defaults.set(true, forKey: Key.hasLaunched.rawValue)
            return
        }
        if firstLaunch { defaults.set(true, forKey: Key.hasLaunched.rawValue) }
        if let stored {
            open(stored)
        } else if unreadable {
            // Pairing again writes over the item, so it is left alone until then.
            pairingError = CredentialStoreError.corrupted.errorDescription
        }
    }

    // MARK: - Pairing

    /// Pairs with the hub that issued the invitation, stores the enrollment and connects: the
    /// phase goes from `.onboarding` to `.connecting`. Returns whether that happened. On failure
    /// nothing is stored, the phase stays `.onboarding` and `pairingError` says why, in the
    /// words the desktop app uses (`pairWithHub` in transport.js) or the hub's own.
    ///
    /// - Parameters:
    ///   - invitationText: what was scanned or pasted, `https://hub…/mobile#join=…`.
    ///   - name: the label the hub shows for this phone.
    @discardableResult
    public func pair(invitationText: String, name: String) async -> Bool {
        guard isLaunched, store == nil, !isPairing else { return false }
        if needsRestore {
            // An invitation works once: it is not spent on an enrollment that could not be kept.
            pairingError = nil
            restore()
            guard !needsRestore, store == nil else { return false }
        }
        isPairing = true
        pairingError = nil
        defer { isPairing = false }

        let enrollment: Enrollment
        do {
            enrollment = try await pairing(try Invitation.parse(invitationText), name)
        } catch {
            pairingError = Self.message(for: error)
            return false
        }
        do {
            try credentials.save(enrollment)
        } catch {
            pairingError = Self.message(for: error)
            // The hub now lists a phone that nobody holds the credential of.
            abandon(enrollment)
            return false
        }
        defaults.set(true, forKey: Key.hasLaunched.rawValue)
        if defaults.string(forKey: Key.hubOrigin.rawValue) != enrollment.origin.string {
            // Card ranges and the seen alert belonged to another hub.
            preferences.forgetHub()
            defaults.set(enrollment.origin.string, forKey: Key.hubOrigin.rawValue)
        }
        open(enrollment)
        return true
    }

    /// Any failure of pairing or of the credential store, for the user. Nil when the caller gave up.
    static func message(for error: any Error) -> String? {
        if let error = error as? CredentialStoreError { return error.errorDescription }
        let failure = HubError(error)
        return failure == .cancelled ? nil : failure.errorDescription
    }

    private func abandon(_ enrollment: Enrollment) {
        let link = connecting(enrollment, credentials)
        Task { [clock] in
            await Self.bounded(Self.disconnectTimeout, on: clock) { try? await link.api.unpairSelf() }
            await link.close()
        }
    }

    // MARK: - The paired hub

    private func open(_ enrollment: Enrollment) {
        let link = connecting(enrollment, credentials)
        self.link = link
        hub = PairedHub(enrollment)
        run(on: link.api)
    }

    /// Starts a store that knows nothing yet on `api`, and follows it.
    private func run(on api: any HubAPI) {
        let store = HubStore(api: api, preferences: preferences, clock: clock, alertNotifier: alertNotifier)
        self.store = store
        store.start()
        beginConnecting()
        watch(store)
        // Launched in the background: connect when there is someone to show it to.
        if !isForeground { suspend(store) }
    }

    /// Stops everything and forgets the hub in memory. What is stored is the caller's business.
    private func end() {
        disarm()
        overdue = nil
        retryMark = nil
        heldPhase = nil
        store?.stop()
        store = nil
        hub = nil
        demoHub = nil
        if let link {
            self.link = nil
            Task { await link.close() }
        }
    }

    /// "Try again": connects now instead of at the next automatic attempt. After a revocation it
    /// asks the hub once more, in case the hub was put right: the phase is `.connecting` until
    /// the hub has answered, and `.unreachable` if it cannot be reached. That attempt starts
    /// over with a new `store`.
    public func retryNow() {
        guard let store, !isDisconnecting else { return }
        if store.connection == .unauthorized {
            // What that store holds is from before the hub refused this phone. Restarted, it
            // would count as the last known state, and a hub that cannot be reached would bring
            // the tabs back with it.
            guard let api = link?.api ?? demoHub else { return }
            heldPhase = nil
            overdue = nil
            run(on: api)
            return
        }
        store.retryNow()
        switch store.connection {
        case .connecting, .reconnecting: retryMark = store.failedAttempts
        case .idle, .live, .unauthorized: break
        }
    }

    /// "Pair again": forgets the enrollment, on this device only, and returns to onboarding. For
    /// the `.revoked` phase, where the hub has nothing left to be told. In demo mode this is
    /// `stopDemo()`: a demo hub can be made to refuse the app too, and has no enrollment to forget.
    public func pairAgain() {
        if isDemo {
            stopDemo()
            return
        }
        guard hub != nil, !isDisconnecting else { return }
        end()
        // A pending rotation proof cannot write a pin back: it finds the enrollment gone.
        try? credentials.clear()
    }

    /// "Disconnect": has the hub forget this phone, then forgets the hub, and returns to
    /// onboarding. The hub is given `disconnectTimeout` to answer; unreachable or not, the
    /// enrollment is gone from this device when the call returns. In demo mode this is `stopDemo()`.
    public func disconnect() async {
        if isDemo {
            stopDemo()
            return
        }
        guard let store, let link, !isDisconnecting else { return }
        isDisconnecting = true
        heldPhase = phase
        let refused = store.connection == .unauthorized
        // First, so the hub closing this app's stream is not taken for a lost connection.
        store.stop()
        disarm()
        if !refused {
            await Self.bounded(Self.disconnectTimeout, on: clock) { try? await link.api.unpairSelf() }
        }
        await link.close()
        self.link = nil
        try? credentials.clear()
        defaults.removeObject(forKey: Key.hubOrigin.rawValue)
        preferences.forgetHub()
        end()
        isDisconnecting = false
    }

    // MARK: - Demo mode

    /// Runs the app on a hub that exists only in memory. Only from onboarding; nothing is read
    /// from or written to the credential store.
    public func startDemo() {
        guard isLaunched, store == nil, !isPairing else { return }
        pairingError = nil
        let hub = demoFactory(clock)
        demoHub = hub
        run(on: hub)
    }

    /// Leaves demo mode for onboarding.
    public func stopDemo() {
        guard isDemo else { return }
        end()
        // The demo's card ranges and seen alerts are no real hub's.
        preferences.forgetHub()
    }

    // MARK: - Foreground and background

    /// The app left the foreground: closes the stream. The phase stays what it was.
    public func enterBackground() {
        isForeground = false
        guard let store, store.isRunning, !store.isSuspended, !isDisconnecting else { return }
        heldPhase = phase
        suspend(store)
    }

    /// The app is in front again: reconnects at once. Also looks for the stored enrollment
    /// again if the Keychain could not be read before.
    public func enterForeground() {
        isForeground = true
        if needsRestore, store == nil, !isPairing {
            pairingError = nil
            restore()
        }
        guard let store, !isDisconnecting else { return }
        if store.isSuspended {
            store.resume()
            if store.connection == .connecting { beginConnecting() }
        }
        heldPhase = nil
    }

    private func suspend(_ store: HubStore) {
        store.suspend()
        disarm()
    }

    // MARK: - Ten seconds without the hub

    private func beginConnecting() {
        connectingCount += 1
        arm(.first(connectingCount), at: clock.now + Self.unreachableAfter)
    }

    /// Follows the store's connection for as long as it is this session's store.
    private func watch(_ store: HubStore) {
        withObservationTracking {
            _ = store.connection
        } onChange: { [weak self, weak store] in
            // Called before the change is made; by the time the task runs it has been.
            Task { @MainActor [weak self, weak store] in
                guard let self, let store, self.store === store else { return }
                self.connectionChanged(store)
                self.watch(store)
            }
        }
    }

    private func connectionChanged(_ store: HubStore) {
        switch store.connection {
        case .reconnecting(let since):
            arm(.lost(since: since), at: since + Self.unreachableAfter)
        case .live:
            disarm()
            overdue = nil
            retryMark = nil
        case .idle, .unauthorized:
            disarm()
            retryMark = nil
        case .connecting:
            // Armed where the session asked for the connection.
            break
        }
    }

    private func arm(_ outage: Outage, at time: Double) {
        guard armed != outage else { return }
        disarm()
        armed = outage
        let wait = time - clock.now
        guard wait > 0 else {
            overdue = outage
            return
        }
        deadline = Task { [weak self, clock] in
            do { try await clock.sleep(milliseconds: wait) } catch { return }
            guard let self, self.armed == outage else { return }
            self.overdue = outage
        }
    }

    private func disarm() {
        deadline?.cancel()
        deadline = nil
        armed = nil
    }

    /// Runs `operation` and returns when it has finished or `milliseconds` have passed,
    /// whichever comes first. An operation that outlives its time is cancelled, not waited for.
    private nonisolated static func bounded(_ milliseconds: Double, on clock: any HubClock, _ operation: @escaping @Sendable () async -> Void) async {
        let (first, signal) = AsyncStream<Void>.makeStream()
        let work = Task {
            await operation()
            signal.yield()
        }
        let timer = Task {
            if (try? await clock.sleep(milliseconds: milliseconds)) != nil { signal.yield() }
        }
        for await _ in first { break }
        work.cancel()
        timer.cancel()
    }
}
