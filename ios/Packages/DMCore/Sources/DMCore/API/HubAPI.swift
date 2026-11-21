import Foundation

/// A time range the hub knows by name (`RANGES` in server.js). The dashboard offers a different
/// subset in each place; the three lists below are those subsets, in the order it shows them.
public enum HistoryRange: String, Sendable, Hashable, Codable, CaseIterable {
    case tenMinutes = "10m"
    case hour = "1h"
    case sixHours = "6h"
    case day = "24h"
    case week = "7d"
    case month = "30d"

    /// What a device card's chart can show (`RANGE_MS` in public/index.html).
    public static let cardRanges: [HistoryRange] = [.tenMinutes, .hour, .sixHours]
    /// What the history page offers (`HV_RANGES`).
    public static let historyRanges: [HistoryRange] = [.hour, .sixHours, .day, .week, .month]
    /// What the advanced page offers (`adv.range`).
    public static let advancedRanges: [HistoryRange] = [.day, .week, .month]

    public var milliseconds: Double {
        switch self {
        case .tenMinutes: 10 * 60e3
        case .hour: 60 * 60e3
        case .sixHours: 6 * 3600e3
        case .day: 24 * 3600e3
        case .week: 7 * 86400e3
        case .month: 30 * 86400e3
        }
    }

    /// The range in a sentence: `RANGE_LABEL` for a card's menu, `rangeLabel` in renderAdv.
    public var label: String {
        switch self {
        case .tenMinutes: "last 10 min"
        case .hour: "last 60 min"
        case .sixHours: "last 6 hours"
        case .day: "last 24 hours"
        case .week: "last 7 days"
        case .month: "last 30 days"
        }
    }

    /// The text of the dashboard's range buttons (`#hvRange`, `#advRange`). The dashboard has no
    /// button for ten minutes; "10 min" follows the same pattern.
    public var shortLabel: String {
        switch self {
        case .tenMinutes: "10 min"
        case .hour: "1 h"
        case .sixHours: "6 h"
        case .day: "24 h"
        case .week: "7 days"
        case .month: "30 days"
        }
    }
}

/// A desktop app the hub publishes updates for (`UPDATE_PLATFORMS` in server.js). Update events
/// and `/api/update/<platform>` say "mac" where a device's `platform` says "macos".
public enum UpdatePlatform: String, Sendable, Hashable, Codable, CaseIterable {
    case windows
    case mac

    /// `platformKey` in public/index.html: nil for Linux and anything else without a desktop app.
    public init?(devicePlatform: String?) {
        switch devicePlatform {
        case "windows": self = .windows
        case "macos": self = .mac
        default: return nil
        }
    }
}

