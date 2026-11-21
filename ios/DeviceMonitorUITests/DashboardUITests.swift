import XCTest

/// The Devices tab against the demo hub: the cards, their menu, chart and Details, reordering,
/// and the offline list. Every test starts its own demo, so none depends on another.
///
/// The demo has six devices; "htpc" (Living Room PC) is offline and can be woken.
final class DashboardUITests: XCTestCase {
    /// The identifiers of the Devices tab (`DashboardID` in the app).
    private enum DashboardID {
        static let screen = "screen-devices"
        static let summary = "devices-summary"
        static let empty = "devices-empty"
        static let loading = "devices-loading"
        static let offlineList = "offline-list"
        static let offlineDone = "offline-list-done-button"
        static let renameField = "device-rename-field"

        static func grip(_ id: String) -> String { "device-grip-\(id)" }
        static func menu(_ id: String) -> String { "device-menu-\(id)" }
        static func gauge(_ kind: String, _ id: String) -> String { "device-gauge-\(kind)-\(id)" }
        static func chart(_ id: String) -> String { "device-chart-\(id)" }
        static func range(_ id: String) -> String { "device-range-\(id)" }
        static func detailsToggle(_ id: String) -> String { "device-details-toggle-\(id)" }
        static func details(_ id: String) -> String { "device-details-\(id)" }
        static func wake(_ id: String) -> String { "offline-wake-\(id)" }
    }

    private static let online = ["gaming", "spark", "mbp", "server", "studio"]
    private static let offline = "htpc"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Starts the demo, with more launch arguments if a test wants a particular state, and waits
    /// for the first card.
    @MainActor
    private func launchDemo(_ arguments: [String] = [], waitingForCards: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-demo"] + arguments
        app.launch()
        if waitingForCards {
            XCTAssertTrue(app.deviceRow("gaming").waitForExistence(timeout: 30), "The demo's first card is on screen")
        }
        return app
    }

