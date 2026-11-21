import XCTest

/// The Advanced tab on the demo hub: totals, the range, the chart, the two tables and the states
/// in between. Every test names its session with launch arguments, and the range too, because the
/// range the user chose last is kept between launches.
final class AdvancedUITests: XCTestCase {
    /// The identifiers of the Advanced screen.
    private enum AdvancedID {
        static let screen = "screen-advanced"
        static let range = "advanced-range"
        static let priceText = "advanced-price-text"
        static let priceButton = "advanced-price-button"
        static let chartTitle = "advanced-chart-title"
        static let chart = "advanced-chart"
        static let chartPlaceholder = "advanced-chart-placeholder"
        static let tooltip = "advanced-chart-tooltip"
        static let power = "advanced-power"
        static let powerTotal = "advanced-power-total"
        static let powerEmpty = "advanced-power-empty"
        static let usage = "advanced-usage"
        static let usageEmpty = "advanced-usage-empty"
        static let note = "advanced-note"
        /// The failure banner, around its text and its "Try again" button.
        static let error = "advanced-error"
        static let priceSheet = "screen-electricity-price"
        static let priceSheetDone = "electricity-price-done-button"

        static func range(_ value: String) -> String { "advanced-range-\(value)" }
        static func tile(_ kind: String) -> String { "advanced-tile-\(kind)" }
        static func legend(_ device: String) -> String { "advanced-chart-legend-\(device)" }
        static func powerRow(_ device: String) -> String { "advanced-power-row-\(device)" }
        static func breakdown(_ device: String) -> String { "advanced-power-breakdown-\(device)" }
        static func usageRow(_ device: String) -> String { "advanced-usage-row-\(device)" }
    }

