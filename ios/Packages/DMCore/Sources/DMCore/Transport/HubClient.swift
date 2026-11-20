import CryptoKit
import Foundation

/// The authenticated connection to the enrolled hub. Port of `desktopTrust()` and `hubRequest()`
/// in `transport.js`, with the limits `dashboardProtocol()` in `main.js` applies.
///
/// Every request goes to the enrolled origin, over a connection whose certificate passed standard
/// validation and carries the enrolled key, with the client credential as a bearer. One client
/// owns the enrollment's pin and at most one rotation proof at a time; create a single instance
/// per enrollment and `close()` it before replacing or removing the enrollment.
public actor HubClient {
    /// Whole-request deadline for API calls (`AbortSignal.timeout(15000)` in `main.js`).
    public static let defaultTimeout: TimeInterval = 15
    /// Deadline of the rotation proof.
    public static let proofTimeout: TimeInterval = 8
    public static let defaultResponseLimit = 32 * 1024 * 1024
    /// Limit for `/api/info`, `/api/update/*`, pairing and the proof.
    public static let smallResponseLimit = 64 * 1024
    /// The hub refuses larger request bodies (`readBody`).
    static let requestBodyLimit = 1_000_000

    public nonisolated let origin: HubOrigin
    /// The id the hub knows this enrollment by.
    public nonisolated let enrollmentID: String
    /// The enrollment with the pin currently trusted; it changes when a rotation is verified.
    public private(set) var enrollment: Enrollment

    private let store: any CredentialStore
    private let connect: @Sendable (PinnedSession.Policy) -> any PinnedTransport
    private var transport: any PinnedTransport
    private let key: SymmetricKey
    private var pendingProof: Task<Void, any Error>?
    private var closed = false

    /// `store` must already hold `enrollment`: a verified new pin is only ever written over the
    /// enrollment it belongs to.
    public init(enrollment: Enrollment, store: any CredentialStore) {
        self.init(enrollment: enrollment, store: store) { PinnedSession(policy: $0) }
    }

    init(enrollment: Enrollment, store: any CredentialStore, connect: @escaping @Sendable (PinnedSession.Policy) -> any PinnedTransport) {
        self.origin = enrollment.origin
        self.enrollmentID = enrollment.id
        self.enrollment = enrollment
        self.store = store
        self.connect = connect
        self.transport = connect(.require(pin: enrollment.pin))
        self.key = HubIdentity.proofKey(client: enrollment.client, proof: enrollment.proof)
    }

    // MARK: Requests

    /// Sends one request and returns the body of a 2xx answer.
    ///
    /// - `path` must start with a single `/`; the query is passed separately and encoded here.
    /// - `body` is JSON and is sent with `Content-Type: application/json`.
    /// - `timeout` bounds the whole exchange. `maxResponseBytes` defaults to 32 MiB, or 64 KiB for
    ///   `/api/info` and `/api/update/*`.
    ///
    /// Throws `HubError`: `.unauthorized` for 401 (the hub no longer knows this enrollment),
    /// `.http` for any other non-2xx status, `.unreachable` and friends when the hub cannot be
    /// reached or verified. A request is sent at most once, except that a refused TLS handshake
    /// (key rotation) is followed by the identity proof and one retry.
    public func request(
        method: String = "GET", path: String, query: [URLQueryItem] = [], body: Data? = nil,
        timeout: TimeInterval = HubClient.defaultTimeout, maxResponseBytes: Int? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let request = try Self.makeRequest(origin: origin, method: method, path: path, query: query, bearer: enrollment.client, body: body)
        let reply = try await send(request, timeout: timeout, limit: maxResponseBytes ?? Self.responseLimit(for: path))
        guard (200..<300).contains(reply.response.statusCode) else {
            throw HubError.status(reply.response.statusCode, body: reply.data, to: .request)
        }
        return (reply.data, reply.response)
    }

    /// `request` followed by JSON decoding; a body that does not decode throws `.invalidResponse`.
    public nonisolated func json<T: Decodable & Sendable>(
        _ type: T.Type = T.self, method: String = "GET", path: String, query: [URLQueryItem] = [], body: Data? = nil,
        timeout: TimeInterval = HubClient.defaultTimeout, maxResponseBytes: Int? = nil
    ) async throws -> T {
        let (data, _) = try await request(method: method, path: path, query: query, body: body, timeout: timeout, maxResponseBytes: maxResponseBytes)
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw HubError.invalidResponse }
        return value
    }

    /// `json` with an `Encodable` request body.
    public nonisolated func json<T: Decodable & Sendable, Body: Encodable & Sendable>(
        _ type: T.Type = T.self, method: String, path: String, query: [URLQueryItem] = [], encoding body: Body,
        timeout: TimeInterval = HubClient.defaultTimeout, maxResponseBytes: Int? = nil
    ) async throws -> T {
        guard let encoded = try? JSONEncoder().encode(body) else { throw HubError.invalidRequest }
        return try await json(type, method: method, path: path, query: query, body: encoded, timeout: timeout, maxResponseBytes: maxResponseBytes)
    }

    /// One connection to the hub's live stream: the payload of each `data:` frame, in order.
    /// See `EventStream`.
    public nonisolated func events() -> AsyncThrowingStream<Data, any Error> {
        EventStream(client: self).frames()
    }

    /// Cancels everything in flight, including open streams and a pending proof. Requests made
    /// afterwards throw `HubError.cancelled`.
    public func close() {
        guard !closed else { return }
        closed = true
        pendingProof?.cancel()
        transport.invalidate()
    }

    /// `encodeURIComponent`, for a device id or other value placed in a path.
    public static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved.union(CharacterSet(charactersIn: "!*'()"))) ?? ""
    }

    // MARK: TLS key rotation

    private func send(_ request: URLRequest, timeout: TimeInterval, limit: Int) async throws -> PinnedSession.Response {
        guard !closed else { throw HubError.cancelled }
        let started = ContinuousClock.now
        let pin = enrollment.pin
        do {
            return try await transport.data(for: request, timeout: timeout, maxResponseBytes: limit)
        } catch HubError.pinMismatch(let peerPin) {
            // The handshake was refused before any HTTP bytes were sent, so this is the one
            // failure after which sending again cannot repeat an operation.
            try await refresh(previous: pin, candidate: peerPin)
            guard !closed, !Task.isCancelled else { throw HubError.cancelled }
            let elapsed = (ContinuousClock.now - started).components
            let remaining = timeout - Double(elapsed.seconds) - Double(elapsed.attoseconds) / 1e18
            guard remaining > 0 else { throw HubError.unreachable(HubError.Reason.timedOut) }
            return try await transport.data(for: request, timeout: remaining, maxResponseBytes: limit)
        }
    }

    /// `trust.refresh()`: everyone who saw the same stale pin waits for one proof.
    func refresh(previous: String, candidate: String) async throws {
        guard !closed else { throw HubError.cancelled }
        guard enrollment.pin == previous else { return }
        let proof = pendingProof ?? Task { try await self.verify(candidate) }
        pendingProof = proof
        try await proof.value
    }

    /// Asks the server on the candidate key to prove it holds this enrollment's verifiers. Neither
    /// the bearer nor either digest is sent: only MACs under a key derived from both secrets.
    private func verify(_ candidate: String) async throws {
        defer { pendingProof = nil }
        guard SPKIPin.isValid(candidate) else { throw HubError.identityProofFailed }
        let nonce = HubIdentity.randomSecret()
        let challenge = ProofRequest(
            lookup: HubIdentity.mac(key, "lookup"), nonce: nonce,
            challenge: HubIdentity.mac(key, "desktop", origin.string, nonce))
        guard let body = try? JSONEncoder().encode(challenge) else { throw HubError.identityProofFailed }
        let request = try Self.makeRequest(origin: origin, method: "POST", path: "/api/desktop/tls-proof", query: [], bearer: nil, body: body)
        let candidateTransport = connect(.require(pin: candidate))
        var adopted = false
        defer { if !adopted { candidateTransport.invalidate() } }

        let reply: PinnedSession.Response
        do {
            reply = try await candidateTransport.data(for: request, timeout: Self.proofTimeout, maxResponseBytes: Self.smallResponseLimit)
        } catch HubError.pinMismatch {
            // The key changed again under us; the next request starts over with what it sees.
            throw HubError.identityProofFailed
        }
        let expected = HubIdentity.mac(key, "hub", origin.string, nonce, candidate)
        guard (200..<300).contains(reply.response.statusCode),
              let answer = try? JSONDecoder().decode(ProofResponse.self, from: reply.data),
              HubIdentity.constantTimeEquals(answer.proof, expected) else { throw HubError.identityProofFailed }
        guard !closed, !Task.isCancelled else { throw HubError.cancelled }

        let updated: Enrollment
        do {
            // Never write this pin over a different enrollment that was saved in the meantime.
            guard let stored = try store.load(), stored.origin == enrollment.origin, stored.id == enrollment.id,
                  stored.client == enrollment.client else { throw HubError.storage("This enrollment is no longer the saved one.") }
            updated = try enrollment.withPin(candidate)
            try store.save(updated)
        } catch let error as HubError {
            throw error
        } catch let error as CredentialStoreError {
            throw HubError.storage(error.errorDescription ?? "")
        } catch {
            throw HubError.storage("The credential store failed.")
        }
        enrollment = updated
        let previous = transport
        transport = candidateTransport
        adopted = true
        // Requests still running on connections to the old key are not disturbed.
        previous.retire()
    }

    private struct ProofRequest: Encodable {
        let lookup: String
        let nonce: String
        let challenge: String
    }

    private struct ProofResponse: Decodable {
        let proof: String
    }

    // MARK: Live stream plumbing (EventStream)

    func openStream(idleTimeout: TimeInterval) throws -> (pin: String, stream: PinnedSession.ByteStream) {
        guard !closed else { throw HubError.cancelled }
        let request = try Self.makeRequest(origin: origin, method: "GET", path: EventStream.path, query: [], bearer: enrollment.client, body: nil)
        return (enrollment.pin, transport.bytes(for: request, idleTimeout: idleTimeout))
    }

    // MARK: Request construction

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private static let methods: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"]

    /// The only way a request for a hub is built: an absolute single-slash path on `origin`
    /// (`requestOnce()` refuses anything else as "Invalid hub destination").
    static func makeRequest(origin: HubOrigin, method: String, path: String, query: [URLQueryItem], bearer: String?, body: Data?) throws -> URLRequest {
        guard methods.contains(method), isValidPath(path), (body?.count ?? 0) <= requestBodyLimit,
              bearer.map(HubIdentity.isValidSecret) ?? true,
              let url = origin.url(path: path, query: query.isEmpty ? nil : encode(query)) else { throw HubError.invalidRequest }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    /// `/^\/(?!\/)/` plus what a path may be made of: no backslash, query, fragment, space or
    /// anything a URL parser would rewrite into a different destination.
    static func isValidPath(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        guard (1...2048).contains(bytes.count), bytes[0] == UInt8(ascii: "/"), bytes.count == 1 || bytes[1] != UInt8(ascii: "/") else { return false }
        return bytes.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"): true
            default: "/-._~%!$&'()*+,;=:@".utf8.contains(byte)
            }
        }
    }

    static func encode(_ query: [URLQueryItem]) -> String {
        // A comma stays readable (`bounds=1,2,3`); everything else outside the unreserved set is
        // escaped, including "+", which the hub's parser would otherwise read as a space.
        let allowed = unreserved.union(CharacterSet(charactersIn: ","))
        return query.map { item in
            let name = item.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            guard let value = item.value else { return name }
            return name + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
    }

    /// `/^\/api\/(info|update\/)/` gets 64 KiB, everything else 32 MiB (`dashboardProtocol()`).
    static func responseLimit(for path: String) -> Int {
        path.hasPrefix("/api/info") || path.hasPrefix("/api/update/") ? smallResponseLimit : defaultResponseLimit
    }
}
