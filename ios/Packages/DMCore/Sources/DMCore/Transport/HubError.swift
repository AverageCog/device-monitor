import Foundation

/// Every way pairing with, or talking to, a hub can fail. Messages are written for the user and
/// never contain a credential, an invitation code or a proof secret.
public enum HubError: Error, Equatable, Sendable {
    /// The text is not a bare HTTPS origin.
    case invalidOrigin
    /// The text is not an invitation for this app.
    case invalidInvitation(Invitation.Problem)
    /// The request was refused before any network use: not a single-slash path on the enrolled
    /// origin, or a body the hub would not accept.
    case invalidRequest
    /// The hub could not be reached, or the connection failed or timed out. Nothing is known about
    /// whether a request that was already sent took effect, so it is never replayed.
    case unreachable(String)
    /// Standard certificate validation (trusted chain, validity, hostname) failed.
    case untrustedCertificate(String)
    /// The certificate is valid for the hub's name but its key is not the enrolled one. No HTTP
    /// bytes were sent. `HubClient` answers this itself with the rotation proof.
    case pinMismatch(peerPin: String)
    /// A server with a valid certificate for the hub's name could not prove it is the enrolled hub.
    case identityProofFailed
    /// The hub answered with a redirect, which is never followed.
    case redirectRefused
    /// The response exceeded the size allowed for that endpoint.
    case responseTooLarge
    /// A successful response that is not the JSON the caller asked for.
    case invalidResponse
    /// A non-2xx answer, with the hub's own `{ error }` text when it sent one. This includes a 403
    /// to an API call: the hub refusing one operation to a credential it otherwise accepts.
    case http(status: Int, message: String)
    /// The verified hub no longer accepts this enrollment: 401 to any request, or 401/403 to the
    /// live stream. This is the signal for the repair screen ("pair again").
    case unauthorized(status: Int, message: String)
    /// The address answered, but not as a Device Monitor hub.
    case notDeviceMonitorHub
    /// The hub's answer to the invitation is not a usable enrollment.
    case invalidEnrollmentResponse
    /// The credential store failed, so a verified new TLS pin could not be kept.
    case storage(String)
    /// The calling task was cancelled or the client was closed.
    case cancelled
}

extension HubError {
    /// The HTTP status of `.http` and `.unauthorized`.
    public var httpStatus: Int? {
        switch self {
        case .http(let status, _), .unauthorized(let status, _): status
        default: nil
        }
    }

    public var isUnauthorized: Bool {
        if case .unauthorized = self { true } else { false }
    }

    /// The hub could not be reached or verified right now; trying again later may work.
    /// Mirrors what sends the desktop app to its "Retrying automatically" page.
    public var isConnectivityFailure: Bool {
        switch self {
        case .unreachable, .untrustedCertificate, .pinMismatch, .identityProofFailed, .redirectRefused: true
        default: false
        }
    }
}

extension HubError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidOrigin: "Enter the hub's HTTPS address."
        case .invalidInvitation(.malformed): "Scan or paste the complete invitation shown on the hub."
        case .invalidInvitation(.desktopInvitation):
            "This invitation is for a computer. On the hub, choose + → iPhone / iPad app and use that invitation instead."
        case .invalidInvitation(.browserLink):
            "This link opens the dashboard in a browser. On the hub, choose + → iPhone / iPad app and use that invitation instead."
        case .invalidRequest: "Invalid hub destination."
        case .unreachable(let reason): reason
        case .untrustedCertificate(let reason): "The hub's certificate could not be verified. " + reason
        case .pinMismatch: "Hub TLS identity changed."
        case .identityProofFailed: "Hub identity proof failed."
        case .redirectRefused: "Hub redirect refused."
        case .responseTooLarge: "The hub's response was too large."
        case .invalidResponse: "The hub sent an unexpected response."
        case .http(_, let message), .unauthorized(_, let message): message
        case .notDeviceMonitorHub: "The address is not a verified Device Monitor hub."
        case .invalidEnrollmentResponse: "Invalid enrollment response."
        case .storage(let reason): "The hub's new identity could not be saved. " + reason
        case .cancelled: "The request was cancelled."
        }
    }
}

extension HubError {
    /// A fixed, secret-free sentence for a URL loading failure. Foundation's own descriptions are
    /// not used: they can quote the URL and vary with the system language in ways tests cannot pin.
    static func transport(_ error: any Error) -> HubError {
        let code = (error as NSError).domain == NSURLErrorDomain ? (error as NSError).code : 0
        // iOS reports a hub on the LAN as "offline" when the user has not allowed local network
        // access; the path it attaches to the error says so.
        if code == NSURLErrorNotConnectedToInternet,
           let path = (error as NSError).userInfo["_NSURLErrorNWPathKey"],
           String(describing: path).localizedCaseInsensitiveContains("local network prohibited") {
            return .unreachable(Reason.localNetworkDenied)
        }
        return switch code {
        case NSURLErrorCancelled: .cancelled
        case NSURLErrorTimedOut: .unreachable(Reason.timedOut)
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: .unreachable("The hub's address could not be found.")
        case NSURLErrorCannotConnectToHost: .unreachable("Could not connect to the hub.")
        case NSURLErrorNetworkConnectionLost: .unreachable("The connection to the hub was lost.")
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
            .unreachable("This device is offline.")
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired:
            .unreachable("A secure connection to the hub could not be established.")
        case NSURLErrorAppTransportSecurityRequiresSecureConnection: .unreachable("The hub must be reached over HTTPS.")
        case 0: .unreachable("The hub could not be reached.")
        default: .unreachable("The hub could not be reached (network error \(code)).")
        }
    }

    enum Reason {
        static let timedOut = "The hub did not answer in time."
        static let unverified = "The hub's TLS identity was not verified."
        static let localNetworkDenied = "Device Monitor is not allowed to use the local network. Allow it in Settings → Privacy & Security → Local Network."
    }

    /// Who received a non-2xx answer, which decides whether it means "this enrollment is refused".
    enum Refused {
        /// Pairing: there is no enrollment yet, so nothing is ever `.unauthorized`.
        case pairing
        /// An API call: 401 is the hub not knowing the credential. A 403 here is the hub refusing
        /// that one operation to a credential it accepts ("Create this invitation on the hub."),
        /// so it stays an ordinary `.http` error, as it is for the web dashboard.
        case request
        /// The live stream: 401 and 403 both send the desktop app to its repair page
        /// (`dashboardProtocol()` in `main.js`).
        case stream
    }

    /// The error for a non-2xx answer, as `hubJson()` in `transport.js` words it: the hub's own
    /// `{ error }` string cut to 240 UTF-16 units, else `HTTP <status>`.
    static func status(_ status: Int, body: Data, to receiver: Refused) -> HubError {
        var message = "HTTP \(status)"
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let text = object["error"] as? String {
            var cleaned = String.UnicodeScalarView()
            cleaned.append(contentsOf: text.unicodeScalars.filter { $0.value > 0x1F && $0.value != 0x7F })
            var cut = String(cleaned)
            while cut.utf16.count > 240 { cut.unicodeScalars.removeLast() }
            if !cut.isEmpty { message = cut }
        }
        let unauthorized = switch receiver {
        case .pairing: false
        case .request: status == 401
        case .stream: status == 401 || status == 403
        }
        return unauthorized ? .unauthorized(status: status, message: message) : .http(status: status, message: message)
    }
}