    /// Scrolls the page until `element` can be tapped clear of the tab bar.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Missing \(element)", file: file, line: line)
        XCTAssertTrue(app.scrollUp(app.element(withIdentifier: DashboardID.screen), until: element, swipes: 12), "Could not reach \(element)", file: file, line: line)
    }

    /// Opens a device's "…" menu and picks an item by its title.
    @MainActor
    private func choose(_ item: String, fromMenuOf id: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let menu = app.element(withIdentifier: DashboardID.menu(id))
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "The device has a menu", file: file, line: line)
        menu.tap()
        let choice = app.element(labelled: item)
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "The menu offers \"\(item)\"", file: file, line: line)
        choice.tap()
    }

    // MARK: Cards

    @MainActor
    func testOnlineDevicesHaveACardEach() throws {
        let app = launchDemo()

        for id in Self.online {
            let card = app.deviceRow(id)
            XCTAssertTrue(card.waitForExistence(timeout: 10), "\(id) has a card")
            XCTAssertTrue((card.value as? String ?? "").hasPrefix("online, CPU "), "\(id): \(String(describing: card.value))")
        }
        XCTAssertEqual(app.deviceRow("gaming").label, "Gaming PC")
        XCTAssertFalse(app.deviceRow(Self.offline).exists, "An offline device has no card")

        // The header: "5 of 6 devices online", whichever form fits the bar.
        let summary = app.element(withIdentifier: DashboardID.summary)
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertEqual(summary.label, "5 of 6 devices online")

        // What a card is made of.
        for kind in ["cpu", "gpu", "memory"] {
            let gauge = app.element(withIdentifier: DashboardID.gauge(kind, "gaming"))
            XCTAssertTrue(gauge.exists, "Missing the \(kind) gauge")
            XCTAssertTrue((gauge.value as? String ?? "").contains("%"), "\(kind): \(String(describing: gauge.value))")
        }
        XCTAssertTrue(app.element(withIdentifier: DashboardID.chart("gaming")).exists)
        XCTAssertTrue(app.element(withIdentifier: DashboardID.range("gaming")).exists)
        XCTAssertTrue(app.element(withIdentifier: DashboardID.grip("gaming")).exists)
        XCTAssertTrue(app.element(withIdentifier: DashboardID.detailsToggle("gaming")).exists)
        attachScreenshot(of: app, named: "dashboard-cards")

        // Readings keep arriving.
        let first = app.deviceRow("gaming").value as? String
        let gauge = app.element(withIdentifier: DashboardID.gauge("cpu", "gaming"))
        let firstGauge = gauge.value as? String
        XCTAssertTrue(
            wait(upTo: 40) { app.deviceRow("gaming").value as? String != first || gauge.value as? String != firstGauge },
            "The card did not change in 40 s: \(String(describing: first))")
    }

    @MainActor
    func testTheChartOpensHistory() {
        let app = launchDemo()

        let chart = app.element(withIdentifier: DashboardID.chart("gaming"))
        XCTAssertTrue(chart.waitForExistence(timeout: 10))
        chart.tap()

        let history = app.element(withIdentifier: "screen-history")
        XCTAssertTrue(history.waitForExistence(timeout: 10), "Tapping the chart opens History")
        XCTAssertTrue(app.navigationBars["History"].exists)
    }

    @MainActor
    func testDetailsOpenAndAreRemembered() {
        let app = launchDemo()

        let toggle = app.element(withIdentifier: DashboardID.detailsToggle("gaming"))
        reveal(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "Collapsed")
        XCTAssertFalse(app.element(withIdentifier: DashboardID.details("gaming")).exists)
        toggle.tap()

        let details = app.element(withIdentifier: DashboardID.details("gaming"))
        XCTAssertTrue(details.waitForExistence(timeout: 5), "Details opens")
        XCTAssertEqual(toggle.value as? String, "Expanded")
        XCTAssertTrue(app.staticTexts["Drives"].exists || app.staticTexts["DRIVES"].exists, "The gaming PC lists its drives")
        attachScreenshot(of: app, named: "dashboard-details")

        // Still open after leaving the tab and coming back.
        app.tabBars.buttons["Settings"].tap()
        app.tabBars.buttons["Devices"].tap()
        XCTAssertTrue(details.waitForExistence(timeout: 5), "Details is still open")

        toggle.tap()
        XCTAssertTrue(wait(upTo: 5) { !details.exists }, "Details closes")
    }

    @MainActor
    func testACardsRangeIsChosenFromItsMenu() {
        let app = launchDemo()

        let range = app.element(withIdentifier: DashboardID.range("gaming"))
        XCTAssertTrue(range.waitForExistence(timeout: 10))
        XCTAssertEqual(range.value as? String, "last 10 min")
        range.tap()
        for label in ["last 10 min", "last 60 min", "last 6 hours"] {
            XCTAssertTrue(app.element(labelled: label).waitForExistence(timeout: 5), "The range menu offers \(label)")
        }
        app.element(labelled: "last 60 min").tap()
        XCTAssertTrue(wait(upTo: 5) { range.value as? String == "last 60 min" }, "The card shows its new range: \(String(describing: range.value))")
        // The other cards keep theirs.
        XCTAssertEqual(app.element(withIdentifier: DashboardID.range("spark")).value as? String, "last 10 min")
        attachScreenshot(of: app, named: "dashboard-range")
    }

    // MARK: The menu

    @MainActor
    func testTheMenuOpensHistory() {
        let app = launchDemo()

        let menu = app.element(withIdentifier: DashboardID.menu("gaming"))
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        for item in ["History", "Rename", "Remove from dashboard"] {
            XCTAssertTrue(app.element(labelled: item).waitForExistence(timeout: 5), "The menu offers \(item)")
        }
        attachScreenshot(of: app, named: "dashboard-menu")
        app.element(labelled: "History").tap()

        let history = app.element(withIdentifier: "screen-history")
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        XCTAssertTrue(history.label.contains("Gaming PC"), "History is on the device whose menu it was: \(history.label)")
    }

    @MainActor
    func testRenamingShowsOnTheCard() {
        let app = launchDemo()

        choose("Rename", fromMenuOf: "gaming", in: app)
        let alert = app.alerts["Device name"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Rename asks for the name")
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Gaming PC", "The field starts with the current name")
        attachScreenshot(of: app, named: "dashboard-rename")

        // Nothing but spaces is no name: the hub would keep the old one.
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12) + "   ")
        XCTAssertFalse(alert.buttons["Rename"].isEnabled, "An empty name cannot be saved")

        field.typeText("Workstation")
        XCTAssertTrue(alert.buttons["Rename"].isEnabled)
        alert.buttons["Rename"].tap()

        XCTAssertTrue(wait(upTo: 10) { app.deviceRow("gaming").label == "Workstation" }, "The card shows the new name: \(app.deviceRow("gaming").label)")
    }

    @MainActor
    func testRemovingAsksFirst() throws {
        let app = launchDemo()

        choose("Remove from dashboard", fromMenuOf: "gaming", in: app)
        let alert = app.alerts["Remove from dashboard"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Removing asks first")
        let message = "Remove \"Gaming PC\"? If its agent is still running it will re-appear. To stop it, run the uninstall command on that device."
        XCTAssertTrue(alert.staticTexts[message].exists, "The confirmation is the dashboard's")
        attachScreenshot(of: app, named: "dashboard-remove")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(app.deviceRow("gaming").exists, "Cancel keeps the device")

        choose("Remove from dashboard", fromMenuOf: "gaming", in: app)
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Remove"].tap()
        XCTAssertTrue(wait(upTo: 10) { !app.deviceRow("gaming").exists }, "The card is gone")
        let state = try XCTUnwrap(waitForSession(of: app, "the hub has five devices") { $0.devices == 5 })
        XCTAssertEqual(state.online, 4)
        XCTAssertEqual(app.element(withIdentifier: DashboardID.summary).label, "4 of 5 devices online")
    }

    // MARK: Reordering

    /// Whether card `a` comes before card `b` in the grid: an earlier row, or earlier in the same row.
    @MainActor
    private func card(_ a: String, isBefore b: String, in app: XCUIApplication) -> Bool {
        let first = app.deviceRow(a).frame, second = app.deviceRow(b).frame
        guard !first.isEmpty, !second.isEmpty else { return false }
        return abs(first.minY - second.minY) > 1 ? first.minY < second.minY : first.minX < second.minX
    }

    @MainActor
    func testDraggingAGripReorders() {
        let app = launchDemo()

        XCTAssertTrue(app.deviceRow("spark").waitForExistence(timeout: 10))
        XCTAssertTrue(card("gaming", isBefore: "spark", in: app), "Gaming PC starts before DGX Spark")

        // Hold the grip, then drag it onto the next card: its top, which is on screen on a phone too.
        let grip = app.element(withIdentifier: DashboardID.grip("gaming"))
        XCTAssertTrue(grip.waitForExistence(timeout: 5))
        XCTAssertEqual(grip.label, "Drag to reorder")
        XCTAssertEqual(grip.value as? String, "1 of 5")
        let start = grip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let target = app.deviceRow("spark").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
        start.press(forDuration: 0.6, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.4)

        XCTAssertTrue(wait(upTo: 10) { card("spark", isBefore: "gaming", in: app) }, "DGX Spark is now before Gaming PC")
        XCTAssertEqual(app.element(withIdentifier: DashboardID.grip("gaming")).value as? String, "2 of 5")
        attachScreenshot(of: app, named: "dashboard-reordered")

        // The order is the hub's now: it survives leaving the tab.
        app.tabBars.buttons["Settings"].tap()
        app.tabBars.buttons["Devices"].tap()
        XCTAssertTrue(app.deviceRow("gaming").waitForExistence(timeout: 10))
        XCTAssertTrue(card("spark", isBefore: "gaming", in: app))
    }

    /// The same drag without a finger (`-dm-dashboard-drag`): the calls the grip makes, onto the
    /// third card and dropped.
    @MainActor
    func testADroppedCardKeepsItsNewPlace() {
        let app = launchDemo(["-dm-dashboard-drag", "gaming:mbp"])

        XCTAssertTrue(wait(upTo: 15) { card("mbp", isBefore: "gaming", in: app) }, "Gaming PC lands after MacBook Pro")
        XCTAssertTrue(card("spark", isBefore: "mbp", in: app), "The cards it passed keep their order")
        XCTAssertTrue(wait(upTo: 5) { app.element(withIdentifier: DashboardID.grip("gaming")).value as? String == "3 of 5" })
        attachScreenshot(of: app, named: "dashboard-dropped")
    }

    /// "Move up", the accessibility action of a card's grip (`-dm-dashboard-move`).
    @MainActor
    func testMoveUpChangesPlacesWithTheCardBefore() {
        let app = launchDemo(["-dm-dashboard-move", "spark:-1"])

        XCTAssertTrue(wait(upTo: 15) { card("spark", isBefore: "gaming", in: app) }, "DGX Spark moved up")
        XCTAssertTrue(wait(upTo: 5) { app.element(withIdentifier: DashboardID.grip("spark")).value as? String == "1 of 5" })
    }

    // MARK: Offline devices

    @MainActor
    func testTheSummaryOpensTheOfflineList() {
        let app = launchDemo()

        let summary = app.element(withIdentifier: DashboardID.summary)
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        summary.tap()

        XCTAssertTrue(app.element(withIdentifier: DashboardID.offlineList).waitForExistence(timeout: 5), "The summary opens the offline list")
        XCTAssertTrue(app.navigationBars["Offline devices"].exists)
        let row = app.deviceRow(Self.offline)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.label, "Living Room PC")
        let value = row.value as? String ?? ""
        XCTAssertTrue(value.hasPrefix("offline, last seen "), "got: \(value)")
        XCTAssertTrue(app.element(withIdentifier: DashboardID.wake(Self.offline)).exists, "A device with a network address can be woken")
        XCTAssertTrue(app.element(withIdentifier: DashboardID.menu(Self.offline)).exists)
        attachScreenshot(of: app, named: "dashboard-offline-list")

        // A row opens the device's history and takes the list away.
        row.tap()
        let history = app.element(withIdentifier: "screen-history")
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        XCTAssertTrue(history.label.contains("Living Room PC"), "got: \(history.label)")
        XCTAssertFalse(app.element(withIdentifier: DashboardID.offlineList).exists)
    }

    @MainActor
    func testWakingADeviceBringsItBackAsACard() {
        let app = launchDemo()

        app.element(withIdentifier: DashboardID.summary).tap()
        let wake = app.element(withIdentifier: DashboardID.wake(Self.offline))
        XCTAssertTrue(wake.waitForExistence(timeout: 5))
        XCTAssertEqual(wake.label, "Wake")
        wake.tap()
        XCTAssertTrue(wait(upTo: 5) { wake.label == "Sent \u{2713}" || !wake.exists }, "The button says what happened: \(wake.label)")

        // The demo's PC starts reporting a few seconds later: nothing is offline any more, so
        // the list closes itself and the device gets a card.
        waitForSession(of: app, "all six devices are online", timeout: 40) { $0.online == 6 }
        XCTAssertTrue(wait(upTo: 10) { !app.element(withIdentifier: DashboardID.offlineList).exists }, "The list closes itself")
        let card = app.deviceRow(Self.offline)
        XCTAssertTrue(card.waitForExistence(timeout: 10), "The woken device has a card")
        XCTAssertTrue((card.value as? String ?? "").hasPrefix("online, CPU "))
        XCTAssertEqual(app.element(withIdentifier: DashboardID.summary).label, "6 of 6 devices online")
    }

    @MainActor
    func testRenamingFromTheOfflineList() {
        let app = launchDemo()

        app.element(withIdentifier: DashboardID.summary).tap()
        XCTAssertTrue(app.deviceRow(Self.offline).waitForExistence(timeout: 5))
        choose("Rename", fromMenuOf: Self.offline, in: app)
        let alert = app.alerts["Device name"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "The offline list asks for the name itself")
        let field = alert.textFields.firstMatch
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + "Den PC")
        alert.buttons["Rename"].tap()

        XCTAssertTrue(wait(upTo: 10) { app.deviceRow(Self.offline).label == "Den PC" }, "The row shows the new name: \(app.deviceRow(Self.offline).label)")
    }

    // MARK: Without cards

    @MainActor
    func testAHubWithoutDevicesSaysSo() throws {
        let app = launchDemo(["-dm-dashboard-state", "empty"], waitingForCards: false)

        let empty = app.element(withIdentifier: DashboardID.empty)
        XCTAssertTrue(empty.waitForExistence(timeout: 30), "A hub without devices shows the empty state")
        XCTAssertTrue(app.staticTexts["No devices yet"].exists)
        XCTAssertFalse(app.element(withIdentifier: DashboardID.summary).exists, "There is nothing to count")
        attachScreenshot(of: app, named: "dashboard-empty")

        app.buttons["devices-empty-add-button"].tap()
        XCTAssertTrue(app.element(withIdentifier: "screen-add-device").waitForExistence(timeout: 5), "Add device opens the shared sheet")
    }

    @MainActor
    func testEveryDeviceOfflineSaysSo() {
        let app = launchDemo(["-dm-dashboard-state", "all-offline"])

        // The hub calls a device offline thirty seconds after its last report.
        waitForSession(of: app, "no device is online", timeout: 90) { $0.devices == 6 && $0.online == 0 }
        XCTAssertTrue(app.element(withIdentifier: DashboardID.empty).waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["All devices are offline."].exists)
        XCTAssertEqual(app.element(withIdentifier: DashboardID.summary).label, "0 of 6 devices online")
        attachScreenshot(of: app, named: "dashboard-all-offline")

        app.buttons["devices-empty-offline-button"].tap()
        XCTAssertTrue(app.element(withIdentifier: DashboardID.offlineList).waitForExistence(timeout: 5))
        for id in Self.online + [Self.offline] {
            XCTAssertTrue(app.deviceRow(id).exists, "\(id) is in the offline list")
        }
    }

    @MainActor
    func testLargeTextKeepsTheCardsUsable() {
        let app = launchDemo(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])

        for kind in ["cpu", "gpu", "memory"] {
            XCTAssertTrue(app.element(withIdentifier: DashboardID.gauge(kind, "gaming")).exists, "Missing the \(kind) gauge at a large text size")
        }
        attachScreenshot(of: app, named: "dashboard-large-text")
        let toggle = app.element(withIdentifier: DashboardID.detailsToggle("gaming"))
        reveal(toggle, in: app)
        toggle.tap()
        XCTAssertTrue(app.element(withIdentifier: DashboardID.details("gaming")).waitForExistence(timeout: 5))
        attachScreenshot(of: app, named: "dashboard-large-text-details")
    }
}
