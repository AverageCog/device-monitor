import DMCore
import Observation
import SwiftUI

/// The browser link one screen is offering: asks the hub through the store, keeps the answer for
/// as long as the hub honours it, and puts it away when the screen says so. The add-device sheet
/// and the "Dashboard link" row of Settings each own one.
///
/// The link signs a browser in. It lives in this object and nowhere else: `discard()` when the
/// screen that shows it disappears or the app leaves the foreground.
@Observable
final class AddDeviceInvitationModel {
    private(set) var invitation = BrowserInvitation()
    /// The link as a QR code, when the screen wants one.
    private(set) var qrCode: AddDeviceQRCode?

    @ObservationIgnored private let makesQRCode: Bool
    @ObservationIgnored private let script: SettingsLaunch.LinkScript?
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var expiry: Task<Void, Never>?

    /// - Parameters:
    ///   - makesQRCode: whether `qrCode` is filled in with each link.
    ///   - script: DEBUG builds only, a stand-in for the hub's answer (see `SettingsLaunch`).
    init(makesQRCode: Bool = false, script: SettingsLaunch.LinkScript? = nil) {
        self.makesQRCode = makesQRCode
        self.script = script
    }

    /// Whether a DEBUG launch argument wants a link asked for as soon as the screen is up.
    var asksAtOnce: Bool { script?.asksAtOnce ?? false }

    /// Asks the hub for a fresh link; the one on show, if any, is put away first.
    func create(from store: HubStore) {
        cancel()
        qrCode = nil
        let canShare = script?.refusesSharing == true ? false : store.info?.canShare
        guard let number = invitation.begin(canShare: canShare) else { return }
        request = Task {
            let link: URL
            do {
                link = try await answer(from: store)
            } catch {
                invitation.fail(number, HubError(error))
                return
            }
            invitation.finish(number, link: link, now: store.clock.now)
            // An answer nobody is waiting for any more was dropped by the model.
            guard invitation.link == link else { return }
            if makesQRCode { qrCode = AddDeviceQRCode(text: link.absoluteString) }
            watchExpiry(on: store.clock)
        }
    }

    /// Forgets the link and whatever was being asked for.
    func discard() {
        cancel()
        qrCode = nil
        invitation.discard()
    }

    private func cancel() {
        request?.cancel()
        request = nil
        expiry?.cancel()
        expiry = nil
    }

    private func answer(from store: HubStore) async throws(HubError) -> URL {
        switch script?.answer {
        case .failure(let error): throw error
        case .silence:
            // Until the screen goes away and cancels the request.
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)) }
            throw HubError.cancelled
        case nil: return try await store.createBrowserInvitation()
        }
    }

    private func watchExpiry(on clock: any HubClock) {
        guard let expires = invitation.expires else { return }
        if script?.expiresAtOnce == true {
            lapse(at: expires)
            return
        }
        expiry = Task {
            do { try await clock.sleep(milliseconds: max(0, expires - clock.now)) } catch { return }
            lapse(at: max(expires, clock.now))
        }
    }

    private func lapse(at time: Double) {
        invitation.expire(now: time)
        if invitation.link == nil { qrCode = nil }
    }
}
