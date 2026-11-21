import XCTest

/// The History tab on the demo hub: choosing a device and a range, zooming into a chart and back,
/// and the states the page has when the hub answers with nothing or not at all.
///
/// Every test starts from a known state with launch arguments (`-dm-demo`, and the History tab's
/// own `-dm-history-…` arguments, see HistoryDebugOptions in the app), and `-dm-reset` so that a
/// range another run chose is not the one this run starts with.
final class HistoryUITests: XCTestCase {
    /// Accessibility identifiers of the History tab.
    private enum HistoryID {
        /// The page's heading: its label is the name of the device on show.
        static let screen = "screen-history"
        static let devices = "history-devices"
        static let range = "history-range"
        static let resetZoom = "history-reset-zoom"
        static let hint = "history-hint"
        static let empty = "history-empty"
        static let error = "history-error"
        static let retry = "history-retry-button"
        static let loading = "history-loading"
        static let addDevice = "history-add-device-button"

        static func device(_ id: String) -> String { "history-device-\(id)" }
        static func range(_ name: String) -> String { "history-range-\(name)" }
        static func tile(_ kind: String) -> String { "history-tile-\(kind)" }
        static func chart(_ kind: String) -> String { "history-chart-\(kind)" }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ arguments: [String] = ["-dm-tab", "history"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-demo", "-dm-reset"] + arguments
        app.launch()
        return app
    }

    /// The page's heading once it names `device`.
    @MainActor
    @discardableResult
    private func waitForHistory(of device: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let heading = app.element(withIdentifier: HistoryID.screen)
        XCTAssertTrue(heading.waitForExistence(timeout: 30), "The History tab did not appear", file: file, line: line)
        let named = wait(upTo: 15) { heading.label.contains(device) }
        XCTAssertTrue(named, "History shows \(heading.label), expected \(device)", file: file, line: line)
        return heading
    }

    /// The chart of that kind, scrolled to where it can be touched.
    @MainActor
    private func chart(_ kind: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let chart = app.element(withIdentifier: HistoryID.chart(kind))
        XCTAssertTrue(chart.waitForExistence(timeout: 20), "No \(kind) chart", file: file, line: line)
        let page = app.scrollViews.firstMatch
        XCTAssertTrue(app.scrollUp(page, until: chart, swipes: 6), "The \(kind) chart could not be scrolled into view", file: file, line: line)
        return chart
    }

    @MainActor
    private func isSelected(_ element: XCUIElement) -> Bool {
        element.exists && element.isSelected
    }

    // MARK: - What the page shows

    @MainActor
    func testHistoryOpensOnTheFirstDeviceWithSixHours() {
        let app = launch()
        waitForHistory(of: "Gaming PC", in: app)

        XCTAssertTrue(app.navigationBars["History"].exists)
        XCTAssertTrue(isSelected(app.element(withIdentifier: HistoryID.device("gaming"))), "The first device's chip is the selected one")
        XCTAssertTrue(isSelected(app.element(withIdentifier: HistoryID.range("6h"))), "Six hours is the range a fresh install starts with")
        for name in ["1h", "6h", "24h", "7d", "30d"] {
            XCTAssertTrue(app.element(withIdentifier: HistoryID.range(name)).exists, "Missing range \(name)")
        }
        for kind in ["cpu", "gpu", "mem", "cpuTemp", "gpuTemp", "gpuPower"] {
            XCTAssertTrue(app.element(withIdentifier: HistoryID.tile(kind)).waitForExistence(timeout: 20), "Missing tile \(kind)")
        }
        let cpu = app.element(withIdentifier: HistoryID.tile("cpu"))
        XCTAssertEqual(cpu.label, "CPU")
        XCTAssertTrue((cpu.value as? String ?? "").contains("peak"), "The tile's value carries the peak and the average, got: \(String(describing: cpu.value))")
        XCTAssertFalse(app.element(withIdentifier: HistoryID.resetZoom).exists, "Nothing is zoomed at first")
        attachScreenshot(of: app, named: "history-default")
        // The Gaming PC has a reading for every chart; each is reached by scrolling down the page.
        for kind in ["utilization", "temperature", "gpuPower", "network", "diskIO"] {
            _ = chart(kind, in: app)
        }
        attachScreenshot(of: app, named: "history-last-charts")
    }

