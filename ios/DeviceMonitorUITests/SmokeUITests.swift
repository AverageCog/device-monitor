import XCTest

/// Proves the scheme, the test bundle and the app shell are wired together.
/// Launch arguments understood by DEBUG builds: `-dm-phase <onboarding|connecting|live|unreachable|revoked>`.
final class SmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFirstLaunchShowsOnboarding() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.element(withIdentifier: "onboarding-screen").waitForExistence(timeout: 20), "A fresh install starts in onboarding")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "The tabs are not shown before pairing")
    }

    @MainActor
    func testLiveShellHasFiveTabs() {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-phase", "live"]
        app.launch()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20), "The live phase shows the tab bar")
        for title in ["Devices", "History", "Advanced", "Alerts", "Settings"] {
            let tab = app.tabBars.buttons[title]
            XCTAssertTrue(tab.exists, "Missing tab: \(title)")
            tab.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), "\(title) tab shows its navigation title")
        }
    }

    @MainActor
    func testRouterOpensHistoryForADevice() {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-phase", "live"]
        app.launch()

        let open = app.buttons["debug-open-history"]
        XCTAssertTrue(open.waitForExistence(timeout: 20))
        open.tap()

        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5), "openHistory(for:) switches to the History tab")
        let history = app.element(withIdentifier: "screen-history")
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        XCTAssertTrue(history.label.contains("demo-device"), "History received the device id, got: \(history.label)")
    }

    @MainActor
    func testFailurePhasesOfferAWayOut() {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-phase", "unreachable"]
        app.launch()

        XCTAssertTrue(app.buttons["unreachable-retry-button"].waitForExistence(timeout: 20))
        app.buttons["unreachable-change-button"].tap()
        XCTAssertTrue(app.element(withIdentifier: "onboarding-screen").waitForExistence(timeout: 5), "Change setup returns to onboarding")
    }

    /// Opens the debug component gallery and attaches screenshots of it (`macrun <wt> shots`).
    @MainActor
    func testComponentGalleryRenders() {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-phase", "live"]
        app.launch()

        let link = app.buttons["debug-gallery-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 20))
        link.tap()

        let gallery = app.scrollViews["gallery-screen"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 5))
        XCTAssertTrue(app.element(withIdentifier: "device-card-gaming-pc").exists, "The mock device card is on screen")

        attachScreenshot(of: app, named: "gallery-1")
        for page in 2...8 {
            gallery.swipeUp(velocity: .slow)
            attachScreenshot(of: app, named: "gallery-\(page)")
        }
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension XCUIApplication {
    /// Any element with this accessibility identifier, whatever its type.
    @MainActor
    func element(withIdentifier identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
