import XCTest

/// The Settings tab, the electricity price editor and the add-device sheet, on the demo hub and
/// on a session "paired" with one (`-dm-phase live`). Nothing here needs a real hub.
///
/// States a tap cannot produce (a hub that does not answer, a link that lapsed) are opened with
/// the `-dm-settings-…` launch arguments; see SettingsDebugOptions.swift in the app.
final class SettingsUITests: XCTestCase {
    /// The identifiers of these screens. The ones the flow tests share are in `ID`.
    private enum SID {
        static let screen = "screen-settings"
        static let unitCelsius = "settings-unit-C"
        static let unitFahrenheit = "settings-unit-F"
        static let linkButton = "settings-link-button"
        static let link = "settings-link"
        static let linkCopy = "settings-link-copy-button"
        static let linkShare = "settings-link-share-button"
        static let linkError = "settings-link-error"
        static let hubHost = "settings-hub-host"
        static let hubAddress = "settings-hub-address"
        static let hubIdentity = "settings-hub-identity"
        static let hubIdentityButton = "settings-hub-identity-button"
        static let priceButton = "settings-price-button"
        static let advancedToggle = "settings-advanced-toggle"
        static let version = "settings-about-version"
        static let licenseButton = "settings-license-button"
        static let license = "screen-license"

        static let priceSheet = "screen-electricity-price"
        static let priceDone = "electricity-price-done-button"
        static let regions = "screen-price-regions"

        static let addSheet = "screen-add-device"
        static let addDone = "add-device-done-button"
        static let addLink = "add-device-link"
        static let addQR = "add-device-qr"
        static let addCopy = "add-device-copy-button"
        static let addShare = "add-device-share-button"
        static let addNewLink = "add-device-new-link-button"
        static let addLinkError = "add-device-link-error"
        static let addLinkUnavailable = "add-device-link-unavailable"
        static let addLinkExpired = "add-device-link-expired"

        /// The price editor's controls; `prefix` is "settings-price" in the Settings tab and
        /// "price" in the sheet.
        static func mode(_ prefix: String, _ mode: String) -> String { "\(prefix)-mode-\(mode)" }
        static func rateField(_ prefix: String) -> String { "\(prefix)-rate-field" }
        static func baseRateField(_ prefix: String) -> String { "\(prefix)-base-rate-field" }
        static func periodRateField(_ prefix: String, _ index: Int) -> String { "\(prefix)-period-\(index)-rate-field" }
        static func removePeriod(_ prefix: String, _ index: Int) -> String { "\(prefix)-period-\(index)-remove" }
        static func addPeriod(_ prefix: String) -> String { "\(prefix)-add-period-button" }
        static func region(_ prefix: String) -> String { "\(prefix)-region" }
        static func currency(_ prefix: String) -> String { "\(prefix)-currency" }
        static func hint(_ prefix: String) -> String { "\(prefix)-hint" }
    }

    private static let demoOrigin = "https://hub.demo.example"
    private static let linkPrefix = demoOrigin + "/unlock#join="

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    /// Scrolls `screen` (the Settings tab unless said otherwise) until `element` can be tapped,
    /// whichever way it lies. Under the tabs that also means clear of the tab bar, which floats
    /// over the end of the list.
    @MainActor
    private func reveal(
        _ element: XCUIElement, in app: XCUIApplication, screen: String = SID.screen, underTabs: Bool = true,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Missing \(element)", file: file, line: line)
        let scroll = app.element(withIdentifier: screen)
        let bar = app.tabBars.firstMatch
        func isClear() -> Bool {
            guard element.exists, element.isHittable else { return false }
            return !underTabs || !bar.exists || element.frame.maxY <= bar.frame.minY
        }
        for _ in 0..<12 {
            if isClear() { return }
            // Above what is on show, or below it.
            if element.frame.midY < scroll.frame.minY + 140 {
                scroll.swipeDown(velocity: .slow)
            } else {
                scroll.swipeUp(velocity: .slow)
            }
        }
        XCTAssertTrue(isClear(), "Could not scroll to \(element)", file: file, line: line)
    }

    // MARK: - Settings

