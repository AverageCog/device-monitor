import Foundation

/// Redeems a mobile invitation. Port of `pairWithHub()` in `transport.js`, speaking the mobile
/// enrollment protocol (`POST /api/mobile/pair`).
public enum HubPairing {
    /// Pairs with the hub that issued `invitation` and returns the enrollment, which the caller
    /// stores (`CredentialStore.save`) before creating a `HubClient`.
    ///
    /// 1. Probe `GET /api/info` with standard certificate validation and remember the key that
    ///    answered. Nothing secret is sent.
    /// 2. Redeem the code on a connection that must present that same key.
    ///
    /// `name` is the label the hub shows for this phone (at most 60 characters are kept).
    /// Throws `HubError`: `.notDeviceMonitorHub`, `.http` carrying the hub's own words (for
    /// example "Invitation is invalid, expired or already used."), `.invalidEnrollmentResponse`,
    /// or a connectivity error.
    public static func pair(invitation: Invitation, name: String) async throws -> Enrollment {
        try await pair(invitation: invitation, name: name, redeemPath: redeemPath, secondSecret: secondSecret) { PinnedSession(policy: $0) }
    }

    static let redeemPath = "/api/mobile/pair"
    /// The answer's field that holds the second secret.
    static let secondSecret = "proof"

    /// The same exchange against any redeem endpoint that answers `{ id, client, <secondSecret> }`.
    /// The desktop endpoint (`/api/pair`, `agent`) has that shape and derives the proof key the
    /// same way, which lets tests run against a hub without the mobile routes.
    static func pair(
        invitation: Invitation, name: String, redeemPath: String, secondSecret: String, now: Date = Date(),
        connect: @Sendable (PinnedSession.Policy) -> any PinnedTransport
    ) async throws -> Enrollment {
        let origin = invitation.origin
        let probe = connect(.capture)
        defer { probe.invalidate() }
        let info = try await probe.data(
            for: try HubClient.makeRequest(origin: origin, method: "GET", path: "/api/info", query: [], bearer: nil, body: nil),
            timeout: HubClient.defaultTimeout, maxResponseBytes: HubClient.smallResponseLimit)
        let described = try? JSONSerialization.jsonObject(with: info.data) as? [String: Any]
        guard (200..<300).contains(info.response.statusCode) else {
            // A hub explains itself in JSON; anything else at this address is not one.
            guard described?["error"] is String else { throw HubError.notDeviceMonitorHub }
            throw HubError.status(info.response.statusCode, body: info.data, to: .pairing)
        }
        guard described?["app"] as? String == "device-monitor", let pin = info.peerPin, SPKIPin.isValid(pin) else {
            throw HubError.notDeviceMonitorHub
        }

        let label = Enrollment.cleanName(name)
        guard let body = try? HubJSON.encode(Wire.MobilePair(name: label.isEmpty ? nil : label)) else { throw HubError.invalidRequest }
        let pinned = connect(.require(pin: pin))
        defer { pinned.invalidate() }
        let reply = try await pinned.data(
            for: try HubClient.makeRequest(origin: origin, method: "POST", path: redeemPath, query: [], bearer: invitation.code, body: body),
            timeout: HubClient.defaultTimeout, maxResponseBytes: HubClient.smallResponseLimit)
        guard (200..<300).contains(reply.response.statusCode) else {
            throw HubError.status(reply.response.statusCode, body: reply.data, to: .pairing)
        }
        guard let member = try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any],
              let id = member["id"] as? String, let client = member["client"] as? String, let proof = member[secondSecret] as? String else {
            throw HubError.invalidEnrollmentResponse
        }
        let stored = (member["name"] as? String).map(Enrollment.cleanName) ?? ""
        do {
            return try Enrollment(origin: origin, id: id, client: client, proof: proof, pin: pin, name: stored.isEmpty ? label : stored, pairedAt: now)
        } catch {
            throw HubError.invalidEnrollmentResponse
        }
    }
}
