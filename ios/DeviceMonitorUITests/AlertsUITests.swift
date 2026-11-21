import XCTest

/// The Alerts tab on the demo hub: what is firing, the log, the rules and channels editor, a
/// rule's screen. The demo opens with two alerts firing (the Home Server's disk, the Living Room
/// PC offline), a log of six entries and four rules.
///
/// Where a state needs typing or a hub that misbehaves, the app is started in it with a
/// `-dm-alerts-…` launch argument (listed at the top of AlertsDebugOptions.swift in the app).
final class AlertsUITests: XCTestCase {
    /// The identifiers these tests lean on.
    private enum AlertsID {
        static let screen = "screen-alerts"
        static let settingsButton = "alerts-settings-button"
        static let settingsScreen = "screen-alert-settings"
        static let ruleScreen = "screen-alert-rule"
        static let saveButton = "alerts-save-button"
        static let cancelButton = "alerts-cancel-button"
        static let discardConfirm = "alerts-discard-confirm"
        static let clearButton = "alerts-clear-log-button"
        static let clearConfirm = "alerts-clear-log-confirm"
        static let emptyLog = "alerts-log-empty"
        static let allClear = "alerts-all-clear"
        static let activePrefix = "alert-active-"
        static let eventPrefix = "alert-event-"
        static let ruleTogglePrefix = "alert-rule-toggle-"
        static let rulePrefix = "alert-rule-"
        static let addRuleButton = "alerts-add-rule-button"
        static let limitField = "alert-rule-limit-field"
        static let limitIssue = "alert-rule-limit-issue"
        static let deleteRule = "alert-rule-delete-button"
        static let deleteConfirm = "alert-rule-delete-confirm"
        static let topicIssue = "alerts-ntfy-topic-field-issue"
        static let testButton = "alerts-test-button"
        static let webhookSaved = "alerts-webhook-saved"
        static let webhookReplace = "alerts-webhook-replace-button"
        static let webhookField = "alerts-webhook-url-field"
        static let setPrice = "alerts-set-price-button"
        static let notifyToggle = "alerts-notify-toggle"
        static let blockedBanner = "alerts-blocked-banner"
        static let openSettings = "alerts-open-settings-button"
        static let saveError = "alerts-save-error"

        static func testResult(_ channel: String) -> String { "alerts-test-result-\(channel)" }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ arguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-demo", "-dm-tab", "alerts"] + arguments
        app.launch()
        return app
    }

    /// Every element whose identifier starts with `prefix`.
    @MainActor
    private func elements(in app: XCUIApplication, withPrefix prefix: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        let button = app.element(withIdentifier: AlertsID.settingsButton)
        XCTAssertTrue(button.waitForExistence(timeout: 20), "The Alerts tab has a button to the rules and channels")
        button.tap()
        XCTAssertTrue(app.element(withIdentifier: AlertsID.settingsScreen).waitForExistence(timeout: 10))
    }

    // MARK: The tab

    @MainActor
    func testTheTabShowsWhatIsFiringAndTheLog() {
        let app = launch()
        XCTAssertTrue(app.element(withIdentifier: AlertsID.screen).waitForExistence(timeout: 20))

        let active = elements(in: app, withPrefix: AlertsID.activePrefix)
        XCTAssertTrue(wait(upTo: 20) { active.count == 2 }, "Two alerts are firing in the demo, found \(active.count)")
        let labels = (0..<active.count).map { active.element(boundBy: $0).label }
        XCTAssertTrue(labels.contains { $0.contains("Living Room PC is offline") }, "Active: \(labels)")
        XCTAssertTrue(labels.contains { $0.contains("Home Server") && $0.contains("full") }, "Active: \(labels)")
        XCTAssertFalse(app.element(withIdentifier: AlertsID.allClear).exists)

        XCTAssertTrue(app.element(withIdentifier: AlertsID.clearButton).exists, "A log with entries can be cleared")
        XCTAssertGreaterThan(elements(in: app, withPrefix: AlertsID.eventPrefix).count, 0, "The log lists what fired and cleared")
        XCTAssertTrue(app.element(labelled: "Yesterday").exists || app.element(labelled: "Today").exists, "The log is grouped by day")
        attachScreenshot(of: app, named: "alerts")

        let tab = app.tabBars.buttons["Alerts"]
        XCTAssertTrue(wait(upTo: 10) { (tab.value as? String)?.contains("2") == true }, "Alerts badge: \(String(describing: tab.value))")
    }