    @MainActor
    func testAChartSaysWhatItShows() {
        let app = launch()
        waitForHistory(of: "Gaming PC", in: app)

        let chart = app.element(withIdentifier: HistoryID.chart("utilization"))
        XCTAssertTrue(chart.waitForExistence(timeout: 20))
        XCTAssertEqual(chart.label, "Utilization")
        let value = chart.value as? String ?? ""
        XCTAssertTrue(value.contains("CPU") && value.contains("%"), "The chart's value is its newest readings, got: \(value)")
    }

    @MainActor
    func testTheRouterOpensHistoryForADevice() {
        let app = launch(["-dm-history", "spark"])
        waitForHistory(of: "DGX Spark", in: app)
        XCTAssertTrue(isSelected(app.element(withIdentifier: HistoryID.device("spark"))))
        XCTAssertFalse(isSelected(app.element(withIdentifier: HistoryID.device("gaming"))))
    }

    @MainActor
    func testADeviceTheHubDoesNotKnowFallsBackToTheFirst() {
        let app = launch(["-dm-history", "no-such-device"])
        waitForHistory(of: "Gaming PC", in: app)
        XCTAssertTrue(isSelected(app.element(withIdentifier: HistoryID.device("gaming"))))
    }

    // MARK: - Choosing

    @MainActor
    func testChoosingADeviceShowsItsHistory() {
        let app = launch()
        waitForHistory(of: "Gaming PC", in: app)

        let chip = app.element(withIdentifier: HistoryID.device("mbp"))
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.tap()

        waitForHistory(of: "MacBook Pro", in: app)
        XCTAssertTrue(wait(upTo: 5) { isSelected(chip) }, "The chosen chip is the selected one")
        XCTAssertTrue(app.element(withIdentifier: HistoryID.chart("utilization")).waitForExistence(timeout: 20))
        attachScreenshot(of: app, named: "history-macbook")
    }

    @MainActor
    func testAnOfflineDeviceStillHasHistory() {
        let app = launch(["-dm-history", "htpc"])
        let heading = waitForHistory(of: "Living Room PC", in: app)
        XCTAssertTrue((heading.value as? String ?? "").contains("offline"), "The heading says the device is offline, got: \(String(describing: heading.value))")
        let chip = app.element(withIdentifier: HistoryID.device("htpc"))
        XCTAssertEqual(chip.value as? String, "Offline")
    }

    @MainActor
    func testChoosingARangeIsRemembered() {
        let app = launch()
        waitForHistory(of: "Gaming PC", in: app)

        let day = app.element(withIdentifier: HistoryID.range("24h"))
        XCTAssertTrue(day.waitForExistence(timeout: 10))
        day.tap()
        XCTAssertTrue(wait(upTo: 5) { isSelected(day) }, "24 h is lit after choosing it")
        XCTAssertFalse(isSelected(app.element(withIdentifier: HistoryID.range("6h"))))
        XCTAssertTrue(app.element(withIdentifier: HistoryID.chart("utilization")).waitForExistence(timeout: 20))

        // Without -dm-reset the next launch reads what this one stored.
        app.terminate()
        app.launchArguments = ["-dm-demo", "-dm-tab", "history"]
        app.launch()
        waitForHistory(of: "Gaming PC", in: app)
        XCTAssertTrue(wait(upTo: 10) { isSelected(app.element(withIdentifier: HistoryID.range("24h"))) }, "The range survives a relaunch")
    }

    // MARK: - Zooming

