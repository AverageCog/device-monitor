import XCTest

/// The app against a real hub: `server.js` behind real TLS, started by `ios/Tools/e2e.sh` through
/// build/test/mobile-hub.js. The script trusts the fixture's CA in the simulator and hands the
/// test runner two environment variables:
///
///     DM_E2E_INVITATION   a fresh invitation, https://localhost:<port>/mobile#join=<code>
///     DM_E2E_CONTROL      the fixture's control endpoint, http://127.0.0.1:<port>
///
/// Without them (a plain `xcodebuild test`) the test is skipped.
final class HubFlowUITests: XCTestCase {
    /// What build/test/mobile-hub.js registers, in its order; nas stops reporting, htpc never does.
    static let devices = ["gaming", "spark", "mbp", "server", "studio", "nas", "htpc"]
    static let phoneName = "E2E iPhone"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPairRelaunchRotateRevokeAndDisconnect() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let invitation = environment["DM_E2E_INVITATION"], !invitation.isEmpty,
              let control = environment["DM_E2E_CONTROL"].flatMap(ControlPort.init) else {
            throw XCTSkip("Needs a fixture hub: run ios/Tools/e2e.sh")
        }
        let origin = try XCTUnwrap(invitation.components(separatedBy: "/mobile#").first)
        XCTAssertEqual(try phones(control).count, 0, "The fixture hub starts with no phone paired")

        // 1. A fresh install pairs from the invitation text.
        let app = XCUIApplication()
        app.launchArguments = ["-dm-reset", "-dm-name", Self.phoneName]
        app.launch()
        XCTAssertTrue(app.element(withIdentifier: ID.onboarding).waitForExistence(timeout: 30), "After a reset the app is not paired")
        attachScreenshot(of: app, named: "hub-1-onboarding")
        pair(app, with: invitation)

        // 2. Live: the fixture's devices, and readings that keep changing.
        let first = try live(app, origin: origin, "paired")
        // The NAS stops reporting soon after the hub starts, and the living-room PC never does.
        XCTAssertTrue((5...6).contains(first.online), "online: \(first.online)")
        for id in Self.devices {
            XCTAssertTrue(app.deviceRow(id).waitForExistence(timeout: 10), "\(id) is listed")
        }
        XCTAssertEqual(app.deviceRow("gaming").label, "Gaming PC")
        XCTAssertEqual(app.deviceRow("htpc").value as? String, "offline")
        XCTAssertEqual(try phones(control).map { $0["name"] as? String }, [Self.phoneName], "The hub lists this phone under the name it gave")
        waitForSession(of: app, "reports keep arriving") { $0.readings != first.readings && $0.heartbeat > first.heartbeat }
        attachScreenshot(of: app, named: "hub-2-live")

        // 3. Relaunch: still paired (the enrollment is in the Keychain), and live again.
        app.terminate()
        app.launchArguments = []
        app.launch()
        try live(app, origin: origin, "relaunched")
        XCTAssertFalse(app.element(withIdentifier: ID.onboarding).exists)
        XCTAssertEqual(try phones(control).count, 1, "Nothing was paired a second time")
        attachScreenshot(of: app, named: "hub-3-relaunched")

