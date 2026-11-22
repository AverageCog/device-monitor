import AVFoundation
import DMCore
import Observation
import SwiftUI

/// The invitation scanner's state: camera permission, the camera itself, and what to make of
/// each code it sees. Only a code that parses as an invitation for this app ends the scan; for
/// any other the transport's own explanation is shown and scanning goes on.
@Observable
final class OnboardingScannerModel {
    enum Status: Equatable {
        /// Asking for the camera, or starting it.
        case preparing
        case scanning
        /// Another app, or the system, has the camera for now.
        case interrupted
        /// An invitation was read; the sheet is closing.
        case accepted
        /// The user said no to the camera. Settings is where that is changed.
        case denied
        /// The device's owner does not allow the camera at all.
        case restricted
        /// No camera (the Simulator).
        case unavailable
        case failed
    }

    private(set) var status: Status = .preparing
    /// Why the code in view is not accepted, in the transport's words. Nil when none is in view.
    private(set) var rejection: String?
    private(set) var isTorchAvailable = false
    private(set) var isTorchOn = false
    /// Made on the first `start()`, so that a model nobody shows costs nothing.
    private(set) var camera: OnboardingScannerCamera?

    /// Called once, with the text of an invitation for this app. A secret: it is handed on, and
    /// kept nowhere here.
    @ObservationIgnored var onInvitation: (String) -> Void = { _ in }

    /// False once the sheet has closed or the app has left the foreground.
    @ObservationIgnored private var isWanted = false
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var rejectionSeen = ContinuousClock.now
    @ObservationIgnored private var rejectionExpiry: Task<Void, Never>?
    #if DEBUG
    /// `-dm-onboarding-scanner`: the state to show without a camera.
    @ObservationIgnored private var simulated: String?
    #endif

    /// How long an explanation stays after its code has left the picture.
    private static let rejectionLinger: Duration = .seconds(3)

    init() {}

    #if DEBUG
    /// A scanner that never touches the camera and shows `state` (see `OnboardingDebugOptions`).
    init(simulating state: String) {
        simulated = state
        status = switch state {
        case "preparing": .preparing
        case "interrupted": .interrupted
        case "denied": .denied
        case "restricted": .restricted
        case "unavailable": .unavailable
        case "failed": .failed
        default: .scanning
        }
        isTorchAvailable = status == .scanning
    }
    #endif

    // MARK: - Camera

    /// Asks for the camera if that has not been decided yet, and starts scanning. Safe to call
    /// again: when the app returns to the foreground, or after a failure.
    func start() async {
        isWanted = true
        #if DEBUG
        if let simulated {
            await simulate(simulated)
            return
        }
        #endif
        guard !isStarting, status != .scanning, status != .accepted else { return }
        isStarting = true
        defer { isStarting = false }

        // First, because asking for a camera that does not exist would still put up the prompt.
        guard OnboardingScannerCamera.deviceHasCamera else {
            status = .unavailable
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            // The system's prompt, with the reason from NSCameraUsageDescription.
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                status = .denied
                return
            }
        case .restricted:
            status = .restricted
            return
        case .denied:
            status = .denied
            return
        @unknown default:
            status = .denied
            return
        }
        guard isWanted else { return }

        let camera = camera ?? OnboardingScannerCamera { [weak self] codes in
            for code in codes { self?.scanned(code) }
        }
        self.camera = camera
        status = .preparing
        switch await camera.start() {
        case .running(let hasTorch):
            status = .scanning
            isTorchAvailable = hasTorch
        case .unavailable:
            status = .unavailable
        case .failed:
            status = .failed
        }
        // Closed, or sent to the background, while the camera was starting.
        if !isWanted { stop() }
    }

    /// Stops the camera and the torch. The sheet closing and the app leaving the foreground both
    /// end here.
    func stop() {
        isWanted = false
        camera?.stop()
        isTorchOn = false
        rejectionExpiry?.cancel()
        rejectionExpiry = nil
        rejection = nil
        if status == .scanning || status == .interrupted { status = .preparing }
    }

    func toggleTorch() {
        guard let camera, status == .scanning, isTorchAvailable else { return }
        let wanted = !isTorchOn
        Task { isTorchOn = await camera.setTorch(wanted) }
    }

    /// The system took the camera away (a call, another app in Split View).
    func interrupted() {
        guard status == .scanning else { return }
        status = .interrupted
        isTorchOn = false
    }

    func interruptionEnded() {
        guard status == .interrupted else { return }
        status = .scanning
    }

    /// The session stopped with an error.
    func runtimeFailure() {
        guard status == .scanning || status == .interrupted || status == .preparing else { return }
        camera?.stop()
        isTorchOn = false
        status = .failed
    }

    // MARK: - Codes

    private func scanned(_ text: String) {
        guard status == .scanning else { return }
        do {
            _ = try Invitation.parse(text)
        } catch {
            // "This invitation is for a computer…", "This link opens the dashboard in a browser…",
            // or, for anything else, "Scan or paste the complete invitation shown on the hub."
            reject(HubError(error).errorDescription)
            return
        }
        camera?.stop()
        isTorchOn = false
        rejectionExpiry?.cancel()
        rejectionExpiry = nil
        rejection = nil
        status = .accepted
        OnboardingHaptics.success()
        onInvitation(text)
    }

    private func reject(_ message: String?) {
        guard let message, !message.isEmpty else { return }
        rejectionSeen = .now
        if rejection != message {
            rejection = message
            OnboardingHaptics.warning()
            AccessibilityNotification.Announcement(message).post()
        }
        #if DEBUG
        // A simulated code never leaves the picture.
        if simulated != nil { return }
        #endif
        guard rejectionExpiry == nil else { return }
        // The camera reports a code many times a second while it is in view; the explanation
        // stays that long and a little longer.
        rejectionExpiry = Task { [weak self] in
            while let self, !Task.isCancelled {
                let remaining = Self.rejectionLinger - (ContinuousClock.now - self.rejectionSeen)
                if remaining <= .zero {
                    self.rejection = nil
                    self.rejectionExpiry = nil
                    return
                }
                try? await Task.sleep(for: remaining)
            }
        }
    }

    // MARK: - Simulation

    #if DEBUG
    /// Feeds a simulated scanner the code its state is about, through the same door the camera uses.
    private func simulate(_ state: String) async {
        let code = String(repeating: "a", count: 43)
        switch state {
        case "desktop": scanned("https://hub.demo.example/pair#join=\(code)")
        case "browser": scanned("https://hub.demo.example/unlock#join=\(code)")
        case "other": scanned("https://example.com/")
        case "accept":
            // Once the sheet is up, so that its closing can be seen.
            try? await Task.sleep(for: .milliseconds(900))
            scanned("https://hub.demo.example\(DMCoreInfo.invitationPath)#join=\(code)")
        default: break
        }
    }
    #endif
}
