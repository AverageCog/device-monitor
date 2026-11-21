import UIKit

/// What the first-run and system-state screens say, in one place.
///
/// Sentences that also exist on the desktop are the desktop's (app/setup.html, app/setup.js,
/// app/offline.html, app/offline.js, main.js), changed only where a phone is not a PC. Everything
/// that reports a failure is not here: those come from the session controller and the transport
/// (`SessionController.pairingError`, `.unreachableReason`, the `.unreachable` phase's message,
/// `HubError.errorDescription`).
enum OnboardingCopy {
    static let productName = "Device Monitor"
    static let tagline = "See every computer on your hub live: CPU, GPU, memory, temperatures, power and alerts."

    /// "iPhone" or "iPad", for sentences about this device.
    static var deviceKind: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    // MARK: Pairing (app/setup.html "Connect to a hub")

    static let connectTitle = "Connect to your hub"
    /// The hub's own name for the place the invitation is shown (public/index.html `#osTabs`).
    static let invitationMenu = "+ → iPhone / iPad app"
    static let invitationMenuSpoken = "the plus button, then iPhone / iPad app"
    static let hostStepLead = "On the computer that hosts Device Monitor, open"
    static let scanStep = "Scan the invitation it shows, or copy it and paste it here."
    /// public/index.html `#cmdHint` and the hint beside the QR code say the same of the hub's side.
    static let requirements = "The hub needs HTTPS enabled, for example Tailscale HTTPS. An invitation works once, for ten minutes."

    /// The wording the hub's dashboard, its /mobile page and the README send people to.
    static let scan = "Scan invitation"
    static let noCamera = "This device has no camera. Paste the invitation instead."
    static let or = "or"
    /// setup.html: placeholder "Paste the HTTPS desktop invitation", aria-label "Desktop invitation".
    static let invitationPrompt = "Paste the invitation"
    static let invitationLabel = "Invitation"
    static let clearInvitation = "Clear the invitation"
    static let nameLabel = "Name of this device"
    static let nameHint = "The hub lists it under “Paired phones and tablets”."
    static let connect = "Connect"
    /// setup.js: the busy text of "Connect".
    static let verifying = "Verifying the hub…"
    static let demoLead = "No hub yet?"
    static let demo = "Try the demo"

    static func invitationHub(_ origin: String) -> String { "Invitation for \(origin)" }

    // MARK: Scanner

    static let scannerInstruction = "Point the camera at the code shown on the hub."
    static let scannerPreparing = "Starting the camera…"
    static let scannerViewfinder = "Camera viewfinder"
    static let torch = "Torch"
    static let close = "Close"
    static let pasteInstead = "Paste instead"
    static let openSettings = "Open Settings"
    static let tryAgain = "Try again"

    static let cameraDeniedTitle = "Camera access is off"
    static let cameraDeniedMessage = "Device Monitor uses the camera only to scan the invitation shown on your hub. Allow the camera in Settings, or paste the invitation instead."
    static let cameraRestrictedTitle = "The camera is restricted"
    static let cameraRestrictedMessage = "Screen Time or a management profile does not allow this device to use the camera. Paste the invitation instead."
    static let cameraMissingTitle = "No camera"
    static let cameraFailedTitle = "The camera could not start"
    static let cameraFailedMessage = "Try again, or paste the invitation instead."
    static let cameraInterrupted = "The camera is in use elsewhere. Scanning continues when it is free again."

    // MARK: Connecting

    static let connecting = "Connecting to hub…"
    static let startingDemo = "Starting the demo…"
    /// The second sentence is app/offline.html's.
    static let connectingSlow = "Still waiting for the hub to answer. The PC hosting the dashboard may be off or asleep."

    // MARK: Unreachable (app/offline.html)

    static let unreachableTitle = "Can't reach the hub"
    static let unreachableFallback = "The PC hosting the dashboard may be off or asleep."
    static let retrying = "Trying…"
    static let stillTrying = "Trying to reach the hub…"
    static let changeSetup = "Change setup"
    static let unreachableHint = "Certificate renewals reconnect automatically. If you replaced the hub or revoked this device, use a fresh invitation."
    /// main.js: 'Disconnect this computer and change setup?'
    static var changeSetupQuestion: String { "Disconnect this \(deviceKind) and change setup?" }
    static let changeSetupConsequence = "Pairing again needs a fresh invitation from the hub."
    static let forgetHub = "Forget hub"
    static let disconnecting = "Disconnecting…"
    static let cancel = "Cancel"

    // MARK: Revoked (app/offline.js, the "repair" case)

    static let revokedTitle = "Pairing no longer valid"
    /// offline.js, first sentence. The desktop continues "Choose Change setup and paste a fresh
    /// desktop invitation."; here the steps below say how.
    static let revokedMessage = "The verified hub no longer accepts this enrollment."
    static let freshInvitationTitle = "Get a fresh invitation"
    static let pairAgainStep = "Choose Pair again, then scan or paste the invitation it shows."
    static let pairAgain = "Pair again"
    static var revokedHint: String { "Pair again only forgets the old pairing on this \(deviceKind)." }

    // MARK: Demo

    static let demoTag = "Demo"
    static let exitDemo = "Exit demo"
    static let demoRevokedMessage = "The demo hub was told to refuse this app, which is what a real hub does after this device is removed from it."
    static let demoRevokedHint = "Nothing was paired. Exit the demo to connect to your own hub."
}
