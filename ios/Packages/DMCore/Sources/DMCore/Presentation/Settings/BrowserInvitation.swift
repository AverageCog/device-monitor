import Foundation

/// A browser invitation as the app offers it: "Dashboard link" in Settings (copyDashboardLink in
/// main.js) and "View from another device" in the add-device sheet (updateCmd in
/// public/index.html). It is what the dashboard keeps in `#viewUrl`, with the states a browser
/// leaves blank made explicit.
///
/// ```swift
/// guard let request = link.begin(canShare: store.info?.canShare) else { return }   // .unavailable
/// do { link.finish(request, link: try await store.createBrowserInvitation(), now: store.clock.now) }
/// catch { link.fail(request, error) }
/// ```
///
/// The link lets whoever holds it in until it is used or ten minutes have passed: `discard()` it
/// as soon as the screen showing it goes away.
public struct BrowserInvitation: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// Nothing was asked for yet, or the link was put away.
        case idle
        case creating
        /// `expires` is when the app stops showing it (ms since 1970).
        case ready(link: URL, expires: Double)
        /// The ten minutes are over; the link opens nothing any more.
        case expired
        /// The hub refused or could not be asked; the text is its own, or the transport's.
        case failed(String)
        /// The hub says this caller may not create invitations (`canShare` false).
        case unavailable
    }

    /// The fixed wording around a link.
    public enum Labels {
        public static let title = "Dashboard link"
        public static let hint = "Share a single-use browser invitation. It signs in one browser tab for eight hours."
        public static let create = "Create link"
        public static let creating = "Creating an invitation\u{2026}"
        public static let renew = "New link"
        public static let retry = "Try again"
        public static let copy = "Copy"
        public static let copied = "Copied"
        public static let share = "Share"
        /// Under a link that is ready.
        public static let validity = "Single use, valid ten minutes."
        public static let expired = "This invitation has expired."
        // updateCmd: if (!info?.canShare) { … 'Create new invitations in the hub app or its local operator dashboard.' }
        public static let unavailable = "Create new invitations in the hub app or its local operator dashboard."
        // throw new Error(out.error || 'Cannot create invitation')
        public static let failure = "Cannot create invitation"
        public static let qrCode = "QR code of the dashboard link"
        /// What the share sheet calls the link.
        public static let shareSubject = "Device Monitor dashboard"
    }

    // phoneInvite = { known, expires: Date.now() + 590e3 }: ten seconds short of the hub's ten
    // minutes, so a link is never on show after the hub stopped honouring it.
    /// How long a link is shown, in milliseconds.
    public static let lifetime: Double = 590e3

    public private(set) var state: State = .idle
    /// Names the newest request; the answer to an older one is dropped (`invitationRequest`).
    private var request = 0

    public init() {}

    /// The link on show, if there is one. A secret until it is used.
    public var link: URL? {
        if case .ready(let link, _) = state { link } else { nil }
    }

    /// When the link on show stops being shown.
    public var expires: Double? {
        if case .ready(_, let expires) = state { expires } else { nil }
    }

    public var isCreating: Bool { state == .creating }

    /// The sentence that takes the link's place, when there is one to show.
    public var message: String? {
        switch state {
        case .idle, .ready: nil
        case .creating: Labels.creating
        case .expired: Labels.expired
        case .failed(let text): text
        case .unavailable: Labels.unavailable
        }
    }

    /// What the button that asks the hub says, nil while there is nothing to ask for.
    public var actionLabel: String? {
        switch state {
        case .idle: Labels.create
        case .creating, .unavailable: nil
        case .ready, .expired: Labels.renew
        case .failed: Labels.retry
        }
    }

    /// Starts asking for a link and returns the request's number, to hand back with the answer.
    /// Whatever was on show is put away first. Returns nil, and says why, when the hub has said
    /// that this caller may not share.
    ///
    /// - Parameter canShare: `HubInfo.canShare`, nil while the hub has not answered. A paired app
    ///   may always share, so an unknown is asked rather than refused.
    public mutating func begin(canShare: Bool?) -> Int? {
        request += 1
        guard canShare != false else {
            state = .unavailable
            return nil
        }
        state = .creating
        return request
    }

    /// The hub's answer to `request`.
    public mutating func finish(_ request: Int, link: URL, now: Double) {
        guard request == self.request, state == .creating else { return }
        state = .ready(link: link, expires: now + Self.lifetime)
    }

    /// `request` failed. A request the caller gave up says nothing.
    public mutating func fail(_ request: Int, _ error: HubError) {
        guard request == self.request, state == .creating else { return }
        state = error == .cancelled ? .idle : .failed(Self.failureText(error))
    }

    /// Call when `expires` has come: the link goes, and the state says that it lapsed.
    public mutating func expire(now: Double) {
        guard case .ready(_, let expires) = state, now >= expires else { return }
        state = .expired
    }

    /// Forgets the link and whatever was being asked for: the screen is gone.
    public mutating func discard() {
        request += 1
        state = .idle
    }

    /// The hub's own words when it refused, the transport's when it could not be asked.
    public static func failureText(_ error: HubError) -> String {
        error.errorDescription.flatMap { $0.isEmpty ? nil : $0 } ?? Labels.failure
    }
}

// The link is a credential until it is used: none of the model's descriptions carries it.
extension BrowserInvitation.State: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        switch self {
        case .idle: "idle"
        case .creating: "creating"
        case .ready: "ready(link: <redacted>)"
        case .expired: "expired"
        case .failed(let text): "failed(\(text))"
        case .unavailable: "unavailable"
        }
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["state": description]) }
}

extension BrowserInvitation: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "BrowserInvitation(\(state.description))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["state": state.description]) }
}

/// The add-device sheet as a paired phone or tablet sees it (#addDlg and updateCmd in
/// public/index.html with `canEnroll` false and `canShare` true): devices are enrolled on the hub
/// itself, and what this app can hand out is a browser link.
public enum AddDeviceGuide {
    public static let title = "Add a device"
    public static let done = "Done"

    // updateCmd: 'Create device enrollments on the hub. The browser link below is ready to share.'
    /// Where new devices come from.
    public static let enrollOnHub = "Create device enrollments on the hub."

    public static let computersTitle = "Computers"
    /// Before `computerOptions`.
    public static let computersLead = "On the hub, choose + and then one of:"
    /// The dashboard's own tabs for computers (#osTabs).
    public static let computerOptions = ["Windows command", "Desktop app (Windows / Mac)", "Mac / Linux command"]
    // 'Pick how to add the device. Either way it shows up here within seconds and keeps reporting after restarts.'
    public static let computersNote = "Either way it shows up here within seconds and keeps reporting after restarts."

    public static let mobileTitle = "iPhone or iPad"
    /// The dashboard's tab for this app.
    public static let mobileOption = "iPhone / iPad app"
    /// Before `mobileOption`.
    public static let mobileLead = "On the hub, choose + and then:"
    // 'In Device Monitor on your iPhone or iPad, choose Scan invitation and point the camera at this code. Single use, valid ten minutes.'
    public static let mobileSteps = "In Device Monitor on the other iPhone or iPad, choose Scan invitation and point the camera at the code the hub shows. Single use, valid ten minutes."

    public static let viewTitle = "View from another device"
    public static let viewText = "Open this link on any phone, tablet or computer on your network. It is a single-use, ten-minute invitation for one browser tab."
    /// Under the QR code.
    public static let scanHint = "Scan with the other device's camera, or send the link."
    /// With the link, while the app runs on the demo hub: there is no hub behind it.
    public static let demoNote = "Demo mode: this link is simulated and opens nothing."
}
