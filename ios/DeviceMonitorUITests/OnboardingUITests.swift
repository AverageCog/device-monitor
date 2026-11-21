import XCTest

/// The first-run and system-state screens: pairing (scan or paste), connecting, hub unreachable,
/// access revoked. No hub is needed: every session is in memory (`-dm-phase`, see
/// DebugLaunchOptions in the app), and the states that take a camera or a tap to reach are asked
/// for with the feature's own launch arguments (OnboardingDebugOptions in the app).
///
/// Pairing with a real hub, the demo, "Forget hub" and "Pair again" are in HubFlowUITests and
/// DemoFlowUITests.
final class OnboardingUITests: XCTestCase {
    /// Identifiers of these screens beyond the ones in `ID` (UITestSupport.swift).
    private enum OnboardingID {
        static let scanButton = "pair-scan-button"
        static let scanUnavailable = "pair-scan-unavailable"
        static let pasteButton = "pair-paste-button"
        static let clearButton = "pair-clear-button"
        static let invitationHub = "pair-invitation-hub"
        static let scanner = "screen-pair-scanner"
        static let scannerClose = "scanner-close-button"
        static let scannerInstruction = "scanner-instruction"
        static let scannerMessage = "scanner-message"
        static let scannerTorch = "scanner-torch-button"
        static let scannerNotice = "scanner-notice"
        static let scannerSettings = "scanner-settings-button"
        static let scannerPaste = "scanner-paste-button"
        static let connectingStatus = "connecting-status"
        static let unreachableReason = "unreachable-reason"
        static let revokedRetry = "revoked-retry-button"
    }

    /// Shaped like an invitation's code; no hub issued it.
    private static let code = String(repeating: "a", count: 43)
    private static let invitation = "https://hub.example/mobile#join=" + code

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

    // MARK: - Pairing

    @MainActor
    func testThePairingScreenSaysWhatToDoAndOffersBothWays() {
        let app = launch(["-dm-phase", "onboarding"])
        XCTAssertTrue(app.element(withIdentifier: ID.onboarding).waitForExistence(timeout: 20))

        XCTAssertTrue(app.staticTexts["Device Monitor"].exists, "The product's name is on the first screen")
        XCTAssertTrue(app.staticTexts["CONNECT TO YOUR HUB"].exists || app.staticTexts["Connect to your hub"].exists)
        XCTAssertTrue(
            app.element(labelled: "Step 1: On the computer that hosts Device Monitor, open the plus button, then iPhone / iPad app.").exists,
            "The first step says where the invitation is")

        let scan = app.buttons[OnboardingID.scanButton]
        XCTAssertTrue(scan.exists)
        XCTAssertEqual(scan.label, "Scan invitation", "The hub's dashboard sends people to this wording")
        // A simulator has no camera: the button is then off, and says why.
        XCTAssertTrue(scan.isEnabled || app.element(withIdentifier: OnboardingID.scanUnavailable).exists)

        XCTAssertTrue(app.element(withIdentifier: ID.invitationField).exists)
        XCTAssertTrue(app.element(withIdentifier: OnboardingID.pasteButton).exists, "The system's Paste button is beside the field")
        let name = app.element(withIdentifier: ID.nameField)
        XCTAssertTrue(name.exists)
        XCTAssertFalse((name.value as? String ?? "").isEmpty, "The device's name is suggested")
        XCTAssertFalse(app.buttons[ID.connectButton].isEnabled, "Nothing to connect with yet")
        XCTAssertTrue(app.buttons[ID.demoButton].exists)
        XCTAssertFalse(app.element(withIdentifier: ID.pairError).exists)
        attachScreenshot(of: app, named: "onboarding-first-run")
    }

