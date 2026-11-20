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
}
