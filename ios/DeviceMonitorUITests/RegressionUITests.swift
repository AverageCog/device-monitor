import XCTest

/// Things that broke once in the shell and the design system, each pinned through a DEBUG launch
/// argument (see DebugLaunchOptions in the app).
final class RegressionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// A phase screen keeps one copy of its content. When the content stops fitting (keyboard,
    /// rotation, larger text) the screen starts scrolling; it must not swap in a fresh copy, which
    /// would empty a half-typed invitation and drop the keyboard.
    @MainActor
    func testPhaseContainerKeepsItsContentWhenItStartsScrolling() {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-probe", "phase-container"]
        app.launch()

        let counter = app.buttons["probe-counter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 20))
        counter.tap()
        counter.tap()
        XCTAssertEqual(counter.label, "Count: 2")

        let field = app.textFields["probe-field"]
        field.tap()
        field.typeText("abc")
        XCTAssertEqual(field.value as? String, "abc")

        let grow = app.buttons["probe-grow-button"]
        grow.tap()
        XCTAssertEqual(grow.label, "Shrink", "The content is now taller than the screen")
        XCTAssertEqual(counter.label, "Count: 2", "State inside the content survives the switch to scrolling")
        XCTAssertEqual(field.value as? String, "abc", "Typed text survives the switch to scrolling")

        grow.tap()
        XCTAssertEqual(grow.label, "Grow")
        XCTAssertEqual(counter.label, "Count: 2", "State survives the switch back to centred")
        XCTAssertEqual(field.value as? String, "abc")
    }

    /// The hub relays any finite number, and a ratio such as used / total can be far outside 0–100.
    /// The components show such a reading; formatting it used to trap.
    @MainActor
    func testOutOfRangeReadingsRender() {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-gallery", "extremes"]
        app.launch()

        let high = app.element(withIdentifier: "extreme-gauge-high")
        XCTAssertTrue(high.waitForExistence(timeout: 20), "The gallery renders readings far outside 0–100")
        XCTAssertEqual(high.value as? String, "1e+23%, 59°C, Normal")
        XCTAssertEqual(app.element(withIdentifier: "extreme-gauge-low").value as? String, "-1e+23%, no sensor")
        XCTAssertEqual(app.element(withIdentifier: "extreme-gauge-infinite").value as? String, "No reading, 1 EB / 1 KB")
        // Bars state what they draw: clamped to 0–100.
        XCTAssertEqual(app.element(withIdentifier: "extreme-stat-high").value as? String, "1 EB / 1 KB, 100%")
        XCTAssertEqual(app.element(withIdentifier: "extreme-stat-nan").value as? String, "0 B / 0 B, 0%")
        XCTAssertEqual(app.element(withIdentifier: "extreme-meter-low").value as? String, "0%")
        XCTAssertEqual(app.element(withIdentifier: "extreme-chart").value as? String, "CPU 1e+23%")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// VoiceOver reads a gauge and its caption as one element. On their own, two pills both read
    /// "Temperature" and the memory figure had no label at all.
    @MainActor
    func testGaugeColumnsReadAsOneElement() {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-gallery"]
        app.launch()

        XCTAssertTrue(app.element(withIdentifier: "device-card-gaming-pc").waitForExistence(timeout: 20))
        // The first mock card. Only the combined element is asserted: the automation tree may still
        // list what an accessibility element is made of, which VoiceOver never visits.
        for (label, value) in [("CPU", "28%, 59°C, Normal"), ("GPU", "81%, 66°C, Normal"), ("Memory", "46%, 27.6 / 60 GB")] {
            let gauge = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND value == %@", label, value)).firstMatch
            XCTAssertTrue(gauge.exists, "\(label) gauge reads as \"\(label), \(value)\"")
        }
    }

    /// A segment's plate is 32 points tall, and only the plate took a touch: short of the 44 points
    /// a finger needs, and the °C / °F segments are narrower than that as well.
    @MainActor
    func testASegmentTakesATouchJustAboveOrBelowItsPlate() {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-gallery", "selection"]
        app.launch()

        let sixHours = app.buttons["gallery-range-6h"]
        let oneHour = app.buttons["gallery-range-1h"]
        XCTAssertTrue(sixHours.waitForExistence(timeout: 20))
        XCTAssertTrue(wait(upTo: 5) { sixHours.isHittable }, "The gallery has scrolled to the segmented control")
        XCTAssertFalse(sixHours.isSelected)
        XCTAssertFalse(oneHour.isSelected)
        // The element's frame is the area that takes a touch, centred on the plate.
        XCTAssertGreaterThanOrEqual(sixHours.frame.height, 44, "6 h takes a touch over \(sixHours.frame)")
        // "1 h" and "6 h" with their padding were 43 points wide.
        XCTAssertGreaterThanOrEqual(oneHour.frame.width, 44, "1 h takes a touch across \(oneHour.frame)")
        XCTAssertGreaterThanOrEqual(sixHours.frame.width, 44, "6 h takes a touch across \(sixHours.frame)")

        // 19 points from the middle is 3 points beyond the edge of a 32-point plate.
        sixHours.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: -19)).tap()
        XCTAssertTrue(wait(upTo: 5) { sixHours.isSelected }, "A touch just above 6 h chooses it")
        oneHour.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: 19)).tap()
        XCTAssertTrue(wait(upTo: 5) { oneHour.isSelected }, "A touch just below 1 h chooses it")
    }

    /// The temperature unit's segments were 38 and 36 points wide, the shortest labels of any
    /// segmented control.
    @MainActor
    func testTheTemperatureUnitSegmentsAreTouchTargetsAcrossAsWellAsDown() {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-demo", "-dm-tab", "settings"]
        app.launch()

        for unit in ["C", "F"] {
            let segment = app.buttons["settings-unit-\(unit)"]
            XCTAssertTrue(segment.waitForExistence(timeout: 20))
            XCTAssertGreaterThanOrEqual(segment.frame.width, 44, "°\(unit) takes a touch across \(segment.frame)")
            XCTAssertGreaterThanOrEqual(segment.frame.height, 44, "°\(unit) takes a touch over \(segment.frame)")
        }
    }

    /// At the largest text sizes on a phone the price editor's mode read "One rate | Time of…".
    /// Labels that do not fit side by side now go one under the other, whole and still choosable.
    @MainActor
    func testSegmentsWhoseLabelsDoNotFitGoOneUnderTheOther() {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-gallery", "selection"]
        app.launch()

        let flat = app.buttons["gallery-narrow-flat"]
        let timeOfUse = app.buttons["gallery-narrow-tou"]
        XCTAssertTrue(timeOfUse.waitForExistence(timeout: 20))
        XCTAssertTrue(flat.exists)
        XCTAssertTrue(timeOfUse.isSelected)
        XCTAssertLessThanOrEqual(flat.frame.maxY, timeOfUse.frame.minY + 1, "One rate \(flat.frame) is not above Time of use \(timeOfUse.frame)")
        XCTAssertEqual(flat.frame.width, timeOfUse.frame.width, accuracy: 1, "Each row is as wide as the control")

        flat.tap()
        XCTAssertTrue(wait(upTo: 5) { flat.isSelected && !timeOfUse.isSelected }, "A row is chosen like a segment")
    }

    /// The price editor in Settings at the largest text size on a phone: the mode whole, one
    /// segment under the other.
    @MainActor
    func testThePriceModeIsWholeAtTheLargestTextSize() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-dm-demo", "-dm-tab", "settings", "-dm-settings-advanced", "open", "-dm-settings-scroll", "advanced",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()

        let flat = app.buttons["settings-price-mode-flat"]
        let timeOfUse = app.buttons["settings-price-mode-time-of-use"]
        XCTAssertTrue(flat.waitForExistence(timeout: 20))
        XCTAssertTrue(timeOfUse.exists)
        XCTAssertEqual(timeOfUse.label, "Time of use")
        // Side by side, the two need more than an upright phone's width at this size.
        if app.frame.width < 500 {
            XCTAssertLessThanOrEqual(flat.frame.maxY, timeOfUse.frame.minY + 1, "One rate \(flat.frame) is not above Time of use \(timeOfUse.frame)")
        }
        attachScreenshot(of: app, named: "settings-price-mode-largest-text")
    }

    /// At the largest text size the gallery used to open part-way down its first card with the top
    /// out of reach: a lazy grid inside an eager page is sized from an estimate.
    @MainActor
    func testGalleryOpensAtItsTopAtTheLargestTextSize() {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-gallery", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()

        let heading = app.element(withIdentifier: "gallery-section-cards")
        XCTAssertTrue(heading.waitForExistence(timeout: 20))
        XCTAssertGreaterThan(heading.frame.height, 30, "The text size argument took effect")
        // Cut off, the heading sat several hundred points above the top of the screen.
        let bar = app.navigationBars["Components"]
        XCTAssertTrue(bar.exists)
        XCTAssertGreaterThanOrEqual(heading.frame.minY, bar.frame.maxY, "The gallery opens with its first heading under the navigation bar")
    }
}
