import XCTest

/// Proves the scheme, the test bundle and the app shell are wired together. Every test names the
/// session it wants with a DEBUG launch argument (see DebugLaunchOptions in the app), so none
/// depends on what an earlier run left in the simulator's Keychain.
final class SmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAnUnpairedAppShowsOnboarding() {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-memory-credentials"]
        app.launch()

        XCTAssertTrue(app.element(withIdentifier: ID.onboarding).waitForExistence(timeout: 20), "An app that is not paired starts in onboarding")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "The tabs are not shown before pairing")
        for identifier in [ID.invitationField, ID.nameField, ID.connectButton, ID.demoButton] {
            XCTAssertTrue(app.element(withIdentifier: identifier).exists, "Missing \(identifier)")
        }
        XCTAssertEqual(app.sessionState?.phase, "onboarding")
    }

    @MainActor
    func testLiveShellHasFiveTabs() {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-demo"]
        app.launch()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20), "The live phase shows the tab bar")
        for title in ["Devices", "History", "Advanced", "Alerts", "Settings"] {
            let tab = app.tabBars.buttons[title]
            XCTAssertTrue(tab.exists, "Missing tab: \(title)")
            tab.tap()
            XCTAssertTrue(app.showsTitle(title), "\(title) tab shows its title")
        }
    }

    @MainActor
    func testRouterOpensHistoryForADevice() {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-demo"]
        app.launch()

        let open = app.buttons["debug-open-history"]
        XCTAssertTrue(open.waitForExistence(timeout: 20))
        XCTAssertTrue(app.deviceRow("gaming").waitForExistence(timeout: 10), "The demo's devices have arrived")
        // The debug tools are under the cards, several screens down the page.
        XCTAssertTrue(app.scrollUp(app.element(withIdentifier: "screen-devices"), until: open, swipes: 12), "The debug tools can be scrolled to")
        open.tap()

        XCTAssertTrue(app.showsTitle("History"), "openHistory(deviceID:) switches to the History tab")
        let history = app.element(withIdentifier: "screen-history")
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        XCTAssertTrue(history.label.contains("Gaming PC"), "History received the device id, got: \(history.label)")
    }

    @MainActor
    func testLaunchArgumentsOpenATabAndASheet() {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-demo", "-dm-history", "spark", "-dm-sheet", "electricityPrice"]
        app.launch()

        XCTAssertTrue(app.element(withIdentifier: "screen-electricity-price").waitForExistence(timeout: 20), "-dm-sheet presents the shared sheet")
        app.buttons["electricity-price-done-button"].tap()
        let history = app.element(withIdentifier: "screen-history")
        XCTAssertTrue(history.waitForExistence(timeout: 5), "-dm-history opens the History tab")
        XCTAssertTrue(history.label.contains("DGX Spark"), "got: \(history.label)")
    }

    /// Opens the debug component gallery and attaches screenshots of it (`macrun <wt> shots`).
    @MainActor
    func testComponentGalleryRenders() {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-demo"]
        app.launch()

        let link = app.buttons["debug-gallery-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 20))
        // The debug tools are under the cards, several screens down the page.
        XCTAssertTrue(app.scrollUp(app.element(withIdentifier: "screen-devices"), until: link, swipes: 12), "The debug tools can be scrolled to")
        link.tap()

        let gallery = app.scrollViews["gallery-screen"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 5))
        XCTAssertTrue(app.element(withIdentifier: "device-card-gaming-pc").exists, "The mock device card is on screen")

        attachScreenshot(of: app, named: "gallery-1")
        for page in 2...8 {
            gallery.swipeUp(velocity: .slow)
            attachScreenshot(of: app, named: "gallery-\(page)")
        }
        app.buttons["gallery-close-button"].tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5), "Closing the gallery returns to the tabs")
    }
}