        // 4. The hub's TLS key changes, twice (to RSA and back to EC). The hub closes every
        //    connection; the app proves the new key belongs to its hub and carries on by itself.
        for round in 1...2 {
            let pin = try XCTUnwrap(try control.json("GET", "/state")["pin"] as? String)
            let rotated = try control.json("POST", "/rotate-tls")
            // The simulator runs on this Mac's clock. Half a second on, nothing the app shows can
            // have come over a connection from before the rotation.
            let rotatedAt = Int64(Date().timeIntervalSince1970 * 1000) + 500
            XCTAssertEqual(rotated["previous"] as? String, pin)
            XCTAssertNotEqual(rotated["pin"] as? String, pin, "The hub serves a new key")
            let recovered = waitForSession(of: app, "the stream is back after rotation \(round) (\(rotated["key"] ?? "?"))", timeout: 40) {
                $0.phase == "live" && $0.connection == "live" && $0.heartbeat > rotatedAt
            }
            XCTAssertEqual(recovered?.devices, 7)
            XCTAssertFalse(app.element(withIdentifier: ID.unreachable).exists, "The app never gave the hub up")
            XCTAssertFalse(app.element(withIdentifier: ID.revoked).exists)
        }
        attachScreenshot(of: app, named: "hub-4-rotated")
        // The pin that was proved is the one that was kept: a relaunch connects without ado.
        app.terminate()
        app.launch()
        try live(app, origin: origin, "relaunched after the rotations")
        XCTAssertEqual(try phones(control).count, 1)

        // 5. The hub's operator removes this phone: the app says so, and keeps saying so.
        XCTAssertEqual(try control.json("POST", "/revoke-mobile")["revoked"] as? Int, 1)
        XCTAssertTrue(app.element(withIdentifier: ID.revoked).waitForExistence(timeout: 30), "A revoked phone lands on the revoked screen")
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        attachScreenshot(of: app, named: "hub-5-revoked")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.element(withIdentifier: ID.revoked).waitForExistence(timeout: 30), "The enrollment is kept, and the hub still refuses it")

        // 6. Pair again with a fresh invitation, then disconnect: the hub forgets the phone.
        app.buttons[ID.revokedPairAgain].tap()
        XCTAssertTrue(app.element(withIdentifier: ID.onboarding).waitForExistence(timeout: 10), "Pair again returns to onboarding")
        pair(app, with: try control.text("GET", "/invite"))
        try live(app, origin: origin, "paired again")
        XCTAssertEqual(try phones(control).count, 1)

        app.tabBars.buttons["Settings"].tap()
        let disconnect = app.buttons[ID.disconnectButton]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 5))
        XCTAssertEqual(disconnect.label, "Disconnect")
        attachScreenshot(of: app, named: "hub-6-settings")
        disconnect.tap()
        XCTAssertTrue(app.element(withIdentifier: ID.onboarding).waitForExistence(timeout: 15), "Disconnect returns to onboarding")
        XCTAssertEqual(try phones(control).count, 0, "The hub was told")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.element(withIdentifier: ID.onboarding).waitForExistence(timeout: 30), "Nothing is left in the Keychain")
    }

    /// Types the invitation and connects.
    @MainActor
    private func pair(_ app: XCUIApplication, with invitation: String) {
        let field = app.element(withIdentifier: ID.invitationField)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(invitation)
        let connect = app.buttons[ID.connectButton]
        XCTAssertTrue(connect.isEnabled)
        connect.tap()
        if app.element(withIdentifier: ID.pairError).waitForExistence(timeout: 1) {
            XCTFail("Pairing failed: \(app.element(withIdentifier: ID.pairError).label)")
        }
    }

    /// Waits for the app to be live on the fixture hub with all its devices.
    @MainActor
    @discardableResult
    private func live(_ app: XCUIApplication, origin: String, _ when: String, file: StaticString = #filePath, line: UInt = #line) throws -> SessionState {
        let state = try XCTUnwrap(
            waitForSession(of: app, "the app is live (\(when))", timeout: 45, file: file, line: line) {
                $0.phase == "live" && $0.connection == "live" && $0.devices == Self.devices.count && $0.heartbeat > 0
            }, file: file, line: line)
        XCTAssertFalse(state.isDemo, file: file, line: line)
        XCTAssertEqual(state.hub, origin, file: file, line: line)
        XCTAssertTrue(app.deviceRow("gaming").waitForExistence(timeout: 10), "The device list is on screen (\(when))", file: file, line: line)
        return state
    }

    private func phones(_ control: ControlPort) throws -> [[String: Any]] {
        try XCTUnwrap(try control.json("GET", "/state")["phones"] as? [[String: Any]])
    }
}