    @MainActor
    func testTheDemoSaysWhatItIsAndNamesItsHub() {
        let app = launch(["-dm-demo", "-dm-tab", "settings"])
        XCTAssertTrue(app.element(withIdentifier: SID.screen).waitForExistence(timeout: 20))
        XCTAssertTrue(app.navigationBars["Settings"].exists)

        let leave = app.buttons[ID.disconnectButton]
        XCTAssertTrue(leave.waitForExistence(timeout: 5))
        XCTAssertEqual(leave.label, "Exit demo")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Running the demo")).firstMatch.exists, "The demo is said to be one")

        let host = app.element(withIdentifier: SID.hubHost)
        XCTAssertTrue(wait(upTo: 10) { host.exists && host.value as? String == "demo-hub" }, "Host name: \(String(describing: host.value))")
        XCTAssertEqual(app.element(withIdentifier: SID.hubAddress).value as? String, Self.demoOrigin)
        XCTAssertTrue(app.buttons[SID.priceButton].exists)
        XCTAssertFalse(app.element(withIdentifier: SID.hubIdentity).exists, "A demo hub has no TLS key to show")
        XCTAssertTrue(app.buttons[SID.unitCelsius].exists && app.buttons[SID.unitFahrenheit].exists)
        attachScreenshot(of: app, named: "settings-demo")

        let version = app.element(withIdentifier: SID.version)
        XCTAssertTrue(version.exists)
        XCTAssertTrue(version.label.contains("Version "), "got: \(version.label)")
    }

