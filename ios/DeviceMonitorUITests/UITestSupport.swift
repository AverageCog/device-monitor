import Darwin
import XCTest

/// The accessibility identifiers the flow tests lean on. A screen that is rebuilt keeps these, or
/// changes them here.
enum ID {
    static let onboarding = "onboarding-screen"
    static let invitationField = "pair-invitation-field"
    static let nameField = "pair-name-field"
    static let connectButton = "pair-connect-button"
    static let pairError = "pair-error"
    static let demoButton = "pair-demo-button"
    static let connecting = "phase-connecting"
    static let unreachable = "phase-unreachable"
    static let unreachableRetry = "unreachable-retry-button"
    static let unreachableChange = "unreachable-change-button"
    static let revoked = "phase-revoked"
    static let revokedPairAgain = "revoked-pair-again-button"
    static let reconnectingBanner = "reconnecting-banner"
    static let addDeviceButton = "add-device-button"
    static let disconnectButton = "settings-disconnect-button"
    /// DEBUG builds only: see SessionProbe in the app.
    static let sessionProbe = "debug-session"
    /// DEBUG builds only: the menu that directs a demo hub, in DebugTools. A pop-up button.
    static let debugHubMenu = "debug-hub-menu"

    static func deviceRow(_ id: String) -> String { "device-row-\(id)" }
}

/// What the app's DEBUG probe says about its session.
struct SessionState: Equatable, CustomStringConvertible {
    var phase = ""
    var isDemo = false
    var connection = ""
    var devices = 0
    var online = 0
    /// Milliseconds since 1970 of the last status event the app received, 0 before the first.
    var heartbeat: Int64 = 0
    /// Moves with every report the app receives.
    var readings = 0
    var hub = ""

    init?(_ text: String) {
        var fields: [String: String] = [:]
        for pair in text.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        guard let phase = fields["phase"] else { return nil }
        self.phase = phase
        isDemo = fields["demo"] == "1"
        connection = fields["connection"] ?? ""
        devices = Int(fields["devices"] ?? "") ?? 0
        online = Int(fields["online"] ?? "") ?? 0
        heartbeat = Int64(fields["heartbeat"] ?? "") ?? 0
        readings = Int(fields["readings"] ?? "") ?? 0
        hub = fields["hub"] ?? ""
    }

    var description: String {
        "phase=\(phase) demo=\(isDemo) connection=\(connection) devices=\(devices) online=\(online) heartbeat=\(heartbeat) readings=\(readings) hub=\(hub)"
    }
}

extension XCUIApplication {
    /// Any element with this accessibility identifier, whatever its type.
    @MainActor
    func element(withIdentifier identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The session as the app's DEBUG probe reports it; nil while the app is not up.
    @MainActor
    var sessionState: SessionState? {
        let probe = element(withIdentifier: ID.sessionProbe)
        return probe.exists ? SessionState(probe.label) : nil
    }

    @MainActor
    func deviceRow(_ id: String) -> XCUIElement {
        element(withIdentifier: ID.deviceRow(id))
    }

    /// Any element with exactly this label, whatever its type. For what the system draws, a
    /// menu's items for one, where the type is the system's choice and not the same on every iOS.
    @MainActor
    func element(labelled label: String) -> XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Swipes `container` up until `element` can be tapped: on screen, and clear of the tab bar,
    /// which floats over the end of every list. False when `swipes` were not enough.
    @MainActor
    func scrollUp(_ container: XCUIElement, until element: XCUIElement, swipes: Int = 5) -> Bool {
        func isClear() -> Bool {
            guard element.exists, element.isHittable else { return false }
            let bar = tabBars.firstMatch
            return !bar.exists || element.frame.maxY <= bar.frame.minY
        }
        for _ in 0..<swipes {
            if isClear() { return true }
            container.swipeUp()
        }
        return isClear()
    }
}

extension XCTestCase {
    @MainActor
    func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Polls until `condition` holds; false when `timeout` passes first.
    @MainActor
    @discardableResult
    func wait(upTo timeout: TimeInterval, every interval: TimeInterval = 0.4, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if condition() { return true }
            if Date() >= deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
        }
    }

    /// Waits until the app's session satisfies `condition` and returns it, failing the test otherwise.
    @MainActor
    @discardableResult
    func waitForSession(
        of app: XCUIApplication, _ what: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line,
        where condition: (SessionState) -> Bool
    ) -> SessionState? {
        var last: SessionState?
        let reached = wait(upTo: timeout) {
            last = app.sessionState
            return last.map(condition) ?? false
        }
        XCTAssertTrue(reached, "Timed out waiting until \(what). Last seen: \(last?.description ?? "no session probe")", file: file, line: line)
        return reached ? last : nil
    }
}

/// The fixture hub's control endpoint (build/test/mobile-hub.js), spoken to over a plain socket:
/// the test runner is an app like any other, and App Transport Security would refuse it plain
/// HTTP through URLSession.
struct ControlPort {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let host: String
    let port: UInt16

    /// `http://127.0.0.1:8571`
    init?(_ url: String) {
        guard let components = URLComponents(string: url), components.scheme == "http", let host = components.host, let port = components.port,
              let narrow = UInt16(exactly: port) else { return nil }
        self.host = host
        self.port = narrow
    }

    /// The JSON object the endpoint answers with.
    func json(_ method: String, _ path: String) throws -> [String: Any] {
        let body = try request(method, path)
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw Failure(description: "\(method) \(path): not a JSON object")
        }
        return object
    }

    func text(_ method: String, _ path: String) throws -> String {
        String(decoding: try request(method, path), as: UTF8.self)
    }

    /// One request; the body of a 200 answer.
    func request(_ method: String, _ path: String) throws -> Data {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure(description: "socket: \(errno)") }
        defer { close(descriptor) }

        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host == "localhost" ? "127.0.0.1" : host, &address.sin_addr) == 1 else {
            throw Failure(description: "\(host) is not an IPv4 address")
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw Failure(description: "connect to \(host):\(port): \(errno)") }

        // HTTP/1.0, so the answer is not chunked and ends when the hub closes the connection.
        let head = Array("\(method) \(path) HTTP/1.0\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 0\r\n\r\n".utf8)
        var sent = 0
        while sent < head.count {
            let count = head[sent...].withUnsafeBytes { send(descriptor, $0.baseAddress, $0.count, 0) }
            guard count > 0 else { throw Failure(description: "send: \(errno)") }
            sent += count
        }

        var answer = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            guard count >= 0 else { throw Failure(description: "recv: \(errno)") }
            if count == 0 { break }
            answer.append(contentsOf: buffer[0..<count])
        }
        guard let separator = answer.range(of: Data("\r\n\r\n".utf8)) else { throw Failure(description: "\(method) \(path): no answer") }
        let status = String(decoding: answer[..<separator.lowerBound], as: UTF8.self).split(separator: " ").dropFirst().first.flatMap { Int($0) }
        let body = answer[separator.upperBound...]
        guard status == 200 else {
            throw Failure(description: "\(method) \(path): HTTP \(status.map(String.init) ?? "?") \(String(decoding: body, as: UTF8.self))")
        }
        return Data(body)
    }
}