    @MainActor
    func testAnInvitationNamesItsHubBeforeConnecting() {
        let app = launch(["-dm-phase", "onboarding", "-dm-invitation", Self.invitation, "-dm-name", "Test-phone"])
        let hub = app.element(withIdentifier: OnboardingID.invitationHub)
        XCTAssertTrue(hub.waitForExistence(timeout: 20), "A well-formed invitation shows the hub it is for")
        XCTAssertEqual(hub.label, "Invitation for https://hub.example")
        XCTAssertFalse(hub.label.contains(Self.code), "The code is never shown")
        XCTAssertTrue(app.buttons[ID.connectButton].isEnabled)
        XCTAssertEqual(app.element(withIdentifier: ID.nameField).value as? String, "Test-phone", "-dm-name pre-fills the name")
        attachScreenshot(of: app, named: "onboarding-invitation")

        app.buttons[OnboardingID.clearButton].tap()
        XCTAssertTrue(wait(upTo: 5) { !hub.exists }, "Clearing the field takes the hub away")
        XCTAssertFalse(app.buttons[ID.connectButton].isEnabled)
    }

    @MainActor
    func testEditingARefusedInvitationTakesItsErrorAway() {
        // A desktop invitation: refused on the spot, without asking any hub.
        let app = launch(["-dm-phase", "onboarding", "-dm-invitation", "https://hub.example/pair#join=" + Self.code])
        let connect = app.buttons[ID.connectButton]
        XCTAssertTrue(connect.waitForExistence(timeout: 20))
        XCTAssertFalse(app.element(withIdentifier: ID.pairError).exists, "Nothing is judged before Connect")
        connect.tap()

        let error = app.element(withIdentifier: ID.pairError)
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertEqual(error.label, "This invitation is for a computer. On the hub, choose + → iPhone / iPad app and use that invitation instead.")
        attachScreenshot(of: app, named: "onboarding-refused")

        let field = app.element(withIdentifier: ID.invitationField)
        field.tap()
        field.typeText("x")
        XCTAssertTrue(wait(upTo: 5) { !error.exists }, "The error was about the text as it was")
        XCTAssertTrue(app.element(withIdentifier: ID.onboarding).exists)
    }