    @MainActor
    func testAnAlertOffersItsDevicesHistory() {
        let app = launch()
        let active = elements(in: app, withPrefix: AlertsID.activePrefix)
        XCTAssertTrue(wait(upTo: 20) { active.count == 2 })
        let offline = active.matching(NSPredicate(format: "label CONTAINS %@", "Living Room PC")).firstMatch
        XCTAssertTrue(offline.exists)
        offline.tap()

        let history = app.element(labelled: "Show history")
        XCTAssertTrue(history.waitForExistence(timeout: 5), "Tapping an alert for a device offers its history")
        XCTAssertTrue(app.element(labelled: "Edit rule").exists, "…and the rule that raised it")
        attachScreenshot(of: app, named: "alert-menu")
        history.tap()
        XCTAssertTrue(app.element(withIdentifier: "screen-history").waitForExistence(timeout: 10), "Show history goes to the History tab")
        XCTAssertTrue(app.tabBars.buttons["History"].isSelected)
    }

    @MainActor
    func testAnAlertLeadsToTheRuleThatRaisedIt() {
        let app = launch()
        let active = elements(in: app, withPrefix: AlertsID.activePrefix)
        XCTAssertTrue(wait(upTo: 20) { active.count == 2 })
        active.matching(NSPredicate(format: "label CONTAINS %@", "Living Room PC")).firstMatch.tap()
        let edit = app.element(labelled: "Edit rule")
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()

        XCTAssertTrue(app.element(withIdentifier: AlertsID.ruleScreen).waitForExistence(timeout: 10), "Edit rule opens the rule, over the editor")
        XCTAssertTrue(app.element(withIdentifier: "alert-rule-summary").label.contains("Offline for 10 min"))
        XCTAssertTrue(app.navigationBars["Offline"].waitForExistence(timeout: 5), "The rule's screen carries its title")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.element(withIdentifier: AlertsID.settingsScreen).waitForExistence(timeout: 10), "Back leads to the editor")
    }

    @MainActor
    func testAnAlertThatFiresShowsAtOnceAndIsAnnounced() {
        // The demo hub's Gaming PC fills its D: drive for eight seconds; the probe tells what the
        // notifier made of it (nothing can answer the system's permission question here).
        let app = launch("-dm-alerts-probe", "-dm-alerts-script", "disk-alert")
        let active = elements(in: app, withPrefix: AlertsID.activePrefix)
        XCTAssertTrue(wait(upTo: 30) { active.count == 3 }, "A third alert fires while the tab is open, found \(active.count)")
        let fired = active.matching(NSPredicate(format: "label CONTAINS %@", "Gaming PC: disk D:")).firstMatch
        XCTAssertTrue(fired.exists)
        XCTAssertTrue(app.element(labelled: "Today").exists, "It is in today's log too")
        let tab = app.tabBars.buttons["Alerts"]
        XCTAssertTrue(wait(upTo: 10) { (tab.value as? String)?.contains("3") == true }, "Alerts badge: \(String(describing: tab.value))")
        attachScreenshot(of: app, named: "alerts-fired")

        let probe = app.element(withIdentifier: "debug-alerts-notifier")
        XCTAssertTrue(wait(upTo: 10) { probe.label.contains("notify: [Gaming PC: disk D:") }, "The notifier plans a notification for it: \(probe.label)")
        XCTAssertTrue(probe.label.contains("log: "), "…after going through the hub's log first: \(probe.label)")
        let log = probe.label.range(of: "log: "), live = probe.label.range(of: "live: Gaming PC")
        if let log, let live { XCTAssertTrue(log.lowerBound < live.lowerBound, "The log comes before live alerts: \(probe.label)") }

        // And clears by itself.
        XCTAssertTrue(wait(upTo: 40) { active.count == 2 }, "The alert clears when the disk has room again, found \(active.count)")
        XCTAssertTrue(wait(upTo: 10) { probe.label.contains("back under") }, "Its end is announced too: \(probe.label)")
    }

    @MainActor
    func testClearingTheLogAsksFirst() {
        let app = launch()
        let clear = app.element(withIdentifier: AlertsID.clearButton)
        XCTAssertTrue(clear.waitForExistence(timeout: 20))
        clear.tap()
        let confirm = app.element(withIdentifier: AlertsID.clearConfirm)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Clearing the log is confirmed first")
        attachScreenshot(of: app, named: "alerts-clear-confirm")
        confirm.tap()

        XCTAssertTrue(app.element(withIdentifier: AlertsID.emptyLog).waitForExistence(timeout: 10), "The log is empty afterwards")
        XCTAssertEqual(elements(in: app, withPrefix: AlertsID.eventPrefix).count, 0)
        XCTAssertEqual(elements(in: app, withPrefix: AlertsID.activePrefix).count, 2, "What is firing stays")
        XCTAssertFalse(clear.exists, "There is nothing left to clear")
    }

    @MainActor
    func testEveryStateOfTheListHasItsScreen() {
        for (state, identifier) in [
            ("loading", "alerts-loading"), ("error", "alerts-load-error"), ("empty", AlertsID.emptyLog),
            ("all-clear", AlertsID.allClear), ("no-rules", "alerts-no-rules"), ("kinds", "alert-event-sample-test"),
        ] {
            let app = launch("-dm-alerts-list", state)
            XCTAssertTrue(app.element(withIdentifier: identifier).waitForExistence(timeout: 20), "-dm-alerts-list \(state) shows \(identifier)")
            attachScreenshot(of: app, named: "alerts-\(state)")
            app.terminate()
        }
    }

    // MARK: Rules

    @MainActor
    func testARuleCanBeSwitchedOffAndSaved() {
        let app = launch()
        openSettings(app)
        let save = app.element(withIdentifier: AlertsID.saveButton)
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertFalse(save.isEnabled, "Nothing to save yet")
        XCTAssertFalse(app.element(withIdentifier: AlertsID.cancelButton).exists)

        let toggles = elements(in: app, withPrefix: AlertsID.ruleTogglePrefix)
        XCTAssertTrue(wait(upTo: 10) { toggles.count == 4 }, "The demo hub has four rules, found \(toggles.count)")
        let first = toggles.element(boundBy: 0)
        XCTAssertEqual(first.value as? String, "On")
        first.tap()
        XCTAssertTrue(wait(upTo: 5) { first.value as? String == "Off" })
        XCTAssertTrue(wait(upTo: 5) { save.isEnabled }, "An edit can be saved")
        XCTAssertTrue(app.element(withIdentifier: AlertsID.cancelButton).exists, "…or cancelled")
        attachScreenshot(of: app, named: "alert-settings-edited")

        save.tap()
        XCTAssertTrue(wait(upTo: 10) { save.exists && !save.isEnabled }, "Saved: nothing left to save")
        XCTAssertFalse(app.element(withIdentifier: AlertsID.saveError).exists)
        XCTAssertEqual(first.value as? String, "Off", "The hub kept the rule switched off")
        XCTAssertFalse(app.element(withIdentifier: AlertsID.cancelButton).exists)

        // The offline rule is off now, so the Living Room PC's alert is gone: one left firing.
        app.navigationBars.buttons.firstMatch.tap()
        let active = elements(in: app, withPrefix: AlertsID.activePrefix)
        XCTAssertTrue(wait(upTo: 10) { active.count == 1 }, "Switching the offline rule off ends its alert, found \(active.count)")
    }

    @MainActor
    func testCancelTakesTheEditsBack() {
        let app = launch()
        openSettings(app)
        let toggles = elements(in: app, withPrefix: AlertsID.ruleTogglePrefix)
        XCTAssertTrue(wait(upTo: 10) { toggles.count == 4 })
        let second = toggles.element(boundBy: 1)
        second.tap()
        XCTAssertTrue(wait(upTo: 5) { second.value as? String == "Off" })

        let cancel = app.element(withIdentifier: AlertsID.cancelButton)
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        let discard = app.element(withIdentifier: AlertsID.discardConfirm)
        XCTAssertTrue(discard.waitForExistence(timeout: 5), "Cancel asks before throwing edits away")
        discard.tap()

        XCTAssertTrue(wait(upTo: 5) { second.value as? String == "On" }, "The rule is on again")
        XCTAssertFalse(app.element(withIdentifier: AlertsID.saveButton).isEnabled)
        XCTAssertTrue(wait(upTo: 5) { !cancel.exists })
    }

    @MainActor
    func testAnEditedRuleIsValidatedBeforeItIsSent() {
        // The CPU temperature rule, opened with a limit the hub would refuse.
        let app = launch("-dm-alerts-rule", "cpuTemp", "-dm-alerts-script", "limit=500", "-dm-alerts-unit", "C")
        XCTAssertTrue(app.element(withIdentifier: AlertsID.ruleScreen).waitForExistence(timeout: 20))
        let issue = app.element(withIdentifier: AlertsID.limitIssue)
        XCTAssertTrue(issue.waitForExistence(timeout: 10), "A limit out of range is explained next to the field")
        XCTAssertTrue(issue.label.contains("The limit must be between 20°C and 150°C."), issue.label)
        let save = app.element(withIdentifier: AlertsID.saveButton)
        XCTAssertFalse(save.isEnabled, "Nothing invalid is sent")
        attachScreenshot(of: app, named: "alert-rule-invalid")

        // Put right by typing.
        let field = app.element(withIdentifier: AlertsID.limitField)
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "80")
        XCTAssertTrue(wait(upTo: 5) { !issue.exists }, "A limit in range has nothing to explain")
        XCTAssertTrue(wait(upTo: 5) { save.isEnabled })
        save.tap()
        XCTAssertTrue(wait(upTo: 10) { save.exists && !save.isEnabled })
        XCTAssertTrue(app.element(withIdentifier: "alert-rule-summary").label.contains("CPU temperature above 80°C"))
    }

    @MainActor
    func testAddingARuleOpensItWithItsDefaults() {
        let app = launch()
        openSettings(app)
        let add = app.element(withIdentifier: AlertsID.addRuleButton)
        XCTAssertTrue(app.scrollUp(app.element(withIdentifier: AlertsID.settingsScreen), until: add))
        add.tap()
        let power = app.element(labelled: "Power draw")
        XCTAssertTrue(power.waitForExistence(timeout: 5), "Add rule lists the kinds of rule")
        for kind in ["Offline", "CPU temperature", "GPU temperature", "CPU load", "GPU load", "Memory use", "Disk space used", "Electricity cost today"] {
            XCTAssertTrue(app.element(labelled: kind).exists, "\(kind) can be added")
        }
        power.tap()

        XCTAssertTrue(app.element(withIdentifier: AlertsID.ruleScreen).waitForExistence(timeout: 10), "A new rule opens for editing")
        XCTAssertTrue(app.element(withIdentifier: "alert-rule-summary").label.contains("Power draw above 500 W for 5 min"))
        XCTAssertTrue(app.element(withIdentifier: AlertsID.saveButton).isEnabled)
        attachScreenshot(of: app, named: "alert-rule-new")

        // And goes again.
        let delete = app.element(withIdentifier: AlertsID.deleteRule)
        XCTAssertTrue(app.scrollUp(app.element(withIdentifier: AlertsID.ruleScreen), until: delete))
        delete.tap()
        let confirm = app.element(withIdentifier: AlertsID.deleteConfirm)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Deleting a rule is confirmed first")
        confirm.tap()
        XCTAssertTrue(app.element(withIdentifier: AlertsID.settingsScreen).waitForExistence(timeout: 10), "Back in the editor")
        XCTAssertTrue(wait(upTo: 5) { self.elements(in: app, withPrefix: AlertsID.ruleTogglePrefix).count == 4 })
    }

    @MainActor
    func testTheCostRuleLeadsToTheElectricityPrice() {
        let app = launch("-dm-alerts-rule", "new:dailyCost", "-dm-alerts-price", "none")
        XCTAssertTrue(app.element(withIdentifier: AlertsID.ruleScreen).waitForExistence(timeout: 20))
        let price = app.element(withIdentifier: AlertsID.setPrice)
        XCTAssertTrue(price.waitForExistence(timeout: 10), "A cost rule without a price says what it needs")
        XCTAssertTrue(app.element(labelled: "Warning: Needs an electricity price. Until one is saved in Settings, this rule never fires.").exists)
        attachScreenshot(of: app, named: "alert-rule-needs-price")
        XCTAssertTrue(app.scrollUp(app.element(withIdentifier: AlertsID.ruleScreen), until: price))
        price.tap()
        XCTAssertTrue(app.element(withIdentifier: "screen-electricity-price").waitForExistence(timeout: 10), "…and opens the price sheet")
    }

    // MARK: Channels

    @MainActor
    func testATopicTheHubWouldRefuseIsExplained() {
        let app = launch("-dm-alerts-open", "settings", "-dm-alerts-script", "ntfy=on,topic=not!a!topic", "-dm-alerts-scroll", "channels")
        XCTAssertTrue(app.element(withIdentifier: AlertsID.settingsScreen).waitForExistence(timeout: 20))
        let issue = app.element(withIdentifier: AlertsID.topicIssue)
        XCTAssertTrue(issue.waitForExistence(timeout: 10))
        XCTAssertTrue(issue.label.contains("A topic is letters, digits, hyphens and underscores only."), issue.label)
        XCTAssertFalse(app.element(withIdentifier: AlertsID.saveButton).isEnabled, "Nothing invalid is sent")
        XCTAssertTrue(app.element(withIdentifier: AlertsID.cancelButton).exists)
        attachScreenshot(of: app, named: "alert-channels-invalid")
    }

    @MainActor
    func testASavedWebhookAddressIsNeverShownAgain() {
        let app = launch("-dm-alerts-open", "settings", "-dm-alerts-script", "webhook=on,url=https://chat.example/hooks/demo,save", "-dm-alerts-scroll", "channels")
        XCTAssertTrue(app.element(withIdentifier: AlertsID.settingsScreen).waitForExistence(timeout: 20))
        let saved = app.element(withIdentifier: AlertsID.webhookSaved)
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "After saving, the address is only said to be there")
        XCTAssertFalse(app.element(withIdentifier: AlertsID.webhookField).exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "chat.example")).firstMatch.exists)
        attachScreenshot(of: app, named: "alert-webhook-saved")

        let replace = app.element(withIdentifier: AlertsID.webhookReplace)
        XCTAssertTrue(app.scrollUp(app.element(withIdentifier: AlertsID.settingsScreen), until: replace))
        replace.tap()
        XCTAssertTrue(app.element(withIdentifier: AlertsID.webhookField).waitForExistence(timeout: 5), "Replace brings up an empty field")
    }

    @MainActor
    func testATestAlertReportsOnEveryChannel() {
        let app = launch("-dm-alerts-open", "settings", "-dm-alerts-scroll", "test")
        XCTAssertTrue(app.element(withIdentifier: AlertsID.settingsScreen).waitForExistence(timeout: 20))
        let send = app.element(withIdentifier: AlertsID.testButton)
        XCTAssertTrue(app.scrollUp(app.element(withIdentifier: AlertsID.settingsScreen), until: send))
        send.tap()

        let apps = app.element(withIdentifier: AlertsID.testResult("apps"))
        XCTAssertTrue(apps.waitForExistence(timeout: 15), "The hub's answer is shown channel by channel")
        XCTAssertEqual(apps.value as? String, "Sent")
        XCTAssertEqual(app.element(withIdentifier: AlertsID.testResult("ntfy")).value as? String, "Off")
        XCTAssertEqual(app.element(withIdentifier: AlertsID.testResult("webhook")).value as? String, "Off")
        attachScreenshot(of: app, named: "alert-test-result")
    }

    @MainActor
    func testASaveThatFailsSaysSoAndKeepsTheEdits() {
        let app = launch("-dm-alerts-open", "settings", "-dm-alerts-script", "resolved=off,save", "-dm-alerts-fail", "save")
        XCTAssertTrue(app.element(withIdentifier: AlertsID.settingsScreen).waitForExistence(timeout: 20))
        let error = app.element(withIdentifier: AlertsID.saveError)
        XCTAssertTrue(error.waitForExistence(timeout: 10), "A save the hub never answered is reported")
        XCTAssertTrue(app.element(withIdentifier: AlertsID.saveButton).isEnabled, "The edits are still there to send again")
        XCTAssertTrue(app.element(withIdentifier: AlertsID.cancelButton).exists)
        attachScreenshot(of: app, named: "alert-save-error")
    }

    // MARK: This device

    @MainActor
    func testNotificationsBlockedInSettingsLeadThere() {
        let app = launch("-dm-alerts-notify", "blocked")
        XCTAssertTrue(app.element(withIdentifier: AlertsID.blockedBanner).waitForExistence(timeout: 20), "The Alerts tab says when iOS is in the way")
        openSettings(app)
        XCTAssertTrue(app.element(withIdentifier: AlertsID.openSettings).waitForExistence(timeout: 5), "…and the editor leads to the Settings app")
        let toggle = app.element(withIdentifier: AlertsID.notifyToggle)
        XCTAssertTrue(toggle.exists)
        XCTAssertEqual(toggle.value as? String, "Off", "The switch does not claim what iOS forbids")
        attachScreenshot(of: app, named: "alert-notifications-blocked")
    }

    @MainActor
    func testTheEditorHoldsUpAtTheLargestTextSize() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-dm-demo", "-dm-tab", "alerts", "-dm-alerts-rule", "cpuTemp",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        XCTAssertTrue(app.element(withIdentifier: AlertsID.ruleScreen).waitForExistence(timeout: 20))
        XCTAssertTrue(app.element(withIdentifier: AlertsID.limitField).exists)
        let delete = app.element(withIdentifier: AlertsID.deleteRule)
        XCTAssertTrue(app.scrollUp(app.element(withIdentifier: AlertsID.ruleScreen), until: delete, swipes: 12), "Everything can be reached by scrolling")
        attachScreenshot(of: app, named: "alert-rule-largest-text")
    }
}