    private static let tiles = ["drawing-now", "energy-used", "cost", "per-month"]
    /// Stands in for a figure that is still loading.
    private static let loading = "\u{2026}"
    /// The demo hub's devices.
    private static let devices = ["gaming", "spark", "mbp", "server", "studio", "htpc"]
    /// The largest of the system's text sizes.
    private static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The demo on the Advanced tab, on the seven-day range unless the arguments say otherwise.
    @MainActor
    private func launch(_ arguments: [String] = ["-dm-advanced-range", "7d"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-demo", "-dm-tab", "advanced"] + arguments
        app.launch()
        XCTAssertTrue(app.element(withIdentifier: AdvancedID.screen).waitForExistence(timeout: 30), "The Advanced tab opens")
        return app
    }

    @MainActor
    private func value(of element: XCUIElement) -> String {
        element.value as? String ?? ""
    }

    /// Waits until the hub's totals are on show: the energy tile no longer reads "…".
    @MainActor
    private func waitForTotals(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let energy = app.element(withIdentifier: AdvancedID.tile("energy-used"))
        XCTAssertTrue(energy.waitForExistence(timeout: 20), "The Energy used tile is there", file: file, line: line)
        let arrived = wait(upTo: 30) { !self.value(of: energy).isEmpty && !self.value(of: energy).hasPrefix(Self.loading) }
        XCTAssertTrue(arrived, "The totals did not arrive: \(value(of: energy))", file: file, line: line)
    }

    /// Scrolls the page until `element` is between the navigation bar and the tab bar. The page is
    /// one eager stack, so an element has a frame wherever it is; dragging by exactly what is
    /// missing cannot overshoot something in the middle of the page the way a swipe can.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element) is not on the page", file: file, line: line)
        let screen = app.element(withIdentifier: AdvancedID.screen)
        let centre = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        for _ in 0..<40 {
            let navigationBar = app.navigationBars.firstMatch
            let tabBar = app.tabBars.firstMatch
            // Scrolled down, the bars are away; the status bar stays, and a tap there scrolls up.
            let top = (navigationBar.exists ? navigationBar.frame.maxY : app.frame.minY + 62) + 12
            let bottom = (tabBar.exists ? tabBar.frame.minY : app.frame.maxY) - 12
            let frame = element.frame
            // How far the element's top is below the band's top, and its bottom below the band's bottom.
            let above = frame.minY - top
            let below = frame.maxY - bottom
            if above >= -8, below <= 8 { return }
            // Down by what is hidden under the title; or up by what is hidden under the tab bar,
            // but never so far that the top goes under the title.
            let move = above < 0 ? above : min(below, above)
            // Taller than the band, and its top is where it should be.
            if abs(move) < 8 { return }
            // A drag only starts to scroll after some ten points.
            let distance = max(-260, min(260, move)) + (move > 0 ? 10 : -10)
            centre.press(forDuration: 0.05, thenDragTo: centre.withOffset(CGVector(dx: 0, dy: -distance)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTFail("Could not scroll to \(element); it is at \(element.frame)", file: file, line: line)
    }

    // MARK: Totals

    @MainActor
    func testTheDemoShowsElectricityAndUsageTotals() {
        let app = launch()
        XCTAssertTrue(app.showsTitle("Advanced", timeout: 0))
        waitForTotals(in: app)

        for kind in Self.tiles {
            let tile = app.element(withIdentifier: AdvancedID.tile(kind))
            XCTAssertTrue(tile.exists, "Missing tile \(kind)")
            XCTAssertFalse(value(of: tile).hasPrefix(Self.loading), "\(kind) still loading: \(value(of: tile))")
        }
        XCTAssertEqual(app.element(withIdentifier: AdvancedID.tile("drawing-now")).label, "Drawing now")
        XCTAssertTrue(value(of: app.element(withIdentifier: AdvancedID.tile("energy-used"))).contains("kWh"))
        XCTAssertTrue(value(of: app.element(withIdentifier: AdvancedID.tile("energy-used"))).contains("last 7 days"))

        let price = app.element(withIdentifier: AdvancedID.priceText)
        XCTAssertTrue(price.exists)
        XCTAssertTrue(price.label.hasPrefix("Electricity price"), "got: \(price.label)")
        XCTAssertTrue(price.label.contains("/kWh"), "got: \(price.label)")
        attachScreenshot(of: app, named: "advanced-top")

        let chart = app.element(withIdentifier: AdvancedID.chart)
        reveal(chart, in: app)
        XCTAssertEqual(app.element(withIdentifier: AdvancedID.chartTitle).label, "Energy per day")
        XCTAssertEqual(chart.label, "Energy per day")
        XCTAssertTrue(value(of: chart).contains("kWh"), "The chart speaks its newest bucket: \(value(of: chart))")
        XCTAssertTrue(app.element(withIdentifier: AdvancedID.legend("gaming")).exists, "The legend lists the devices that used energy")
        attachScreenshot(of: app, named: "advanced-chart")

        let row = app.element(withIdentifier: AdvancedID.powerRow("gaming"))
        reveal(row, in: app)
        XCTAssertEqual(row.label, "Gaming PC")
        for heading in ["Now", "Average", "Peak", "Energy", "Cost", "Share", "Power reading"] {
            XCTAssertTrue(value(of: row).contains(heading), "The power row has no \(heading): \(value(of: row))")
        }
        attachScreenshot(of: app, named: "advanced-power")

        let offline = app.element(withIdentifier: AdvancedID.powerRow("htpc"))
        reveal(offline, in: app)
        XCTAssertTrue(value(of: offline).contains("Now offline"), "A device that is not reporting says so: \(value(of: offline))")

        let total = app.element(withIdentifier: AdvancedID.powerTotal)
        reveal(total, in: app)
        XCTAssertEqual(total.label, "All devices")
        XCTAssertTrue(value(of: total).contains("kWh"), "got: \(value(of: total))")

        let usage = app.element(withIdentifier: AdvancedID.usageRow("gaming"))
        reveal(usage, in: app)
        XCTAssertEqual(usage.label, "Gaming PC")
        for heading in ["Online", "CPU avg / peak", "GPU avg / peak", "Memory avg", "Peak temp CPU / GPU", "Downloaded", "Uploaded", "Disk read", "Disk written"] {
            XCTAssertTrue(value(of: usage).contains(heading), "The usage row has no \(heading): \(value(of: usage))")
        }
        attachScreenshot(of: app, named: "advanced-usage")

        let note = app.element(withIdentifier: AdvancedID.note)
        reveal(note, in: app)
        XCTAssertTrue(note.label.hasPrefix("Power is estimated \"at the wall\"."), "got: \(note.label)")
        XCTAssertTrue(note.label.hasSuffix("Energy is only counted while the hub is running and the device is reporting."), "got: \(note.label)")
    }

    // MARK: Range

    @MainActor
    func testChoosingARangeAsksForItsTotals() {
        let app = launch()
        waitForTotals(in: app)
        let title = app.element(withIdentifier: AdvancedID.chartTitle)
        let energy = app.element(withIdentifier: AdvancedID.tile("energy-used"))
        XCTAssertTrue(app.element(withIdentifier: AdvancedID.range("7d")).isSelected)

        app.element(withIdentifier: AdvancedID.range("24h")).tap()
        XCTAssertTrue(wait(upTo: 10) { title.label == "Energy per hour" }, "24 h is charted by the hour: \(title.label)")
        XCTAssertTrue(wait(upTo: 20) { self.value(of: energy).contains("last 24 hours") }, "got: \(value(of: energy))")
        XCTAssertTrue(app.element(withIdentifier: AdvancedID.range("24h")).isSelected)
        attachScreenshot(of: app, named: "advanced-24h")

        app.element(withIdentifier: AdvancedID.range("30d")).tap()
        XCTAssertTrue(wait(upTo: 10) { title.label == "Energy per day" }, "30 days are charted by the day: \(title.label)")
        XCTAssertTrue(wait(upTo: 20) { self.value(of: energy).contains("last 30 days") }, "got: \(value(of: energy))")
        attachScreenshot(of: app, named: "advanced-30d")
    }

    @MainActor
    func testTheChosenRangeIsKept() {
        var app = launch()
        waitForTotals(in: app)
        app.element(withIdentifier: AdvancedID.range("24h")).tap()
        XCTAssertTrue(wait(upTo: 10) { app.element(withIdentifier: AdvancedID.chartTitle).label == "Energy per hour" })
        app.terminate()

        // No range in the arguments this time: the saved one decides.
        app = launch([])
        XCTAssertTrue(wait(upTo: 10) { app.element(withIdentifier: AdvancedID.range("24h")).isSelected }, "The range chosen last is the one the tab opens on")
        XCTAssertEqual(app.element(withIdentifier: AdvancedID.chartTitle).label, "Energy per hour")

        // Leave the dashboard's default behind for whoever runs next.
        app.element(withIdentifier: AdvancedID.range("7d")).tap()
        XCTAssertTrue(wait(upTo: 10) { app.element(withIdentifier: AdvancedID.range("7d")).isSelected })
    }

    // MARK: Price

    @MainActor
    func testChangeOpensThePriceEditor() {
        let app = launch()
        let change = app.element(withIdentifier: AdvancedID.priceButton)
        XCTAssertTrue(change.waitForExistence(timeout: 10))
        change.tap()
        XCTAssertTrue(app.element(withIdentifier: AdvancedID.priceSheet).waitForExistence(timeout: 10), "Change… presents the electricity price sheet")
        app.element(withIdentifier: AdvancedID.priceSheetDone).tap()
        XCTAssertTrue(wait(upTo: 10) { change.isHittable }, "The sheet closes back to Advanced")
    }

    /// The first number of a tile's value: 192 of "192 kWh, last 7 days", 19.16 of "$19.16, at $0.100/kWh".
    @MainActor
    private func figure(of tile: XCUIElement) -> Double? {
        let text = value(of: tile)
        guard let digits = text.range(of: "[0-9][0-9.,]*[0-9]|[0-9]", options: .regularExpression) else { return nil }
        return Double(text[digits].replacingOccurrences(of: ",", with: ""))
    }

    /// The app does not ask twice because the store hears of the saved price while the first
    /// totals are on their way, as it does at every launch. A price that really is replaced in
    /// that time must reach the costs all the same.
    @MainActor
    func testAPriceSavedWhileTheFirstTotalsLoadReachesTheCosts() {
        // The hub's answers are two seconds on their way, and $0.10 a kWh is saved meanwhile.
        // The figures are read as numbers, so their notation is fixed.
        let app = launch(["-dm-advanced-range", "7d", "-dm-advanced-state", "late", "-dm-advanced-then", "price", "-AppleLocale", "en_US"])
        let price = app.element(withIdentifier: AdvancedID.priceText)
        XCTAssertTrue(price.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(upTo: 20) { price.label.contains("$0.10") }, "The price saved at launch is on show: \(price.label)")
        waitForTotals(in: app)

        // A tenth of the energy, where the demo's own price makes it nearly a third.
        let energy = app.element(withIdentifier: AdvancedID.tile("energy-used"))
        let cost = app.element(withIdentifier: AdvancedID.tile("cost"))
        func rate() -> Double? {
            guard let kWh = figure(of: energy), let paid = figure(of: cost), kWh > 0 else { return nil }
            return paid / kWh
        }
        let reached = wait(upTo: 20) { rate().map { $0 > 0.08 && $0 < 0.12 } ?? false }
        XCTAssertTrue(reached, "The cost is still the old price's: \(value(of: cost)) for \(value(of: energy))")
    }

    // MARK: Chart

    @MainActor
    func testTouchingABarShowsItsFigures() {
        let app = launch()
        waitForTotals(in: app)
        let chart = app.element(withIdentifier: AdvancedID.chart)
        reveal(chart, in: app)
        let tooltip = app.element(withIdentifier: AdvancedID.tooltip)
        XCTAssertFalse(tooltip.exists, "Nothing is picked out until a bar is touched")

        // The middle of the plot is the fourth of seven days.
        let bar = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.6))
        bar.tap()
        XCTAssertTrue(tooltip.waitForExistence(timeout: 5), "Touching a bar shows its figures")
        XCTAssertTrue(tooltip.label.contains("Total"), "got: \(tooltip.label)")
        XCTAssertTrue(tooltip.label.contains("kWh"), "got: \(tooltip.label)")
        XCTAssertTrue(tooltip.label.contains("Gaming PC"), "got: \(tooltip.label)")
        attachScreenshot(of: app, named: "advanced-chart-selected")

        bar.tap()
        XCTAssertTrue(wait(upTo: 5) { !tooltip.exists }, "Touching the same bar again lets go of it")
    }

    @MainActor
    func testTheBucketInProgressSaysSo() {
        let app = launch(["-dm-advanced-range", "7d", "-dm-advanced-bucket", "last"])
        waitForTotals(in: app)
        let tooltip = app.element(withIdentifier: AdvancedID.tooltip)
        XCTAssertTrue(tooltip.waitForExistence(timeout: 10))
        XCTAssertTrue(tooltip.label.contains("(so far)"), "Today is not over: \(tooltip.label)")
        let chart = app.element(withIdentifier: AdvancedID.chart)
        XCTAssertTrue(value(of: chart).contains("(so far)"), "The chart speaks the bucket that is picked out: \(value(of: chart))")
    }

    /// Only where there is a pointer, which is an iPad: the bar under it is picked out before the
    /// click comes, and the click must keep it rather than let go of it.
    @MainActor
    func testAClickKeepsTheBarUnderThePointer() throws {
        try XCTSkipUnless(XCUIDevice.shared.supportsPointerInteraction, "This device has no pointer")
        let app = launch()
        waitForTotals(in: app)
        let chart = app.element(withIdentifier: AdvancedID.chart)
        reveal(chart, in: app)
        let tooltip = app.element(withIdentifier: AdvancedID.tooltip)
        XCTAssertFalse(tooltip.exists, "Nothing is picked out until the pointer is over a bar")

        let bar = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.6))
        bar.hover()
        XCTAssertTrue(tooltip.waitForExistence(timeout: 5), "The pointer picks out the bar under it")
        bar.click()
        XCTAssertFalse(wait(upTo: 2) { !tooltip.exists }, "A click on the bar under the pointer keeps it")

