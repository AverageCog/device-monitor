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

    /// What an earlier run may have left in the app's defaults, set aside for this launch: a range
    /// chosen on a card is remembered (`dm.cardRanges`), and the demo keeps it like any other hub's.
    /// Arguments in this form take the place of the stored values without touching them.
    private static let untouchedRanges = ["-dm.cardRanges", "{}", "-dm.range", "10m"]

    /// Starts the demo, with more launch arguments if a test wants a particular state, and waits
    /// for the first card.
    @MainActor
    private func launchDemo(_ arguments: [String] = [], waitingForCards: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-demo"] + Self.untouchedRanges + arguments
        app.launch()
        if waitingForCards {
            XCTAssertTrue(app.deviceRow("gaming").waitForExistence(timeout: 30), "The demo's first card is on screen")
        }
        return app
    }

    /// Scrolls the page until `element` can be tapped clear of the tab bar.
    ///
    /// A third of a screen at a time and without a fling: a swipe travels as far as it likes, and
    /// what is in the middle of a page several screens long can be carried past the top between
    /// two looks. The finger is in the page's margin, where no card is to take the touch.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Missing \(element)", file: file, line: line)
        let page = app.element(withIdentifier: DashboardID.screen)
        func isClear() -> Bool {
            guard element.exists, element.isHittable else { return false }
            let bar = app.tabBars.firstMatch
            // An iPad's tab bar is at the top, out of the way.
            return !bar.exists || bar.frame.minY < page.frame.midY || element.frame.maxY <= bar.frame.minY
        }
        for _ in 0..<40 {
            if isClear() { return }
            let from = page.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.7)).withOffset(CGVector(dx: -6, dy: 0))
            let to = page.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.35)).withOffset(CGVector(dx: -6, dy: 0))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(isClear(), "Could not reach \(element)", file: file, line: line)
    }

    /// Opens a menu and returns its item titled `title`.
    ///
    /// The title alone does not find it: "History" is also a tab, and the tab's button comes
    /// first in the tree, menu or no menu. The item is what carries the title once the menu is
    /// open and was not there before. No assumption about what kind of element the system makes it.
    @MainActor
    private func item(
        _ title: String, ofMenuOpenedBy opener: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) -> XCUIElement {
        func isSame(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
        }
        let titled = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title))
        let before = titled.allElementsBoundByIndex.map(\.frame)
        opener.tap()
        var found: XCUIElement?
        let appeared = wait(upTo: 5) {
            found = titled.allElementsBoundByIndex.first { candidate in
                guard candidate.exists else { return false }
                let frame = candidate.frame
                return !frame.isEmpty && !before.contains { isSame($0, frame) }
            }
            return found != nil
        }
        XCTAssertTrue(appeared, "The menu offers \"\(title)\"", file: file, line: line)
        return found ?? titled.firstMatch
    }

    /// Opens a device's "…" menu and picks an item by its title.
    @MainActor
    private func choose(_ item: String, fromMenuOf id: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let menu = app.element(withIdentifier: DashboardID.menu(id))
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "The device has a menu", file: file, line: line)
        self.item(item, ofMenuOpenedBy: menu, in: app, file: file, line: line).tap()
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
        XCTAssertTrue(app.showsTitle("History", timeout: 0))
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
        app.tab("Settings").tap()
        app.tab("Devices").tap()
        XCTAssertTrue(details.waitForExistence(timeout: 5), "Details is still open")

        toggle.tap()
        XCTAssertTrue(wait(upTo: 5) { !details.exists }, "Details closes")
    }

    /// A device that went offline gets a fresh card when it is back, the last one to go as well:
    /// with it the whole grid went, and its open Details used to be remembered through that.
    @MainActor
    func testCardsThatComeBackStartWithDetailsClosed() {
        // Every device stops reporting, and reports again eight seconds after the hub has called
        // the last of them offline (`-dm-dashboard-state offline-and-back`).
        let app = launchDemo(["-dm-dashboard-details", "all", "-dm-dashboard-state", "offline-and-back"])
        for id in Self.online {
            let toggle = app.element(withIdentifier: DashboardID.detailsToggle(id))
            XCTAssertTrue(wait(upTo: 10) { toggle.value as? String == "Expanded" }, "\(id) starts with Details open")
        }

        // The hub calls a device offline thirty seconds after its last report.
        waitForSession(of: app, "no device is online", timeout: 90) { $0.devices == 6 && $0.online == 0 }
        waitForSession(of: app, "the devices report again", timeout: 60) { $0.online == Self.online.count }
        for id in Self.online {
            XCTAssertTrue(app.deviceRow(id).waitForExistence(timeout: 10), "\(id) has a card again")
            let toggle = app.element(withIdentifier: DashboardID.detailsToggle(id))
            XCTAssertEqual(toggle.value as? String, "Collapsed", "\(id) came back as a fresh card")
            XCTAssertFalse(app.element(withIdentifier: DashboardID.details(id)).exists, "\(id) shows no details")
        }
        attachScreenshot(of: app, named: "dashboard-cards-back")
    }

    @MainActor
    func testACardsRangeIsChosenFromItsMenu() {
        let app = launchDemo()

        // Ten minutes unless a range was chosen, and this launch starts without a choice
        // (`untouchedRanges`): the one this test makes is remembered by the app.
        let range = app.element(withIdentifier: DashboardID.range("gaming"))
        XCTAssertTrue(range.waitForExistence(timeout: 10))
        XCTAssertEqual(range.value as? String, "last 10 min")
        // Every card shows "last 10 min" already; the hour is only in the menu.
        let hour = item("last 60 min", ofMenuOpenedBy: range, in: app)
        for label in ["last 10 min", "last 6 hours"] {
            XCTAssertTrue(app.element(labelled: label).waitForExistence(timeout: 5), "The range menu offers \(label)")
        }
        hour.tap()
        XCTAssertTrue(wait(upTo: 5) { range.value as? String == "last 60 min" }, "The card shows its new range: \(String(describing: range.value))")
        // The other cards keep theirs.
        XCTAssertEqual(app.element(withIdentifier: DashboardID.range("spark")).value as? String, "last 10 min")
        attachScreenshot(of: app, named: "dashboard-range")

        // The choice is the store's to keep: it is still there after the tab was left.
        app.tab("Settings").tap()
        app.tab("Devices").tap()
        XCTAssertTrue(range.waitForExistence(timeout: 10))
        XCTAssertEqual(range.value as? String, "last 60 min")

        // Back to ten minutes, which is then also what the app's defaults are left with.
        item("last 10 min", ofMenuOpenedBy: range, in: app).tap()
        XCTAssertTrue(wait(upTo: 5) { range.value as? String == "last 10 min" }, "The card is back on ten minutes: \(String(describing: range.value))")
    }

    /// A range chosen in an earlier run is in the app's defaults, the demo's included. A launch
    /// that sets the stored ranges aside starts every card on ten minutes all the same, which is
    /// what lets the tests here run a second time on the same simulator.
    @MainActor
    func testAStoredRangeIsSetAsideForALaunch() {
        // An earlier run: six hours for the Gaming PC, chosen as its menu would (`-dm-dashboard-range`).
        var app = XCUIApplication()
        app.launchArguments = ["-dm-demo", "-dm-dashboard-range", "gaming:6h"]
        app.launch()
        var range = app.element(withIdentifier: DashboardID.range("gaming"))
        XCTAssertTrue(range.waitForExistence(timeout: 30))
        XCTAssertTrue(wait(upTo: 10) { range.value as? String == "last 6 hours" }, "The choice is made: \(String(describing: range.value))")
        app.terminate()

        // The next launch, as every test here starts. A range chosen for another card in it
        // replaces what the first launch stored: a ten-minute choice is all this test leaves.
        app = launchDemo(["-dm-dashboard-range", "spark:10m"])
        range = app.element(withIdentifier: DashboardID.range("gaming"))
        XCTAssertTrue(range.waitForExistence(timeout: 10))
        XCTAssertEqual(range.value as? String, "last 10 min", "The stored choice is set aside for this launch")
    }

    // MARK: The menu

    @MainActor
    func testTheMenuOpensHistory() {
        let app = launchDemo()

        // Not the first device: History opened without one falls back on the first, and would
        // look right for the Gaming PC whatever was tapped.
        let menu = app.element(withIdentifier: DashboardID.menu("spark"))
        reveal(menu, in: app)
        // "History" is also the name of a tab, so the item is looked for as part of the menu.
        let history = item("History", ofMenuOpenedBy: menu, in: app)
        for other in ["Rename", "Remove from dashboard"] {
            XCTAssertTrue(app.element(labelled: other).waitForExistence(timeout: 5), "The menu offers \(other)")
        }
        attachScreenshot(of: app, named: "dashboard-menu")
        history.tap()

        let screen = app.element(withIdentifier: "screen-history")
        XCTAssertTrue(screen.waitForExistence(timeout: 10), "The menu's History opens the History tab")
        XCTAssertTrue(screen.label.contains("DGX Spark"), "History is on the device whose menu it was: \(screen.label)")
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

    /// The device is removed somewhere else (the web dashboard, another phone) while this phone
    /// asks whether to remove it (`-dm-dashboard-removed-elsewhere`). Its card goes and the
    /// question stays; answering Remove gets a 404 from the hub, which is what was asked for and
    /// no failure to report.
    @MainActor
    func testRemovingADeviceThatIsAlreadyGoneIsNoFailure() {
        let app = launchDemo(["-dm-dashboard-remove", "gaming", "-dm-dashboard-removed-elsewhere"], waitingForCards: false)

        let alert = app.alerts["Remove from dashboard"]
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "The question is up")
        waitForSession(of: app, "the hub has five devices") { $0.devices == 5 }
        XCTAssertTrue(wait(upTo: 10) { !app.deviceRow("gaming").exists }, "Its card has gone")
        XCTAssertTrue(alert.exists, "The question is still up")
        alert.buttons["Remove"].tap()

        XCTAssertTrue(wait(upTo: 5) { !alert.exists }, "The question has gone")
        XCTAssertFalse(app.alerts["Couldn\u{2019}t remove \u{201C}Gaming PC\u{201D}"].waitForExistence(timeout: 3), "No failure is reported")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Nothing else comes up: \(app.alerts.firstMatch.label)")
        XCTAssertEqual(app.element(withIdentifier: DashboardID.summary).label, "4 of 5 devices online")
    }

    /// While the hub is away the tab shell's banner says "Reconnecting to hub…" on every tab. The
    /// header keeps what it last knew rather than say the same a second time.
    @MainActor
    func testAnOutageIsSaidOnce() {
        // The demo hub goes away for twenty seconds once the session has settled; the banner
        // comes after a second, the unreachable screen after ten.
        let app = launchDemo(["-dm-then", "outage"])

        XCTAssertTrue(app.element(withIdentifier: ID.reconnectingBanner).waitForExistence(timeout: 15), "The banner says the stream is down")
        let summary = app.element(withIdentifier: DashboardID.summary)
        XCTAssertTrue(summary.exists)
        XCTAssertEqual(summary.label, "5 of 6 devices online", "The header keeps the last known count")
        attachScreenshot(of: app, named: "dashboard-outage")
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
        app.tab("Settings").tap()
        app.tab("Devices").tap()
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

    // MARK: The bars

    /// Scrolled down, the page has the screen to itself; scrolled back up a little, the bars are back.
    @MainActor
    func testScrollingDownPutsTheBarsAwayAndScrollingUpBringsThemBack() {
        let app = launchDemo()
        let page = app.element(withIdentifier: DashboardID.screen)
        let tabBar = app.tabBars.firstMatch
        let add = app.buttons[ID.addDeviceButton]
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        XCTAssertTrue(add.isHittable, "At the top the bars are there")

        // In the page's margin, where no card takes the touch, and slowly, so that it does not fling.
        let low = page.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.7)).withOffset(CGVector(dx: -6, dy: 0))
        low.press(forDuration: 0.05, thenDragTo: low.withOffset(CGVector(dx: 0, dy: -320)), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(wait(upTo: 3) { !(tabBar.exists && tabBar.isHittable) }, "Scrolled down, the tab bar goes")
        XCTAssertFalse(add.exists && add.isHittable, "…and so does the top bar with its + button")
        attachScreenshot(of: app, named: "dashboard-bars-away")

        let high = page.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.4)).withOffset(CGVector(dx: -6, dy: 0))
        high.press(forDuration: 0.05, thenDragTo: high.withOffset(CGVector(dx: 0, dy: 80)), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(wait(upTo: 3) { tabBar.exists && tabBar.isHittable }, "Scrolled back up a little, the tab bar is back")
        XCTAssertTrue(add.isHittable, "…and the top bar")
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

    /// In a window the size of an iPad's the logo, name and summary are a row of their own above
    /// the cards (`-dm-dashboard-header page` gives a phone that row). It stays where it is while
    /// the cards scroll: the summary is the only way to the offline list.
    @MainActor
    func testThePinnedHeaderStaysWhileTheCardsScroll() {
        let app = launchDemo(["-dm-dashboard-header", "page"])

        let summary = app.element(withIdentifier: DashboardID.summary)
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertEqual(summary.label, "5 of 6 devices online")
        let top = summary.frame.minY

        // To the end of the last card, several screens down.
        reveal(app.element(withIdentifier: DashboardID.detailsToggle("studio")), in: app)
        XCTAssertTrue(summary.exists && summary.isHittable, "The summary is still on screen")
        XCTAssertEqual(summary.frame.minY, top, accuracy: 1, "The header has not moved with the page")
        attachScreenshot(of: app, named: "dashboard-pinned-header")

        summary.tap()
        XCTAssertTrue(app.element(withIdentifier: DashboardID.offlineList).waitForExistence(timeout: 5), "From there it still opens the offline list")
        XCTAssertTrue(app.deviceRow(Self.offline).waitForExistence(timeout: 5))
    }

    /// At the largest text size a row of the offline list puts Wake and the menu under the name,
    /// several times the row's usual height. They are on show without scrolling: in a sheet on a
    /// phone, and in a popover on an iPad, which is made as tall as its rows.
    @MainActor
    func testTheOfflineListFitsLargeText() {
        let app = launchDemo(["-dm-dashboard-offline", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])

        XCTAssertTrue(app.element(withIdentifier: DashboardID.offlineList).waitForExistence(timeout: 10))
        let row = app.deviceRow(Self.offline)
        let wake = app.element(withIdentifier: DashboardID.wake(Self.offline))
        let menu = app.element(withIdentifier: DashboardID.menu(Self.offline))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(wake.waitForExistence(timeout: 5))
        attachScreenshot(of: app, named: "dashboard-offline-large-text")
        XCTAssertTrue(wake.isHittable, "Wake is on show: \(wake.frame)")
        XCTAssertTrue(menu.isHittable, "The menu is on show: \(menu.frame)")
        XCTAssertGreaterThanOrEqual(wake.frame.minY, row.frame.maxY - 1, "Wake is under the name")
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

        // At this size a line of the card does not hold a label and its value side by side (the
        // label used to be cut short), so a row of Details is its label over its value. Read as
        // one element, "Model, NVIDIA GeForce RTX 5090"; where the tree also lists the two texts
        // it is made of, the value is under the label.
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND value == %@", "Model", "NVIDIA GeForce RTX 5090")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Details names the GPU")
        let label = app.staticTexts["Model"], value = app.staticTexts["NVIDIA GeForce RTX 5090"]
        if label.exists, value.exists {
            XCTAssertGreaterThanOrEqual(value.frame.minY, label.frame.maxY - 1, "The value \(value.frame) is under its label \(label.frame)")
            XCTAssertEqual(value.frame.minX, label.frame.minX, accuracy: 2, "The value starts where its label does")
        }
    }

    /// At accessibility sizes each gauge has a row of its own, its line beside it. The gauge draws
    /// its reading and label in proportion to its size, so it grows with the text for them to, as
    /// far as the line beside it leaves room: on a phone, at the second size but not the largest.
    @MainActor
    func testTheGaugesGrowWithTheText() {
        func gaugeHeight(at size: String) -> CGFloat {
            let app = launchDemo(["-UIPreferredContentSizeCategoryName", size])
            let gauge = app.element(withIdentifier: DashboardID.gauge("cpu", "gaming"))
            XCTAssertTrue(gauge.waitForExistence(timeout: 10))
            attachScreenshot(of: app, named: "dashboard-gauges-\(size)")
            let height = gauge.frame.height
            app.terminate()
            return height
        }
        let first = gaugeHeight(at: "UICTContentSizeCategoryAccessibilityM")
        let second = gaugeHeight(at: "UICTContentSizeCategoryAccessibilityL")
        XCTAssertGreaterThan(first, 0)
        XCTAssertGreaterThan(second, first * 1.1, "The gauge grew from \(first) to \(second) points")
    }

    /// The demo's DGX Spark has a GPU that reads Warm. At the larger accessibility sizes "71°C
    /// Warm" takes most of a phone's row (about 206 points at AccessibilityXXL); gauges that grew
    /// into that room cut it to "71… W…". They grow only into what the widest temperature
    /// leaves, and the three of a card keep one size whatever the readings say.
    @MainActor
    func testTheGaugesLeaveTheTemperatureItsRoom() {
        let app = launchDemo(["-dm-dashboard-scroll", "spark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"])
        let rows = ["cpu", "gpu", "memory"].map { app.element(withIdentifier: DashboardID.gauge($0, "spark")) }
        for row in rows {
            XCTAssertTrue(row.waitForExistence(timeout: 10), "Missing \(row)")
        }
        attachScreenshot(of: app, named: "dashboard-gauges-warm-temperature")

        let gpu = rows[1].frame
        // A row is as wide as the card's content and as tall as its gauge, which is 100 wide
        // for 98 high; the stack has 16 points between the gauge and its line.
        let room = gpu.width - gpu.height * 100 / 98 - 16
        XCTAssertGreaterThanOrEqual(room, 200, "The GPU's temperature has \(room) points beside a gauge in a row of \(gpu.width)")
        for row in rows {
            XCTAssertEqual(row.frame.height, gpu.height, accuracy: 1, "The gauges are one size: \(row.frame) and \(gpu)")
        }
    }
}
