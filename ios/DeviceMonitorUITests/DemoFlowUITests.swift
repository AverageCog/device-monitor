import XCTest

/// The app end to end without a hub: demo mode, and every phase against a demo hub that is made
/// to behave that way (`-dm-phase`). These always run. The same flows against a real hub are in
/// HubFlowUITests.
final class DemoFlowUITests: XCTestCase {
    /// The demo's devices; the last one is offline.
    static let devices = ["gaming", "spark", "mbp", "server", "studio", "htpc"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDemoShowsDevicesThatKeepChanging() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-demo"]
        app.launch()

        // A card for every device that is online.
        let online = Self.devices.dropLast()
        for id in online {
            XCTAssertTrue(app.deviceRow(id).waitForExistence(timeout: 20), "The demo's \(id) has a card")
        }
        let state = try XCTUnwrap(waitForSession(of: app, "the demo is live") { $0.phase == "live" && $0.devices == 6 })
        XCTAssertTrue(state.isDemo)
        XCTAssertEqual(state.online, 5)
        XCTAssertEqual(state.hub, "https://hub.demo.example")
        XCTAssertTrue(app.element(withIdentifier: "demo-banner").exists, "The demo says that it is one")
        attachScreenshot(of: app, named: "demo-devices")

        // The offline one has no card: it is in the list that the summary opens.
        let offline = app.deviceRow("htpc")
        XCTAssertFalse(offline.exists, "An offline device has no card")
        app.element(withIdentifier: "devices-summary").tap()
        XCTAssertTrue(offline.waitForExistence(timeout: 10), "The demo's htpc is in the offline list")
        XCTAssertTrue((offline.value as? String ?? "").hasPrefix("offline"), "got: \(String(describing: offline.value))")
        // The list's Done button on a phone; on an iPad it is a popover, which a tap beside it closes.
        let done = app.element(withIdentifier: "offline-list-done-button")
        if done.waitForExistence(timeout: 2) { done.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.9)).tap() }
        XCTAssertTrue(wait(upTo: 10) { !offline.exists }, "The offline list closes")

        // Reports keep arriving: a reading on screen changes, and so does the hub's heartbeat.
        let first = Dictionary(uniqueKeysWithValues: online.map { ($0, app.deviceRow($0).value as? String ?? "") })
        XCTAssertTrue(first.values.allSatisfy { $0.hasPrefix("online, CPU ") && $0.hasSuffix("%") }, "Rows show a CPU load: \(first)")
        let changed = wait(upTo: 30) { online.contains { app.deviceRow($0).value as? String != first[$0] } }
        XCTAssertTrue(changed, "No row changed in 30 s; first values: \(first)")
        let later = try XCTUnwrap(waitForSession(of: app, "a later heartbeat") { $0.heartbeat > state.heartbeat && $0.readings != state.readings })
        XCTAssertEqual(later.phase, "live")
        attachScreenshot(of: app, named: "demo-devices-later")

        // The Alerts tab counts what is firing: the server's disk and the living-room PC.
        let alerts = app.tabBars.buttons["Alerts"]
        XCTAssertTrue(wait(upTo: 10) { (alerts.value as? String)?.contains("2") == true }, "Alerts badge: \(String(describing: alerts.value))")
    }

    @MainActor
    func testTheDemoStartsFromOnboardingAndEndsThere() {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-memory-credentials"]
        app.launch()

        let demo = app.buttons[ID.demoButton]
        XCTAssertTrue(demo.waitForExistence(timeout: 20))
        attachScreenshot(of: app, named: "onboarding")
        demo.tap()
        XCTAssertTrue(app.deviceRow("gaming").waitForExistence(timeout: 20), "Try the demo goes to the device list")
        XCTAssertFalse(app.element(withIdentifier: ID.onboarding).exists)

        app.tabBars.buttons["Settings"].tap()
        let leave = app.buttons[ID.disconnectButton]
        XCTAssertTrue(leave.waitForExistence(timeout: 5))
        XCTAssertEqual(leave.label, "Exit demo")
        attachScreenshot(of: app, named: "demo-settings")
        leave.tap()
        XCTAssertTrue(app.element(withIdentifier: ID.onboarding).waitForExistence(timeout: 10), "Leaving the demo returns to onboarding")
        XCTAssertFalse(app.tabBars.firstMatch.exists)
    }

    @MainActor
    func testAnInvitationThatIsNotOneIsExplainedInline() {
        let app = XCUIApplication()
        // A link that opens the dashboard in a browser, pre-filled: nothing is asked of any hub.
        app.launchArguments = ["-dm-memory-credentials", "-dm-invitation", "https://hub.example/unlock#join=" + String(repeating: "a", count: 43)]
        app.launch()

        let connect = app.buttons[ID.connectButton]
        XCTAssertTrue(connect.waitForExistence(timeout: 20))
        XCTAssertTrue(connect.isEnabled, "-dm-invitation pre-fills the field")
        XCTAssertFalse(app.element(withIdentifier: ID.pairError).exists)
        connect.tap()
        let error = app.element(withIdentifier: ID.pairError)
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertEqual(error.label, "This link opens the dashboard in a browser. On the hub, choose + → iPhone / iPad app and use that invitation instead.")
        XCTAssertTrue(app.element(withIdentifier: ID.onboarding).exists, "A refused invitation leaves the app in onboarding")
        attachScreenshot(of: app, named: "onboarding-error")
    }

    @MainActor
    func testEveryPhaseHasItsScreen() {
        for (phase, identifier) in [("onboarding", ID.onboarding), ("connecting", ID.connecting), ("unreachable", ID.unreachable), ("revoked", ID.revoked)] {
            let app = XCUIApplication()
            app.launchArguments = ["-dm-phase", phase]
            app.launch()
            XCTAssertTrue(app.element(withIdentifier: identifier).waitForExistence(timeout: 20), "-dm-phase \(phase) shows \(identifier)")
            XCTAssertEqual(app.sessionState?.phase, phase)
            XCTAssertFalse(app.tabBars.firstMatch.exists, "No tabs in the \(phase) phase")
            attachScreenshot(of: app, named: "phase-\(phase)")
            app.terminate()
        }

        let app = XCUIApplication()
        app.launchArguments = ["-dm-phase", "live"]
        app.launch()
        XCTAssertTrue(app.deviceRow("gaming").waitForExistence(timeout: 20), "-dm-phase live shows the tabs")
        XCTAssertEqual(app.sessionState?.isDemo, false, "A -dm-phase session looks paired, not like the demo")
        attachScreenshot(of: app, named: "phase-live")
    }

    @MainActor
    func testTheFailureScreensOfferAWayOut() {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-phase", "unreachable"]
        app.launch()

        XCTAssertTrue(app.buttons[ID.unreachableRetry].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Could not connect to https://hub.demo.example and verify its identity. Retrying automatically."].exists)
        app.buttons[ID.unreachableChange].tap()
        let forget = app.buttons["Forget hub"]
        XCTAssertTrue(forget.waitForExistence(timeout: 5), "Change setup asks first")
        forget.tap()
        XCTAssertTrue(app.element(withIdentifier: ID.onboarding).waitForExistence(timeout: 10), "Change setup returns to onboarding")
        app.terminate()

        app.launchArguments = ["-dm-phase", "revoked"]
        app.launch()
        let again = app.buttons[ID.revokedPairAgain]
        XCTAssertTrue(again.waitForExistence(timeout: 20))
        again.tap()
        XCTAssertTrue(app.element(withIdentifier: ID.onboarding).waitForExistence(timeout: 10), "Pair again returns to onboarding")
    }

    /// The hub goes away for twenty seconds: first the banner over what was last known, after ten
    /// seconds the unreachable screen, and then the tabs again, where the user left them.
    @MainActor
    func testAHubThatGoesAwayAndComesBack() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-demo", "-dm-tab", "advanced"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Advanced"].waitForExistence(timeout: 20))
        waitForSession(of: app, "the demo is live") { $0.phase == "live" && $0.devices == 6 }

        directDemoHub(of: app, "Unreachable for 20 s")
        app.tabBars.buttons["Advanced"].tap()

        XCTAssertTrue(app.element(withIdentifier: ID.reconnectingBanner).waitForExistence(timeout: 8), "The banner says the stream is down")
        XCTAssertEqual(app.sessionState?.phase, "live", "For ten seconds the last known state stays on show")
        attachScreenshot(of: app, named: "reconnecting-banner")

        XCTAssertTrue(app.element(withIdentifier: ID.unreachable).waitForExistence(timeout: 15), "After ten seconds the hub is called unreachable")
        attachScreenshot(of: app, named: "unreachable-after-live")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "The tabs make way for it")

        let back = try XCTUnwrap(waitForSession(of: app, "the hub is back", timeout: 25) { $0.phase == "live" && $0.connection == "live" })
        XCTAssertEqual(back.devices, 6)
        XCTAssertTrue(app.navigationBars["Advanced"].waitForExistence(timeout: 5), "The user is on the tab they were on")
        XCTAssertFalse(app.element(withIdentifier: ID.unreachable).exists)
    }

    /// A VoiceOver user reading the cards is told when the figures stop updating, once although
    /// every tab has its banner, and told again when they are live.
    @MainActor
    func testAShortOutageIsAnnouncedOnceAndSoIsTheWayBack() {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-demo", "-dm-then", "blip"]
        app.launch()
        let announcements = app.element(withIdentifier: ID.announcements)
        XCTAssertTrue(announcements.waitForExistence(timeout: 20))
        let banner = app.element(withIdentifier: ID.reconnectingBanner)
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "The banner says the stream is down")
        XCTAssertTrue(wait(upTo: 5) { announcements.label == "Reconnecting to hub…" }, "Announced once: \(announcements.label)")

        XCTAssertTrue(wait(upTo: 15) { !banner.exists }, "The demo hub is back after five seconds")
        XCTAssertTrue(
            wait(upTo: 5) { announcements.label == "Reconnecting to hub…|Reconnected to hub" }, "The way back is announced once: \(announcements.label)")
        XCTAssertEqual(app.sessionState?.phase, "live", "Back before the hub is called unreachable")
    }

    /// The debug menu can have the demo hub refuse the app. There is no enrollment to forget
    /// then, and the revoked screen still has to lead somewhere.
    @MainActor
    func testADemoThatRefusesTheAppCanBeLeft() {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-demo"]
        app.launch()
        waitForSession(of: app, "the demo is live") { $0.phase == "live" && $0.devices == 6 }

        directDemoHub(of: app, "Revoke this enrollment")
        XCTAssertTrue(app.element(withIdentifier: ID.revoked).waitForExistence(timeout: 15), "A demo hub that refuses the app shows the revoked screen")
        XCTAssertEqual(app.sessionState?.isDemo, true)
        attachScreenshot(of: app, named: "demo-revoked")
        app.buttons[ID.revokedPairAgain].tap()
        XCTAssertTrue(app.element(withIdentifier: ID.onboarding).waitForExistence(timeout: 10), "Pair again leaves the demo")
        XCTAssertEqual(app.sessionState?.isDemo, false)
    }

    /// Picks an item of the menu that directs the demo hub (DebugTools, at the end of the Devices tab).
    @MainActor
    private func directDemoHub(of app: XCUIApplication, _ item: String, file: StaticString = #filePath, line: UInt = #line) {
        app.tabBars.buttons["Devices"].tap()
        // A SwiftUI Menu is a pop-up button to the accessibility tree, not a button, so it is
        // looked up by its identifier alone. It is under the cards, several screens down the page.
        let menu = app.element(withIdentifier: ID.debugHubMenu)
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "The Devices tab has the debug tools", file: file, line: line)
        let isClear = app.scrollUp(app.element(withIdentifier: "screen-devices"), until: menu, swipes: 12)
        menu.tap()
        let choice = app.element(labelled: item)
        XCTAssertTrue(
            choice.waitForExistence(timeout: 5), "The debug menu opens and offers \"\(item)\" (scrolled clear of the tab bar: \(isClear))", file: file, line: line)
        choice.tap()
    }

    @MainActor
    func testSharedSheetsOpenFromAnyTab() {
        let app = XCUIApplication()
        // The Devices tab starts with the last card, the Studio PC's, at the top of the screen
        // (see DashboardDebugOptions): the end of this test taps that card's chart.
        app.launchArguments = ["-dm-demo", "-dm-dashboard-scroll", "studio:top"]
        app.launch()

        let add = app.buttons[ID.addDeviceButton]
        XCTAssertTrue(add.waitForExistence(timeout: 20))
        add.tap()
        let sheet = app.element(withIdentifier: "screen-add-device")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The + button presents the shared sheet")
        // The browser link it shows comes from the hub of the tabs' environment.
        let link = app.element(withIdentifier: "add-device-link")
        XCTAssertTrue(link.waitForExistence(timeout: 10), "The sheet asks the tabs' hub for a link")
        XCTAssertTrue(link.label.hasPrefix("https://hub.demo.example/unlock#join="), "The sheet reads the tabs' environment: \(link.label)")
        app.buttons["add-device-done-button"].tap()

        app.tabBars.buttons["Advanced"].tap()
        app.buttons["advanced-price-button"].tap()
        XCTAssertTrue(app.element(withIdentifier: "screen-electricity-price").waitForExistence(timeout: 5), "Advanced can open the price editor")
        app.buttons["electricity-price-done-button"].tap()

        app.tabBars.buttons["Settings"].tap()
        app.buttons["settings-price-button"].tap()
        XCTAssertTrue(app.element(withIdentifier: "screen-electricity-price").waitForExistence(timeout: 5), "So can Settings")
        app.buttons["electricity-price-done-button"].tap()

        // The chart of a device's card routes to History for that device. Not the first device's:
        // History opened without one shows the first. Its card is where the launch left it; a
        // swipe from the top of the page could carry a chart several screens down past the bars.
        app.tabBars.buttons["Devices"].tap()
        let chart = app.element(withIdentifier: "device-chart-studio")
        XCTAssertTrue(wait(upTo: 10) { chart.exists && chart.isHittable }, "The Studio PC's chart is on screen")
        chart.tap()
        let history = app.element(withIdentifier: "screen-history")
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        XCTAssertTrue(history.label.contains("Studio PC"), "got: \(history.label)")
    }
}