/// Everything the app asks of a hub, one method per operation, as the role `client` (a paired
/// desktop or phone) may use it.
///
/// Every method throws `HubError` and nothing else:
/// - `.unauthorized` when the hub no longer knows this enrollment (revoked: pair again),
/// - a connectivity error (`isConnectivityFailure`) when the hub cannot be reached or verified,
/// - `.http(status:message:)` when the hub answered and said no, with its own words,
/// - `.invalidResponse` when the answer is not what the operation returns,
/// - `.cancelled` when the calling task was cancelled.
///
/// `LiveHubAPI` talks to a real hub; `DemoHubAPI` is a self-contained stand-in.
public protocol HubAPI: Sendable {
    /// `GET /api/info`.
    func info() async throws -> HubInfo
    /// `GET /api/devices`: every device with its latest report and ten minutes of samples.
    func devices() async throws -> [Device]
    /// `PATCH /api/devices/<id>`. The hub keeps 60 characters without control characters and
    /// ignores a name that is empty after that. Answers with the device as it now stands.
    func rename(device id: String, name: String) async throws -> Device
    /// `DELETE /api/devices/<id>`: forgets the device, its history and its credentials.
    func remove(device id: String) async throws
    /// `PUT /api/order`: every device id in display order.
    func setOrder(ids: [String]) async throws
    /// `GET /api/history/<id>?range=&points=`: the last `range`, in at most about `points` points.
    func history(device id: String, range: HistoryRange, points: Int) async throws -> HistoryResponse
    /// `GET /api/history/<id>?from=&to=&points=`: an explicit window (ms since 1970).
    func history(device id: String, from: Double, to: Double, points: Int) async throws -> HistoryResponse
    /// `GET /api/energy?bounds=`: totals per device over the buckets between `bounds`
    /// (2 to 800 increasing times spanning at most 32 days).
    func energy(bounds: [Double]) async throws -> EnergyResponse
    /// `GET /api/energy/settings`: the saved electricity price, nil until someone saves one.
    func energySettings() async throws -> EnergySettings?
    /// `PUT /api/energy/settings`. Answers with the settings as the hub stored them.
    func saveEnergySettings(_ settings: EnergySettings) async throws -> EnergySettings
    /// `GET /api/alerts`.
    func alerts() async throws -> AlertsResponse
    /// `PUT /api/alerts`. Answers with the settings as stored and what is firing under them.
    func saveAlerts(_ settings: AlertSettings) async throws -> AlertsUpdate
    /// `POST /api/alerts/test`: sends a test alert through every channel that is switched on.
    func testAlert() async throws -> AlertTestResult
    /// `DELETE /api/alerts/log`.
    func clearAlertLog() async throws
    /// `POST /api/devices/<id>/action` with `wake`: the hub sends a Wake-on-LAN signal.
    func wake(device id: String) async throws
    /// A single-use link that opens the dashboard in a browser, valid for ten minutes:
    /// `<hub origin>/unlock#join=<code>`. The link is a secret until it is used.
    func createBrowserInvitation() async throws -> URL
    /// `GET /api/update/<platform>`: the newest published desktop app version, nil when the hub
    /// has none (404).
    func latestVersion(platform: UpdatePlatform) async throws -> String?
    /// `GET /api/remote`.
    func remoteStatus() async throws -> RemoteStatus
    /// `GET /api/mobile`: for a paired phone, only its own entry.
    func mobileClients() async throws -> [MobileClient]
    /// `DELETE /api/mobile/<own id>`: ends this enrollment on the hub ("Disconnect").
    func unpairSelf() async throws
    /// One connection to the live stream (`GET /api/stream`). The first event is a snapshot. The
    /// sequence throws when the connection fails or is refused, and finishes when the hub ends it;
    /// either way the caller reconnects by calling `events()` again. A frame that does not decode
    /// is skipped. Dropping the stream or cancelling the consuming task closes the connection.
    func events() -> AsyncThrowingStream<HubEvent, any Error>
}

extension HubError {
    /// What a failure means to the app, whatever its details.
    public enum Kind: Sendable, Hashable {
        /// The verified hub no longer accepts this enrollment. Pair again.
        case unauthorized
        /// The hub could not be reached or its identity could not be verified. Try again later.
        case unreachable
        /// The hub answered and refused; `errorDescription` is its own explanation.
        case rejected
        /// The caller gave up.
        case cancelled
        /// A request the app should not have made, an answer it cannot read, or a failure on
        /// this device.
        case other
    }

    /// `.unreachable` covers exactly what `isConnectivityFailure` does.
    public var kind: Kind {
        switch self {
        case .unauthorized: .unauthorized
        case .unreachable, .untrustedCertificate, .pinMismatch, .identityProofFailed, .redirectRefused: .unreachable
        case .http: .rejected
        case .cancelled: .cancelled
        case .invalidOrigin, .invalidInvitation, .invalidRequest, .responseTooLarge, .invalidResponse, .notDeviceMonitorHub,
             .invalidEnrollmentResponse, .storage: .other
        }
    }

    /// Any error out of a `HubAPI` as a `HubError`, so callers have one type to switch over.
    public init(_ error: any Error) {
        if let known = error as? HubError {
            self = known
        } else if error is CancellationError {
            self = .cancelled
        } else if error is DecodingError {
            self = .invalidResponse
        } else if error is EncodingError {
            self = .invalidRequest
        } else if (error as NSError).domain == NSURLErrorDomain {
            self = .transport(error)
        } else {
            self = .unreachable("The hub could not be reached.")
        }
    }
}