    @MainActor
    func testAPairedPhoneShowsTheHubsIdentityAndIsAskedBeforeDisconnecting() {
        let app = launch(["-dm-phase", "live", "-dm-tab", "settings"])
        let disconnect = app.buttons[ID.disconnectButton]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 20))
        XCTAssertEqual(disconnect.label, "Disconnect\u{2026}")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Paired as Debug iPhone")).firstMatch.exists)

        // The debug session's pin is 43 "A"s and "=".
        let toggle = app.buttons[SID.hubIdentityButton]
        reveal(toggle, in: app)
        XCTAssertTrue(app.staticTexts["AAAAAAAA\u{2026}AAAAAAA="].exists, "The pin is shown shortened")
        XCTAssertEqual(toggle.label, "Show all")
        toggle.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "AAAA AAAA AAAA")).firstMatch.waitForExistence(timeout: 5), "And whole, in groups, on request")
        XCTAssertEqual(toggle.label, "Show less")
        attachScreenshot(of: app, named: "settings-identity")

        // Disconnecting asks first. The question's own button is "Disconnect", without the ellipsis.
        reveal(disconnect, in: app)
        disconnect.tap()
        let confirm = app.buttons["Disconnect"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Disconnecting is asked about first")
        XCTAssertTrue(app.staticTexts["Disconnect this iPhone and change setup?"].exists || app.staticTexts["Disconnect this iPad and change setup?"].exists)
        XCTAssertEqual(app.sessionState?.phase, "live", "Nothing has happened yet")
        attachScreenshot(of: app, named: "settings-disconnect-question")
        confirm.tap()
        XCTAssertTrue(app.element(withIdentifier: ID.onboarding).waitForExistence(timeout: 15), "Disconnect returns to onboarding")
    }

    @MainActor
    func testTheTemperatureUnitCanBeChangedAndPutBack() {
        let app = launch(["-dm-demo", "-dm-tab", "settings"])
        let celsius = app.buttons[SID.unitCelsius]
        let fahrenheit = app.buttons[SID.unitFahrenheit]
        XCTAssertTrue(fahrenheit.waitForExistence(timeout: 20))
        fahrenheit.tap()
        XCTAssertTrue(wait(upTo: 5) { fahrenheit.isSelected && !celsius.isSelected }, "°F is the unit now")
        // The choice is kept in the app's preferences: leave it as the other tests expect it.
        celsius.tap()
        XCTAssertTrue(wait(upTo: 5) { celsius.isSelected && !fahrenheit.isSelected }, "And °C again")
    }

    @MainActor
    func testADashboardLinkIsMadeOnRequestAndGoneWhenTheTabIsLeft() {
        let app = launch(["-dm-demo", "-dm-tab", "settings"])
        let create = app.buttons[SID.linkButton]
        XCTAssertTrue(create.waitForExistence(timeout: 20))
        XCTAssertEqual(create.label, "Create link")
        XCTAssertFalse(app.element(withIdentifier: SID.link).exists, "No link until one is asked for")
        create.tap()

        let link = app.element(withIdentifier: SID.link)
        XCTAssertTrue(link.waitForExistence(timeout: 10), "The hub made a link")
        XCTAssertTrue(link.label.hasPrefix(Self.linkPrefix), "got: \(link.label)")
        XCTAssertEqual(link.label.count, Self.linkPrefix.count + 43, "got: \(link.label)")
        XCTAssertTrue(app.buttons[SID.linkShare].exists)
        XCTAssertEqual(create.label, "New link")
        let first = link.label

        let copy = app.buttons[SID.linkCopy]
        XCTAssertEqual(copy.label, "Copy")
        copy.tap()
        XCTAssertTrue(wait(upTo: 3) { copy.label == "Copied" }, "Copying is acknowledged")
        attachScreenshot(of: app, named: "settings-link")
        XCTAssertTrue(wait(upTo: 5) { copy.label == "Copy" }, "For a moment")

        create.tap()
        XCTAssertTrue(wait(upTo: 10) { link.exists && link.label != first }, "A new link replaces the old one")

        // It signs a browser in, so it does not outlive the screen.
        app.tabBars.buttons["Devices"].tap()
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertFalse(link.exists, "The link is gone once the tab was left")
        XCTAssertEqual(create.label, "Create link")
    }

    @MainActor
    func testALinkTheHubCannotMakeIsExplainedInline() {
        let app = launch(["-dm-demo", "-dm-tab", "settings", "-dm-settings-link", "error"])
        let failure = app.element(withIdentifier: SID.linkError)
        XCTAssertTrue(failure.waitForExistence(timeout: 20))
        XCTAssertEqual(failure.label, "Could not connect to the hub.")
        XCTAssertEqual(app.buttons[SID.linkButton].label, "Try again")
        XCTAssertFalse(app.element(withIdentifier: SID.link).exists)
    }

    @MainActor
    func testTheLicenseCanBeRead() {
        let app = launch(["-dm-demo", "-dm-tab", "settings", "-dm-settings-scroll", "about"])
        let row = app.buttons[SID.licenseButton]
        reveal(row, in: app)
        XCTAssertTrue(row.label.contains("MIT License"), "got: \(row.label)")
        row.tap()
        XCTAssertTrue(app.element(withIdentifier: SID.license).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Permission is hereby granted")).firstMatch.exists)
        attachScreenshot(of: app, named: "settings-license")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.element(withIdentifier: SID.screen).waitForExistence(timeout: 5))
    }

    // MARK: - The price editor

    @MainActor
    func testAdvancedSettingsHoldThePriceEditor() {
        let prefix = "settings-price"
        // Closed for this run whatever was remembered; opening it by hand is the test.
        let app = launch(["-dm-demo", "-dm-tab", "settings", "-dm-settings-advanced", "closed", "-dm-settings-scroll", "advanced"])
        let toggle = app.buttons[SID.advancedToggle]
        reveal(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "Collapsed")
        XCTAssertFalse(app.buttons[SID.mode(prefix, "flat")].exists)
        toggle.tap()
        XCTAssertTrue(wait(upTo: 5) { toggle.value as? String == "Expanded" })

        // The demo hub opens with California's typical rate.
        let flat = app.buttons[SID.mode(prefix, "flat")]
        let timeOfUse = app.buttons[SID.mode(prefix, "time-of-use")]
        XCTAssertTrue(flat.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(upTo: 10) { flat.isSelected }, "One rate to begin with")
        let hint = app.element(withIdentifier: SID.hint(prefix))
        XCTAssertTrue(hint.label.hasPrefix("Typical home rate for California."), "got: \(hint.label)")
        let rate = app.element(withIdentifier: SID.rateField(prefix))
        reveal(rate, in: app)
        XCTAssertEqual(rate.value as? String, "0.316")
        attachScreenshot(of: app, named: "settings-price-flat")

        // Time of use starts with one period, 4 pm to 9 pm, at the flat rate.
        reveal(timeOfUse, in: app)
        timeOfUse.tap()
        let firstRate = app.element(withIdentifier: SID.periodRateField(prefix, 0))
        XCTAssertTrue(firstRate.waitForExistence(timeout: 10), "Time of use shows its periods")
        XCTAssertTrue(wait(upTo: 5) { timeOfUse.isSelected })
        XCTAssertEqual(firstRate.value as? String, "0.316")
        XCTAssertEqual(hint.label, "Each hour is charged at the rate of its period.")
        XCTAssertTrue(app.buttons["Remove 4 pm to 9 pm"].exists, "The period is named by its hours")
        XCTAssertTrue(app.element(withIdentifier: SID.baseRateField(prefix)).exists)

        let add = app.buttons[SID.addPeriod(prefix)]
        reveal(add, in: app)
        add.tap()
        XCTAssertTrue(app.element(withIdentifier: SID.periodRateField(prefix, 1)).waitForExistence(timeout: 10), "A second period")
        XCTAssertTrue(app.buttons["Remove 9 pm to 10 pm"].waitForExistence(timeout: 5), "It starts where the first one ends")
        attachScreenshot(of: app, named: "settings-price-time-of-use")

        let remove = app.buttons[SID.removePeriod(prefix, 1)]
        reveal(remove, in: app)
        remove.tap()
        XCTAssertTrue(wait(upTo: 10) { !app.element(withIdentifier: SID.periodRateField(prefix, 1)).exists }, "And one again")

        // Back to one rate, and folded away again, so the next launch finds it as this one did.
        reveal(flat, in: app)
        flat.tap()
        XCTAssertTrue(rate.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(upTo: 5) { !firstRate.exists && flat.isSelected })
        reveal(toggle, in: app)
        toggle.tap()
        XCTAssertTrue(wait(upTo: 5) { toggle.value as? String == "Collapsed" })
    }

    @MainActor
    func testARateTypedIntoTheSheetIsSavedWhenTheSheetCloses() {
        let app = launch(["-dm-demo", "-dm-tab", "settings", "-dm-sheet", "electricityPrice"])
        XCTAssertTrue(app.element(withIdentifier: SID.priceSheet).waitForExistence(timeout: 20))
        let rate = app.element(withIdentifier: SID.rateField("price"))
        XCTAssertTrue(wait(upTo: 10) { rate.exists && rate.value as? String == "0.316" }, "The saved rate: \(String(describing: rate.value))")

        // The cursor goes to the end of the right-aligned text; the old rate is deleted from there.
        rate.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        rate.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "0.25")
        XCTAssertEqual(rate.value as? String, "0.25")
        attachScreenshot(of: app, named: "price-sheet-typing")
        app.buttons[SID.priceDone].tap()

        // Settings reports what the hub now holds.
        let saved = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "$0.250/kWh")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "The hub was told when the sheet closed")
        XCTAssertTrue(saved.label.hasSuffix("The rate you entered."), "got: \(saved.label)")
    }

    @MainActor
    func testARateThatIsNotOneIsPutBack() {
        let app = launch(["-dm-demo", "-dm-sheet", "electricityPrice"])
        let rate = app.element(withIdentifier: SID.rateField("price"))
        XCTAssertTrue(wait(upTo: 20) { rate.exists && rate.value as? String == "0.316" })
        rate.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        rate.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "0")
        // Leaving the field commits it: nothing above zero, so the saved rate comes back.
        app.buttons[SID.mode("price", "flat")].tap()
        let done = app.buttons["price-keyboard-done"]
        if done.waitForExistence(timeout: 2) { done.tap() }
        XCTAssertTrue(wait(upTo: 10) { rate.value as? String == "0.316" }, "got: \(String(describing: rate.value))")
    }

    @MainActor
    func testChoosingWhereYouLiveBringsItsRateAndCurrency() {
        let app = launch(["-dm-demo", "-dm-sheet", "electricityPrice"])
        let region = app.buttons[SID.region("price")]
        XCTAssertTrue(region.waitForExistence(timeout: 20))
        XCTAssertTrue(wait(upTo: 10) { region.value as? String == "California" }, "got: \(String(describing: region.value))")
        region.tap()

        XCTAssertTrue(app.element(withIdentifier: SID.regions).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["price-region-US-CA"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["price-region-US-CA"].isSelected, "The saved place is marked")
        // Germany is far down a long list: search for it.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("germ")
        let germany = app.buttons["price-region-DE"]
        XCTAssertTrue(germany.waitForExistence(timeout: 5))
        XCTAssertTrue(germany.label.contains("Germany"), "got: \(germany.label)")
        attachScreenshot(of: app, named: "price-regions-search")
        germany.tap()

        XCTAssertTrue(region.waitForExistence(timeout: 5), "Choosing returns to the editor")
        XCTAssertTrue(wait(upTo: 10) { region.value as? String == "Germany" }, "got: \(String(describing: region.value))")
        XCTAssertEqual(app.element(withIdentifier: SID.currency("price")).value as? String, "EUR")
        XCTAssertEqual(app.element(withIdentifier: SID.rateField("price")).value as? String, "0.39")
        XCTAssertTrue(app.element(withIdentifier: SID.hint("price")).label.hasPrefix("Typical home rate for Germany."))
    }

    @MainActor
    func testTheEditorSaysWhenTheHubCannotBeAskedOrTold() {
        var app = launch(["-dm-demo", "-dm-sheet", "electricityPrice", "-dm-settings-price", "load-error"])
        let loadError = app.element(withIdentifier: "price-load-error")
        XCTAssertTrue(loadError.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons[SID.mode("price", "flat")].exists, "No controls without a price to start from")
        attachScreenshot(of: app, named: "price-load-error")
        app.terminate()

        app = launch(["-dm-demo", "-dm-sheet", "electricityPrice", "-dm-settings-price", "save-error"])
        let saveError = app.element(withIdentifier: "price-save-error")
        XCTAssertTrue(saveError.waitForExistence(timeout: 20))
        // The change did not happen: the editor shows what the hub still has.
        XCTAssertTrue(app.buttons[SID.mode("price", "flat")].isSelected)
        XCTAssertEqual(app.element(withIdentifier: SID.rateField("price")).value as? String, "0.316")
        attachScreenshot(of: app, named: "price-save-error")
        app.terminate()

        app = launch(["-dm-demo", "-dm-sheet", "electricityPrice", "-dm-settings-price", "invalid"])
        XCTAssertTrue(app.element(withIdentifier: "price-invalid").waitForExistence(timeout: 20), "A period that makes no sense is pointed out")
        XCTAssertEqual(app.element(withIdentifier: SID.periodRateField("price", 0)).value as? String, "abc")
    }

    /// The app is told a change did not reach the hub, and the hub made it all the same (a
    /// request that timed out may have been carried out). Once the hub's own news of that price
    /// is in, nothing is left to report or to send again, whichever of the two came first.
    @MainActor
    func testAChangeTheHubMadeAfterAllIsNotLeftMarkedAsFailed() {
        for state in ["save-lost", "save-late"] {
            let app = launch(["-dm-demo", "-dm-sheet", "electricityPrice", "-dm-settings-price", state])
            let timeOfUse = app.buttons[SID.mode("price", "time-of-use")]
            XCTAssertTrue(timeOfUse.waitForExistence(timeout: 20))
            XCTAssertTrue(wait(upTo: 10) { timeOfUse.isSelected }, "\(state): the editor shows the price the hub now has")
            XCTAssertTrue(app.element(withIdentifier: SID.periodRateField("price", 0)).waitForExistence(timeout: 5))
            XCTAssertTrue(wait(upTo: 10) { !app.element(withIdentifier: "price-save-error").exists }, "\(state): a change that was made is not said to have failed")
            attachScreenshot(of: app, named: "price-\(state)")
            app.terminate()
        }
    }

    /// "One rate" puts the periods away for the session, as the dashboard's `lastTou` outlives its
    /// settings dialog: "Time of use" brings them back in a sheet opened anew, and in the editor
    /// under "Advanced settings", which was not on screen when they were put away.
    @MainActor
    func testPeriodsPutAwayComeBackInWhicheverEditorAsksNext() {
        let sheet = "price", inline = "settings-price"
        let app = launch(["-dm-demo", "-dm-tab", "settings", "-dm-settings-advanced", "closed", "-dm-sheet", "electricityPrice"])
        XCTAssertTrue(app.element(withIdentifier: SID.priceSheet).waitForExistence(timeout: 20))
        let flat = app.buttons[SID.mode(sheet, "flat")]
        let timeOfUse = app.buttons[SID.mode(sheet, "time-of-use")]
        let second = app.element(withIdentifier: SID.periodRateField(sheet, 1))
        let done = app.buttons[SID.priceDone]
        XCTAssertTrue(wait(upTo: 10) { flat.exists && flat.isSelected }, "The demo hub opens with one rate")

        // Two periods, back to one rate, and the sheet is closed.
        timeOfUse.tap()
        XCTAssertTrue(app.element(withIdentifier: SID.periodRateField(sheet, 0)).waitForExistence(timeout: 10))
        XCTAssertFalse(second.exists, "Time of use starts with one period")
        let add = app.buttons[SID.addPeriod(sheet)]
        reveal(add, in: app, screen: SID.priceSheet, underTabs: false)
        add.tap()
        XCTAssertTrue(second.waitForExistence(timeout: 10), "A second period")
        reveal(flat, in: app, screen: SID.priceSheet, underTabs: false)
        flat.tap()
        XCTAssertTrue(wait(upTo: 10) { flat.isSelected && !second.exists }, "One rate again")
        done.tap()
        XCTAssertTrue(wait(upTo: 5) { !app.element(withIdentifier: SID.priceSheet).exists })

        // A sheet opened anew brings both back.
        let change = app.buttons[SID.priceButton]
        reveal(change, in: app)
        change.tap()
        XCTAssertTrue(app.element(withIdentifier: SID.priceSheet).waitForExistence(timeout: 5))
        XCTAssertTrue(wait(upTo: 10) { flat.exists && flat.isSelected })
        timeOfUse.tap()
        XCTAssertTrue(second.waitForExistence(timeout: 10), "Both periods are back in a new sheet")
        XCTAssertTrue(app.buttons["Remove 4 pm to 9 pm"].exists && app.buttons["Remove 9 pm to 10 pm"].exists)
        attachScreenshot(of: app, named: "price-periods-remembered")
        flat.tap()
        XCTAssertTrue(wait(upTo: 10) { flat.isSelected && !second.exists })
        done.tap()
        XCTAssertTrue(wait(upTo: 5) { !app.element(withIdentifier: SID.priceSheet).exists })

        // So does the editor in Settings, made only now.
        let toggle = app.buttons[SID.advancedToggle]
        reveal(toggle, in: app)
        toggle.tap()
        let inlineFlat = app.buttons[SID.mode(inline, "flat")]
        let inlineTimeOfUse = app.buttons[SID.mode(inline, "time-of-use")]
        reveal(inlineTimeOfUse, in: app)
        XCTAssertTrue(wait(upTo: 10) { inlineFlat.isSelected })
        inlineTimeOfUse.tap()
        let inlineSecond = app.element(withIdentifier: SID.periodRateField(inline, 1))
        XCTAssertTrue(inlineSecond.waitForExistence(timeout: 10), "Both periods are back in Settings")
        attachScreenshot(of: app, named: "settings-periods-remembered")

        // Folded away again, so the next launch finds it as this one did.
        reveal(toggle, in: app)
        toggle.tap()
        XCTAssertTrue(wait(upTo: 5) { toggle.value as? String == "Collapsed" })
    }

    /// The same without a tap, both editors on screen at once: the one in Settings puts two
    /// periods away, the one in the sheet asks for them (`-dm-settings-price remembered`).
    @MainActor
    func testPeriodsPutAwayInSettingsComeBackInTheSheet() {
        let app = launch([
            "-dm-demo", "-dm-tab", "settings", "-dm-settings-advanced", "open", "-dm-sheet", "electricityPrice", "-dm-settings-price", "remembered",
        ])
        XCTAssertTrue(app.element(withIdentifier: SID.priceSheet).waitForExistence(timeout: 20))
        XCTAssertTrue(app.element(withIdentifier: SID.periodRateField("price", 1)).waitForExistence(timeout: 20), "Two periods, not the one a first switch starts with")
        XCTAssertTrue(app.buttons["Remove 4 pm to 9 pm"].exists && app.buttons["Remove 9 pm to 10 pm"].exists)
    }

    // MARK: - Add a device

    @MainActor
    func testTheAddDeviceSheetOffersABrowserLink() {
        let app = launch(["-dm-demo"])
        let add = app.buttons[ID.addDeviceButton]
        XCTAssertTrue(add.waitForExistence(timeout: 20))
        add.tap()
        XCTAssertTrue(app.element(withIdentifier: SID.addSheet).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Create device enrollments on the hub."].exists)
        for option in ["Windows command", "Desktop app (Windows / Mac)", "Mac / Linux command", "iPhone / iPad app"] {
            XCTAssertTrue(app.staticTexts[option].exists, "The hub's own choice is named: \(option)")
        }
        attachScreenshot(of: app, named: "add-device")

        // Made when the sheet opens, as text and as a QR code.
        let link = app.element(withIdentifier: SID.addLink)
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        XCTAssertTrue(link.label.hasPrefix(Self.linkPrefix), "got: \(link.label)")
        XCTAssertTrue(app.element(withIdentifier: SID.addQR).exists)
        XCTAssertTrue(app.buttons[SID.addCopy].exists && app.buttons[SID.addShare].exists)
        let first = link.label

        let renew = app.buttons[SID.addNewLink]
        reveal(renew, in: app, screen: SID.addSheet, underTabs: false)
        attachScreenshot(of: app, named: "add-device-link")
        renew.tap()
        XCTAssertTrue(wait(upTo: 10) { link.exists && link.label != first && link.label.hasPrefix(Self.linkPrefix) }, "A new link on request")

        app.buttons[SID.addDone].tap()
        XCTAssertTrue(wait(upTo: 5) { !app.element(withIdentifier: SID.addSheet).exists }, "Done closes the sheet")
    }

    @MainActor
    func testTheAddDeviceSheetSaysWhyThereIsNoLink() {
        var app = launch(["-dm-demo", "-dm-sheet", "addDevice", "-dm-settings-invite", "error"])
        let failure = app.element(withIdentifier: SID.addLinkError)
        XCTAssertTrue(failure.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Could not connect to the hub."].exists, "In the transport's words")
        XCTAssertFalse(app.element(withIdentifier: SID.addLink).exists)
        XCTAssertFalse(app.element(withIdentifier: SID.addQR).exists)
        app.terminate()

        app = launch(["-dm-demo", "-dm-sheet", "addDevice", "-dm-settings-invite", "noshare"])
        XCTAssertTrue(app.element(withIdentifier: SID.addLinkUnavailable).waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Create new invitations in the hub app or its local operator dashboard."].exists)
        XCTAssertFalse(app.element(withIdentifier: SID.addLink).exists)
        app.terminate()

        app = launch(["-dm-demo", "-dm-sheet", "addDevice", "-dm-settings-invite", "expired"])
        XCTAssertTrue(app.element(withIdentifier: SID.addLinkExpired).waitForExistence(timeout: 20))
        XCTAssertFalse(app.element(withIdentifier: SID.addLink).exists, "A link that lapsed is not left on show")
        XCTAssertTrue(app.buttons[SID.addNewLink].exists)
    }

    // MARK: - Large text

    /// At an accessibility text size every control is still there to be used.
    @MainActor
    func testTheScreensHoldAtALargeTextSize() {
        let large = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        var app = launch(["-dm-phase", "live", "-dm-tab", "settings"] + large)
        let disconnect = app.buttons[ID.disconnectButton]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 20))
        XCTAssertTrue(disconnect.isHittable)
        attachScreenshot(of: app, named: "large-settings")
        for identifier in [SID.linkButton, SID.priceButton, SID.hubIdentityButton, SID.advancedToggle, SID.licenseButton] {
            reveal(app.buttons[identifier], in: app)
        }
        attachScreenshot(of: app, named: "large-settings-end")
        app.terminate()

        app = launch(["-dm-demo", "-dm-sheet", "electricityPrice", "-dm-settings-price", "tou"] + large)
        XCTAssertTrue(app.element(withIdentifier: SID.periodRateField("price", 0)).waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons[SID.mode("price", "time-of-use")].isHittable)
        attachScreenshot(of: app, named: "large-price")
        app.terminate()

        app = launch(["-dm-demo", "-dm-sheet", "addDevice"] + large)
        XCTAssertTrue(app.element(withIdentifier: SID.addLink).waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons[SID.addDone].isHittable)
        attachScreenshot(of: app, named: "large-add-device")
    }
}
