import Foundation

/// `HubAPI` against a real hub, over the enrollment's pinned connection. The requests are the
/// ones public/index.html makes with `hubFetch`; the comments name the function each is from.
public struct LiveHubAPI: HubAPI {
    public let client: HubClient

    public init(client: HubClient) {
        self.client = client
    }

    /// The hub tries ntfy and then the webhook, and gives each ten seconds (`post` in alerts.js).
    static let testAlertTimeout: TimeInterval = 30

    public func info() async throws -> HubInfo {
        try decode(try await call(path: "/api/info"))
    }

    public func devices() async throws -> [Device] {
        try list(try await call(path: "/api/devices"))
    }

    // openMenu: rename
    public func rename(device id: String, name: String) async throws -> Device {
        try decode(try await call("PATCH", path: Self.devicePath(id), body: try Self.encode(Wire.Rename(name: name))))
    }

    // openMenu: remove
    public func remove(device id: String) async throws {
        _ = try await call("DELETE", path: Self.devicePath(id))
    }

    // startDrag, at the end of a drag
    public func setOrder(ids: [String]) async throws {
        _ = try await call("PUT", path: "/api/order", body: try Self.encode(Wire.Order(ids: ids)))
    }

    // loadSeries
    public func history(device id: String, range: HistoryRange, points: Int) async throws -> HistoryResponse {
        let query = [URLQueryItem(name: "range", value: range.rawValue), URLQueryItem(name: "points", value: String(points))]
        return try decode(try await call(path: Self.historyPath(id), query: query))
    }

    // loadHistory: `?from=${Math.round(hv.from)}&to=${Math.round(hv.to)}&points=${w}`
    public func history(device id: String, from: Double, to: Double, points: Int) async throws -> HistoryResponse {
        let query = [
            URLQueryItem(name: "from", value: JS.string(JS.round(from))), URLQueryItem(name: "to", value: JS.string(JS.round(to))),
            URLQueryItem(name: "points", value: String(points)),
        ]
        return try decode(try await call(path: Self.historyPath(id), query: query))
    }

    // loadAdv: '/api/energy?bounds=' + advBounds().join(',')
    public func energy(bounds: [Double]) async throws -> EnergyResponse {
        let query = [URLQueryItem(name: "bounds", value: bounds.map(JS.string).joined(separator: ","))]
        return try decode(try await call(path: "/api/energy", query: query))
    }

    public func energySettings() async throws -> EnergySettings? {
        // A hub without a saved price answers the bare word null.
        try decode(try await call(path: "/api/energy/settings"), as: EnergySettings?.self)
    }

    // saveEnergySettings
    public func saveEnergySettings(_ settings: EnergySettings) async throws -> EnergySettings {
        try decode(try await call("PUT", path: "/api/energy/settings", body: try Self.encode(settings)))
    }

    public func alerts() async throws -> AlertsResponse {
        try decode(try await call(path: "/api/alerts"))
    }

    public func saveAlerts(_ settings: AlertSettings) async throws -> AlertsUpdate {
        try decode(try await call("PUT", path: "/api/alerts", body: try Self.encode(settings)))
    }

    public func testAlert() async throws -> AlertTestResult {
        try decode(try await call("POST", path: "/api/alerts/test", timeout: Self.testAlertTimeout))
    }

    public func clearAlertLog() async throws {
        _ = try await call("DELETE", path: "/api/alerts/log")
    }

    // The offline list's Wake button.
    public func wake(device id: String) async throws {
        _ = try await call("POST", path: Self.devicePath(id) + "/action", body: try Self.encode(Wire.DeviceAction.wake))
    }

    // updateCmd's issue('browser') and copyDashboardLink in main.js: the link is for the origin
    // this app is enrolled at, and a code of any other shape is not put into a link.
    public func createBrowserInvitation() async throws -> URL {
        let origin = client.origin.string
        let answer = try await call("POST", path: "/api/invites", body: try Self.encode(Wire.Invite(kind: .browser, origin: origin)))
        let invite: InviteResponse = try decode(answer)
        guard HubIdentity.isValidSecret(invite.code), let link = URL(string: origin + "/unlock#join=" + invite.code) else {
            throw HubError.invalidResponse
        }
        return link
    }

    // loadLatestVersions: `if (r.ok) latestVersions[p] = (await r.json()).version`
    public func latestVersion(platform: UpdatePlatform) async throws -> String? {
        do {
            let manifest: UpdateManifest = try decode(try await call(path: "/api/update/" + platform.rawValue))
            return manifest.version
        } catch HubError.http(status: 404, _) {
            return nil
        }
    }

    public func remoteStatus() async throws -> RemoteStatus {
        try decode(try await call(path: "/api/remote"))
    }

    public func mobileClients() async throws -> [MobileClient] {
        try list(try await call(path: "/api/mobile"))
    }

    public func unpairSelf() async throws {
        _ = try await call("DELETE", path: "/api/mobile/" + HubClient.pathComponent(client.enrollmentID))
    }

    public func events() -> AsyncThrowingStream<HubEvent, any Error> {
        // Pull-based, like the frames underneath: an event is decoded when the consumer asks for
        // it, so a consumer that falls behind is still stopped by the transport's backlog limit.
        let source = EventSource(frames: client.events())
        return AsyncThrowingStream(unfolding: { try await source.next() })
    }

    // MARK: Requests

    /// `'/api/devices/' + encodeURIComponent(id)`
    static func devicePath(_ id: String) -> String {
        "/api/devices/" + HubClient.pathComponent(id)
    }

    /// `'/api/history/' + encodeURIComponent(id)`
    static func historyPath(_ id: String) -> String {
        "/api/history/" + HubClient.pathComponent(id)
    }

    private func call(
        _ method: String = "GET", path: String, query: [URLQueryItem] = [], body: Data? = nil,
        timeout: TimeInterval = HubClient.defaultTimeout
    ) async throws -> Data {
        do {
            return try await client.request(method: method, path: path, query: query, body: body, timeout: timeout).0
        } catch {
            throw HubError(error)
        }
    }

    private static func encode<Body: Encodable>(_ body: Body) throws -> Data {
        guard let data = try? HubJSON.encode(body) else { throw HubError.invalidRequest }
        return data
    }

    private func decode<T: Decodable>(_ data: Data, as type: T.Type = T.self) throws -> T {
        guard let value = try? HubJSON.decode(T.self, from: data) else { throw HubError.invalidResponse }
        return value
    }

    /// A top-level array, minus the elements this app cannot read.
    private func list<T: Decodable>(_ data: Data) throws -> [T] {
        guard let values = try? HubJSON.decodeList(T.self, from: data) else { throw HubError.invalidResponse }
        return values
    }
}

/// Turns stream frames into events for the one task that iterates them.
private final class EventSource: @unchecked Sendable {
    // Only ever touched by the single consumer of the stream that owns this object, one call at
    // a time, which is the contract of an `AsyncThrowingStream` iterator.
    private var iterator: AsyncThrowingStream<Data, any Error>.Iterator

    init(frames: AsyncThrowingStream<Data, any Error>) {
        iterator = frames.makeAsyncIterator()
    }

    func next() async throws -> HubEvent? {
        var frames = iterator
        defer { iterator = frames }
        do {
            while let frame = try await frames.next() {
                // connect() would throw on a frame it cannot parse; a newer hub may say things
                // this app does not understand, and one such frame must not cost the connection.
                if let event = try? HubEvent.decode(frame) { return event }
            }
            return nil
        } catch {
            throw HubError(error)
        }
    }
}