    @MainActor
    func testDraggingAcrossAChartZoomsAndResetZoomGoesBack() {
        let app = launch()
        waitForHistory(of: "Gaming PC", in: app)
        let chart = chart("utilization", in: app)

        // A drag that starts moving at once is a selection; one that rests first is pointing.
        let start = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.6))
        let end = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6))
        start.press(forDuration: 0.03, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.1)

        let reset = app.element(withIdentifier: HistoryID.resetZoom)
        XCTAssertTrue(reset.waitForExistence(timeout: 10), "Dragging across a chart zooms into the stretch")
        XCTAssertFalse(isSelected(app.element(withIdentifier: HistoryID.range("6h"))), "No range is lit while zoomed")
        attachScreenshot(of: app, named: "history-zoomed")

        let page = app.scrollViews.firstMatch
        for _ in 0..<4 where !reset.isHittable { page.swipeDown() }
        reset.tap()
        XCTAssertTrue(wait(upTo: 10) { !reset.exists }, "Reset zoom goes away with the zoom")
        XCTAssertTrue(wait(upTo: 5) { isSelected(app.element(withIdentifier: HistoryID.range("6h"))) }, "The range is lit again")
    }

    @MainActor
    func testDoubleTappingAChartLeavesTheZoom() {
        let app = launch(["-dm-tab", "history", "-dm-history-zoom", "0.3,0.7"])
        waitForHistory(of: "Gaming PC", in: app)
        let reset = app.element(withIdentifier: HistoryID.resetZoom)
        XCTAssertTrue(reset.waitForExistence(timeout: 20), "-dm-history-zoom starts zoomed")

        chart("utilization", in: app).doubleTap()
        XCTAssertTrue(wait(upTo: 10) { !reset.exists }, "A double tap on a chart resets the zoom")
    }

    @MainActor
    func testResetZoomLeavesTheDeviceNameItsRoom() {
        // At the usual text size the button sits beside the name, as on the dashboard.
        var app = launch(["-dm-tab", "history", "-dm-history-zoom", "0.2,0.8"])
        var heading = waitForHistory(of: "Gaming PC", in: app)
        var reset = app.element(withIdentifier: HistoryID.resetZoom)
        XCTAssertTrue(reset.waitForExistence(timeout: 20), "-dm-history-zoom starts zoomed")
        XCTAssertFalse(reset.frame.intersects(heading.frame), "Reset zoom \(reset.frame) lies over the name \(heading.frame)")
        XCTAssertLessThan(reset.frame.minY, heading.frame.maxY, "Reset zoom shares the row with the name while both fit in it")
        app.terminate()

        // At the largest text size the button would take most of the row: the name broke as
        // "Gami", "ng PC", and the line that says whether the device is online was cut short.
        app = launch(["-dm-tab", "history", "-dm-history-zoom", "0.2,0.8", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        heading = waitForHistory(of: "Gaming PC", in: app)
        reset = app.element(withIdentifier: HistoryID.resetZoom)
        XCTAssertTrue(reset.waitForExistence(timeout: 20), "-dm-history-zoom starts zoomed")
        XCTAssertFalse(reset.frame.intersects(heading.frame), "Reset zoom \(reset.frame) lies over the name \(heading.frame)")
        // On a phone the two cannot share a row at this size; a wide iPad may still have the room.
        if app.frame.width < 500 {
            XCTAssertGreaterThanOrEqual(reset.frame.minY, heading.frame.maxY, "Reset zoom goes under the name when the row is too narrow for both")
            XCTAssertGreaterThan(heading.frame.width, app.frame.width / 2, "The name keeps the row: \(heading.frame)")
        }
        attachScreenshot(of: app, named: "history-zoomed-largest-text")
    }

    @MainActor
    func testHoldingAChartPointsWithoutZooming() {
        let app = launch()
        waitForHistory(of: "Gaming PC", in: app)
        let chart = chart("utilization", in: app)

        let start = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6))
        let end = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.6))
        start.press(forDuration: 0.8, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)

        XCTAssertFalse(app.element(withIdentifier: HistoryID.resetZoom).waitForExistence(timeout: 2), "Resting on the chart first inspects it; it does not zoom")
        XCTAssertTrue(isSelected(app.element(withIdentifier: HistoryID.range("6h"))))
    }

    @MainActor
    func testThePageStillScrollsFromAChart() {
        let app = launch()
        waitForHistory(of: "Gaming PC", in: app)
        let chart = chart("utilization", in: app)

        let before = chart.frame.minY
        let start = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        start.press(forDuration: 0.03, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -220)), withVelocity: .fast, thenHoldForDuration: 0.3)

        XCTAssertTrue(wait(upTo: 5) { !chart.exists || chart.frame.minY < before - 60 }, "A drag that starts upwards on a chart scrolls the page")
        XCTAssertFalse(app.element(withIdentifier: HistoryID.resetZoom).exists, "Scrolling did not zoom")
    }

    @MainActor
    func testTheNoteUnderTheChartsExplainsThem() {
        let app = launch(["-dm-tab", "history", "-dm-history-scroll", "hint"])
        waitForHistory(of: "Gaming PC", in: app)
        let hint = app.element(withIdentifier: HistoryID.hint)
        XCTAssertTrue(hint.waitForExistence(timeout: 20))
        XCTAssertTrue(hint.label.contains("Shaded bands show the peak within each interval."), "got: \(hint.label)")
    }

    // MARK: - States

    @MainActor
    func testARangeWithoutReadingsSaysSo() {
        let app = launch(["-dm-tab", "history", "-dm-history-state", "empty"])
        waitForHistory(of: "Gaming PC", in: app)

        let empty = app.element(withIdentifier: HistoryID.empty)
        XCTAssertTrue(empty.waitForExistence(timeout: 20))
        XCTAssertEqual(empty.label, "No history for this time range yet. Data is recorded while the device is online.")
        XCTAssertFalse(app.element(withIdentifier: HistoryID.chart("utilization")).exists)
        attachScreenshot(of: app, named: "history-empty")
    }

    @MainActor
    func testAFailedRequestOffersToTryAgain() {
        let app = launch(["-dm-tab", "history", "-dm-history-state", "error"])
        waitForHistory(of: "Gaming PC", in: app)

        XCTAssertTrue(app.element(withIdentifier: HistoryID.error).waitForExistence(timeout: 20), "The first request fails")
        attachScreenshot(of: app, named: "history-error")
        let retry = app.element(withIdentifier: HistoryID.retry)
        XCTAssertTrue(retry.exists)
        retry.tap()

        XCTAssertTrue(app.element(withIdentifier: HistoryID.chart("utilization")).waitForExistence(timeout: 20), "Trying again loads the charts")
        XCTAssertFalse(app.element(withIdentifier: HistoryID.error).exists)
    }

    @MainActor
    func testAHubThatDoesNotAnswerShowsLoading() {
        let app = launch(["-dm-tab", "history", "-dm-history-state", "loading"])
        waitForHistory(of: "Gaming PC", in: app)
        XCTAssertTrue(app.element(withIdentifier: HistoryID.loading).waitForExistence(timeout: 20))
        XCTAssertFalse(app.element(withIdentifier: HistoryID.chart("utilization")).exists)
    }

    @MainActor
    func testAHubWithoutDevicesOffersToAddOne() {
        let app = launch(["-dm-tab", "history", "-dm-history-state", "no-devices"])
        let add = app.element(withIdentifier: HistoryID.addDevice)
        XCTAssertTrue(add.waitForExistence(timeout: 30), "Without devices the page offers to add one")
        XCTAssertFalse(app.element(withIdentifier: HistoryID.range).exists)
        add.tap()
        XCTAssertTrue(app.element(withIdentifier: "screen-add-device").waitForExistence(timeout: 10), "It opens the shared Add device sheet")
    }

    @MainActor
    func testLargeTextKeepsEverythingReachable() {
        let app = launch(["-dm-tab", "history", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        waitForHistory(of: "Gaming PC", in: app)
        XCTAssertTrue(app.element(withIdentifier: HistoryID.range("30d")).exists, "Every range is still there at a large text size")
        XCTAssertTrue(app.element(withIdentifier: HistoryID.tile("cpu")).waitForExistence(timeout: 20))
        attachScreenshot(of: app, named: "history-large-text")
        _ = chart("utilization", in: app)
        attachScreenshot(of: app, named: "history-large-text-chart")
    }
}