        // What a click chose stays when the pointer leaves the chart.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.05)).hover()
        XCTAssertFalse(wait(upTo: 2) { !tooltip.exists }, "The bar a click chose stays when the pointer moves away")
    }

    // MARK: Power breakdown

    @MainActor
    func testAPowerRowOpensToItsBreakdown() {
        let app = launch()
        waitForTotals(in: app)
        let row = app.element(withIdentifier: AdvancedID.powerRow("gaming"))
        reveal(row, in: app)
        let breakdown = app.element(withIdentifier: AdvancedID.breakdown("gaming"))
        XCTAssertFalse(breakdown.exists)
        XCTAssertTrue(value(of: row).hasSuffix("Collapsed"), "got: \(value(of: row))")

        row.tap()
        XCTAssertTrue(breakdown.waitForExistence(timeout: 5), "A row opens to what the dashboard shows on hover")
        for part in ["CPU", "GPU", "rest of system", "power supply losses"] {
            XCTAssertTrue(breakdown.label.contains(part), "The breakdown has no \(part): \(breakdown.label)")
        }
        XCTAssertTrue(value(of: row).hasSuffix("Expanded"), "got: \(value(of: row))")
        attachScreenshot(of: app, named: "advanced-power-breakdown")

        row.tap()
        XCTAssertTrue(wait(upTo: 5) { !breakdown.exists }, "And closes again")
    }

    // MARK: States

    @MainActor
    func testFiguresWaitForTheHub() {
        let app = launch(["-dm-advanced-range", "7d", "-dm-advanced-state", "loading"])
        let now = app.element(withIdentifier: AdvancedID.tile("drawing-now"))
        XCTAssertTrue(now.waitForExistence(timeout: 20))
        XCTAssertTrue(wait(upTo: 20) { self.value(of: now).contains(" W") || self.value(of: now).contains(" kW") }, "What the devices draw now does not wait: \(value(of: now))")
        for kind in ["energy-used", "cost", "per-month"] {
            let tile = app.element(withIdentifier: AdvancedID.tile(kind))
            XCTAssertTrue(value(of: tile).hasPrefix(Self.loading), "\(kind) shows a placeholder while loading: \(value(of: tile))")
        }
        XCTAssertTrue(app.element(withIdentifier: AdvancedID.chartPlaceholder).exists)
        XCTAssertFalse(app.element(withIdentifier: AdvancedID.chart).exists)
        let usage = app.element(withIdentifier: AdvancedID.usageEmpty)
        reveal(usage, in: app)
        XCTAssertTrue(usage.label.contains("Loading"), "got: \(usage.label)")
        attachScreenshot(of: app, named: "advanced-loading")
    }

    @MainActor
    func testAFailedRequestSaysSoAndOffersToTryAgain() {
        let app = launch(["-dm-advanced-range", "7d", "-dm-advanced-state", "failed"])
        XCTAssertTrue(app.element(withIdentifier: AdvancedID.error).waitForExistence(timeout: 20), "A request that fails is not passed over in silence")
        let retry = app.buttons["Try again"]
        XCTAssertTrue(retry.exists, "The banner offers to try again")
        XCTAssertTrue(value(of: app.element(withIdentifier: AdvancedID.tile("energy-used"))).hasPrefix(Self.loading))
        attachScreenshot(of: app, named: "advanced-failed")

        retry.tap()
        XCTAssertTrue(wait(upTo: 10) { retry.exists && retry.isHittable }, "This hub fails every time; the banner stays")
    }

    @MainActor
    func testAnAnswerThatCannotBeRefreshedStaysOnShow() {
        let app = launch(["-dm-advanced-range", "7d", "-dm-advanced-state", "stale"])
        XCTAssertTrue(app.element(withIdentifier: AdvancedID.error).waitForExistence(timeout: 30), "The second request fails")
        let energy = app.element(withIdentifier: AdvancedID.tile("energy-used"))
        XCTAssertFalse(value(of: energy).hasPrefix(Self.loading), "The first answer stays on show: \(value(of: energy))")
        XCTAssertTrue(app.element(withIdentifier: AdvancedID.chart).exists)
        attachScreenshot(of: app, named: "advanced-stale")
    }

    @MainActor
    func testAHubWithNothingToReportSaysSo() {
        let app = launch(["-dm-advanced-range", "7d", "-dm-advanced-state", "no-devices"])
        let power = app.element(withIdentifier: AdvancedID.powerEmpty)
        XCTAssertTrue(power.waitForExistence(timeout: 20))
        XCTAssertEqual(power.label, "No power data yet.")
        let usage = app.element(withIdentifier: AdvancedID.usageEmpty)
        reveal(usage, in: app)
        XCTAssertEqual(usage.label, "No data for this time range yet.")
        XCTAssertFalse(app.element(withIdentifier: AdvancedID.powerRow("gaming")).exists)
        attachScreenshot(of: app, named: "advanced-empty")
    }

    // MARK: Large text

    @MainActor
    func testTheRangeCanBeReadAndChosenAtTheLargestTextSize() {
        let app = launch(["-dm-advanced-range", "7d"] + Self.largestText)
        waitForTotals(in: app)
        let day = app.element(withIdentifier: AdvancedID.range("24h"))
        let week = app.element(withIdentifier: AdvancedID.range("7d"))
        let month = app.element(withIdentifier: AdvancedID.range("30d"))
        for range in [day, week, month] {
            XCTAssertTrue(range.waitForExistence(timeout: 10), "\(range) is missing")
        }
        XCTAssertTrue(week.isSelected)
        // A third of an upright phone's width cuts "30 days" short at this size, so there the
        // three stand one under the other. A wider screen has room for them side by side.
        if app.frame.width < 500 {
            XCTAssertLessThanOrEqual(day.frame.maxY, week.frame.minY + 1, "24 h \(day.frame) is not above 7 days \(week.frame)")
            XCTAssertLessThanOrEqual(week.frame.maxY, month.frame.minY + 1, "7 days \(week.frame) is not above 30 days \(month.frame)")
        }
        attachScreenshot(of: app, named: "advanced-largest-text")

        let title = app.element(withIdentifier: AdvancedID.chartTitle)
        day.tap()
        XCTAssertTrue(wait(upTo: 10) { title.label == "Energy per hour" }, "24 h is charted by the hour: \(title.label)")
        XCTAssertTrue(day.isSelected)

        // Leave the dashboard's default behind for whoever runs next.
        week.tap()
        XCTAssertTrue(wait(upTo: 10) { week.isSelected })
    }

    @MainActor
    func testUsageCardsStayOnThePageAtTheLargestTextSize() {
        let app = launch(["-dm-advanced-range", "7d"] + Self.largestText)
        waitForTotals(in: app)
        let screen = app.element(withIdentifier: AdvancedID.screen)
        XCTAssertTrue(app.element(withIdentifier: AdvancedID.usageRow("gaming")).waitForExistence(timeout: 10))
        // The page is one eager stack, so a card has its frame wherever the page is scrolled to.
        // A card whose time online does not fit on a line must not grow past the page for it.
        var cards = 0
        for device in Self.devices {
            let card = app.element(withIdentifier: AdvancedID.usageRow(device))
            guard card.exists else { continue }
            cards += 1
            XCTAssertGreaterThanOrEqual(card.frame.minX, screen.frame.minX, "\(device)'s card starts off the page: \(card.frame)")
            XCTAssertLessThanOrEqual(card.frame.maxX, screen.frame.maxX, "\(device)'s card runs off the page: \(card.frame)")
        }
        XCTAssertGreaterThan(cards, 1, "The demo has several devices with usage")
    }
}
