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