    @MainActor
    func testTheKeyboardLeavesConnectInReach() {
        let app = launch(["-dm-phase", "onboarding", "-dm-invitation", Self.invitation])
        let name = app.element(withIdentifier: ID.nameField)
        XCTAssertTrue(name.waitForExistence(timeout: 20))
        name.tap()

        let connect = app.buttons[ID.connectButton]
        XCTAssertTrue(wait(upTo: 8) { connect.exists && connect.isHittable }, "Connect can be tapped while a field has the keyboard")
        // With a hardware keyboard attached to the simulator there is no keyboard on screen.
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            XCTAssertTrue(
                wait(upTo: 5) { connect.frame.maxY <= keyboard.frame.minY + 1 },
                "Connect is above the keyboard: \(connect.frame) against \(keyboard.frame)")
        }
        attachScreenshot(of: app, named: "onboarding-keyboard")
    }

    @MainActor
    func testTheKeyboardLeavesConnectInReachAtALargeTextSize() {
        let app = launch(["-dm-phase", "onboarding", "-dm-invitation", Self.invitation, "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        let name = app.element(withIdentifier: ID.nameField)
        XCTAssertTrue(name.waitForExistence(timeout: 20))
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(app.scrollUp(scroll, until: name, swipes: 8), "The name field can be scrolled into view")
        name.tap()

        // From the name down to Connect fits over the keyboard at this size, so both are on show.
        let connect = app.buttons[ID.connectButton]
        XCTAssertTrue(wait(upTo: 8) { connect.exists && connect.isHittable && name.isHittable }, "Connect and the field being typed in are both on show")
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            XCTAssertTrue(
                wait(upTo: 5) { connect.frame.maxY <= keyboard.frame.minY + 1 },
                "Connect is above the keyboard: \(connect.frame) against \(keyboard.frame)")
        }
        attachScreenshot(of: app, named: "onboarding-keyboard-large-text")
    }

    @MainActor
    func testATapAnywhereInAFieldsBoxGivesItTheKeyboard() {
        let app = launch(["-dm-phase", "onboarding"])
        let field = app.element(withIdentifier: ID.invitationField)
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        let connect = app.buttons[ID.connectButton]
        XCTAssertFalse(connect.isEnabled, "The field starts empty")

        // The element is the line of text; the box around it is 44 points tall and has 12
        // points of padding at the side. A tap in that padding, level with the box's upper
        // part, misses the text itself.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: -8, dy: -10)).tap()
        // With a hardware keyboard attached to the simulator no keyboard shows; typing works either way.
        wait(upTo: 3) { app.keyboards.firstMatch.exists }
        app.typeText("x")
        XCTAssertTrue(wait(upTo: 5) { connect.isEnabled }, "The invitation field took the keyboard and the text")
        XCTAssertTrue(app.buttons[OnboardingID.clearButton].exists)

        let name = app.element(withIdentifier: ID.nameField)
        let before = name.value as? String ?? ""
        // The name field's element is its whole box: its lower left corner is padding.
        name.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 1)).withOffset(CGVector(dx: 4, dy: -3)).tap()
        // The keyboard is up already; the focus moves a moment after the tap.
        wait(upTo: 2) { false }
        app.typeText("y")
        XCTAssertTrue(wait(upTo: 5) { (name.value as? String ?? "") != before }, "The name field took the keyboard and the text")
    }

    @MainActor
    func testThePairingScreenScrollsAtTheLargestTextSize() {
        let app = launch(["-dm-phase", "onboarding", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.element(withIdentifier: ID.onboarding).waitForExistence(timeout: 20))
        attachScreenshot(of: app, named: "onboarding-xxxl-top")
        let scroll = app.scrollViews.firstMatch
        for identifier in [ID.invitationField, ID.nameField, ID.connectButton, ID.demoButton] {
            let element = app.element(withIdentifier: identifier)
            XCTAssertTrue(element.exists, "Missing \(identifier)")
            XCTAssertTrue(app.scrollUp(scroll, until: element, swipes: 14), "\(identifier) can be scrolled into view")
        }
        attachScreenshot(of: app, named: "onboarding-xxxl-end")
    }

    // MARK: - Scanner

    @MainActor
    func testTheScannerSaysWhatToDoWithoutCameraAccess() {
        let app = launch(["-dm-phase", "onboarding", "-dm-onboarding-scanner", "denied"])
        XCTAssertTrue(app.element(withIdentifier: OnboardingID.scanner).waitForExistence(timeout: 20), "-dm-onboarding-scanner opens the scanner")
        XCTAssertTrue(app.element(withIdentifier: OnboardingID.scannerNotice).waitForExistence(timeout: 5), "No picture: a notice instead")
        XCTAssertTrue(app.staticTexts["Camera access is off"].exists)
        XCTAssertTrue(app.buttons[OnboardingID.scannerSettings].exists, "A denied camera is changed in Settings")
        attachScreenshot(of: app, named: "scanner-denied")

        app.buttons[OnboardingID.scannerPaste].tap()
        XCTAssertTrue(wait(upTo: 8) { !app.element(withIdentifier: OnboardingID.scanner).exists }, "Paste instead closes the scanner")
        XCTAssertTrue(app.element(withIdentifier: ID.invitationField).exists)
    }

    @MainActor
    func testTheScannerRefusesOtherCodesInTheTransportsWordsAndGoesOn() {
        let expected = [
            "desktop": "This invitation is for a computer. On the hub, choose + → iPhone / iPad app and use that invitation instead.",
            "browser": "This link opens the dashboard in a browser. On the hub, choose + → iPhone / iPad app and use that invitation instead.",
            "other": "Scan or paste the complete invitation shown on the hub.",
        ]
        for (kind, text) in expected.sorted(by: { $0.key < $1.key }) {
            let app = launch(["-dm-phase", "onboarding", "-dm-onboarding-scanner", kind])
            let message = app.element(withIdentifier: OnboardingID.scannerMessage)
            XCTAssertTrue(message.waitForExistence(timeout: 20), "A \(kind) code is explained")
            XCTAssertTrue(message.label.contains(text), "\(kind): \(message.label)")
            XCTAssertTrue(app.element(withIdentifier: OnboardingID.scannerInstruction).exists, "The scanner stays up")
            XCTAssertTrue(app.element(withIdentifier: OnboardingID.scannerTorch).exists, "The torch is offered while scanning")
            XCTAssertEqual(app.sessionState?.phase, "onboarding")
            XCTAssertFalse(app.element(withIdentifier: ID.pairError).exists, "Nothing was tried with that code")
            attachScreenshot(of: app, named: "scanner-\(kind)")

            app.buttons[OnboardingID.scannerClose].tap()
            XCTAssertTrue(wait(upTo: 8) { !app.element(withIdentifier: OnboardingID.scanner).exists }, "Close closes the scanner")
            app.terminate()
        }
    }

    @MainActor
    func testAScannedInvitationWaitsForConnect() {
        // The simulated scan is of an invitation for a hub that does not exist: everything up to
        // the hub's answer is real.
        let app = launch(["-dm-phase", "onboarding", "-dm-onboarding-scanner", "accept"])
        XCTAssertTrue(app.element(withIdentifier: OnboardingID.scanner).waitForExistence(timeout: 20))
        XCTAssertTrue(wait(upTo: 15) { !app.element(withIdentifier: OnboardingID.scanner).exists }, "A good invitation closes the scanner by itself")

        let hub = app.element(withIdentifier: OnboardingID.invitationHub)
        XCTAssertTrue(hub.waitForExistence(timeout: 5), "The scanned invitation is in the field")
        XCTAssertEqual(hub.label, "Invitation for https://hub.demo.example")

        // An invitation works once and the hub cannot rename a phone afterwards: nothing is
        // sent until the hub and the name have been seen and Connect is pressed.
        let connect = app.buttons[ID.connectButton]
        let error = app.element(withIdentifier: ID.pairError)
        XCTAssertFalse(error.waitForExistence(timeout: 6), "A scan does not pair by itself")
        XCTAssertTrue(connect.isEnabled)
        XCTAssertEqual(connect.label, "Connect", "Nothing is under way")
        XCTAssertTrue(connect.isHittable, "Connect is on show once the scanner has gone")
        XCTAssertFalse((app.element(withIdentifier: ID.nameField).value as? String ?? "").isEmpty, "The name is there to be changed first")
        attachScreenshot(of: app, named: "scanner-accepted")

        connect.tap()
        XCTAssertTrue(error.waitForExistence(timeout: 45), "Connect pairs with the scanned invitation, and fails: there is no such hub")
        XCTAssertFalse(error.label.contains(Self.code), "No message quotes the code")
        XCTAssertEqual(app.sessionState?.phase, "onboarding")
        XCTAssertTrue(connect.isEnabled, "The invitation is kept for another try: it was not used")
    }

    @MainActor
    func testTheViewfinderWindowStaysClearAtTheLargestTextSize() {
        let app = launch(["-dm-phase", "onboarding", "-dm-onboarding-scanner", "browser", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let message = app.element(withIdentifier: OnboardingID.scannerMessage)
        XCTAssertTrue(message.waitForExistence(timeout: 20))
        XCTAssertTrue(message.label.contains("This link opens the dashboard in a browser."), "All of the explanation is read out, whatever part of it is on show")
        let torch = app.element(withIdentifier: OnboardingID.scannerTorch)
        XCTAssertTrue(torch.exists)
        // The window is drawn, not an element: it has the room between the navigation bar (or
        // the instruction) and the explanation, and the layout never gives it less than 160 points.
        let top = [app.navigationBars.firstMatch, app.element(withIdentifier: OnboardingID.scannerInstruction)]
            .filter { $0.exists }.map { $0.frame.maxY }.max() ?? 0
        XCTAssertGreaterThanOrEqual(message.frame.minY - top, 160, "Room for the window above the explanation: \(message.frame) under \(top)")
        XCTAssertLessThanOrEqual(message.frame.maxY, torch.frame.minY, "The explanation ends above the torch")
        attachScreenshot(of: app, named: "scanner-browser-xxxl")
    }

    // MARK: - Connecting

    @MainActor
    func testConnectingNamesTheHubAndSaysWhatItWaitsFor() {
        let app = launch(["-dm-phase", "connecting", "-dm-onboarding-slow", "1"])
        XCTAssertTrue(app.element(withIdentifier: ID.connecting).waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Connecting to hub…"].exists)
        XCTAssertTrue(app.element(labelled: "Hub https://hub.demo.example").exists, "The hub being waited for is named")
        let status = app.element(withIdentifier: OnboardingID.connectingStatus)
        XCTAssertTrue(status.waitForExistence(timeout: 5), "A slow connection is explained")
        XCTAssertTrue(status.label.hasPrefix("Still waiting for the hub to answer."), status.label)
        XCTAssertEqual(app.sessionState?.phase, "connecting")
        attachScreenshot(of: app, named: "connecting-slow")
    }

    // MARK: - Unreachable

    @MainActor
    func testUnreachableSaysWhyKeepsTryingAndAsksBeforeForgettingTheHub() {
        let app = launch(["-dm-phase", "unreachable"])
        XCTAssertTrue(app.element(withIdentifier: ID.unreachable).waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Can't reach the hub"].exists)
        let reason = app.element(withIdentifier: OnboardingID.unreachableReason)
        XCTAssertTrue(reason.waitForExistence(timeout: 10), "The transport's reason is shown")
        XCTAssertFalse(reason.label.isEmpty)
        XCTAssertTrue(
            app.staticTexts["Certificate renewals reconnect automatically. If you replaced the hub or revoked this device, use a fresh invitation."].exists)
        attachScreenshot(of: app, named: "unreachable")

        // Try again: the hub is still away, and the screen stays.
        let retry = app.buttons[ID.unreachableRetry]
        retry.tap()
        XCTAssertTrue(wait(upTo: 10) { retry.isEnabled }, "The attempt resolves and the button comes back")
        XCTAssertEqual(app.sessionState?.phase, "unreachable")

        // Change setup asks first, and backing out changes nothing.
        app.buttons[ID.unreachableChange].tap()
        XCTAssertTrue(app.buttons["Forget hub"].waitForExistence(timeout: 5))
        attachScreenshot(of: app, named: "unreachable-confirm")
        let cancel = app.buttons["Cancel"]
        if cancel.exists {
            cancel.tap()
        } else {
            // Where the question is a popover, there is nothing to say no with but a tap outside it.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        }
        XCTAssertTrue(wait(upTo: 5) { !app.buttons["Forget hub"].exists })
        XCTAssertTrue(app.element(withIdentifier: ID.unreachable).exists)
        XCTAssertEqual(app.sessionState?.hub, "https://hub.demo.example", "The pairing is untouched")
    }

    // MARK: - Revoked

    @MainActor
    func testRevokedSaysHowToGetAFreshInvitationAndCanAskTheHubAgain() {
        let app = launch(["-dm-phase", "revoked"])
        XCTAssertTrue(app.element(withIdentifier: ID.revoked).waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["The verified hub no longer accepts this enrollment."].exists)
        XCTAssertTrue(app.element(labelled: "Hub https://hub.demo.example").exists)
        XCTAssertTrue(
            app.element(labelled: "Step 1: On the computer that hosts Device Monitor, open the plus button, then iPhone / iPad app.").exists,
            "The way to a fresh invitation is spelled out")
        XCTAssertEqual(app.buttons[ID.revokedPairAgain].label, "Pair again")
        attachScreenshot(of: app, named: "revoked")

        // The hub still refuses: asking again ends where it began, without ever showing the tabs.
        app.buttons[OnboardingID.revokedRetry].tap()
        waitForSession(of: app, "the hub has refused again") { $0.phase == "revoked" && $0.connection == "unauthorized" }
        XCTAssertTrue(app.element(withIdentifier: ID.revoked).waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
    }
}
