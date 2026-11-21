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
        static let ruleSummary = "alert-rule-summary"
        static let limitIssue = "alert-rule-limit-issue"
        static let deleteRule = "alert-rule-delete-button"
        static let deleteConfirm = "alert-rule-delete-confirm"
        static let ntfyToggle = "alerts-ntfy-toggle"
        static let topicField = "alerts-ntfy-topic-field"
        static let topicIssue = "alerts-ntfy-topic-field-issue"
        static let hasErrors = "alerts-has-errors"
        static let resolvedToggle = "alerts-notify-resolved-toggle"
        static let testButton = "alerts-test-button"
        static let webhookSaved = "alerts-webhook-saved"
        static let webhookReplace = "alerts-webhook-replace-button"
        static let webhookField = "alerts-webhook-url-field"
        static let setPrice = "alerts-set-price-button"
        static let notifyToggle = "alerts-notify-toggle"
        static let notifyBanner = "alerts-notify-banner"
        static let blockedBanner = "alerts-blocked-banner"
        static let blockedDismiss = "alerts-blocked-dismiss-button"
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

    /// Without `-dm-demo`: a session "paired" with a demo hub, which the app treats as a real one.
    @MainActor
    private func launchPaired(_ arguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-dm-phase", "live", "-dm-tab", "alerts"] + arguments
        app.launch()
        return app
    }

    /// Save, as the button it is. The toolbar wraps it in an element that carries the same
    /// identifier and is enabled whatever the button is, so a lookup by identifier alone finds
    /// the wrong one of the two.
    @MainActor
    private func saveButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons[AlertsID.saveButton]
    }

    /// Whether a switch is on; nil for a value that is neither. A switch reports "1" or "0" to a
    /// test, whatever the app has VoiceOver say for it, and both spellings are read here.
    @MainActor
    private func isOn(_ toggle: XCUIElement) -> Bool? {
        switch toggle.value as? String {
        case "1", "On": true
        case "0", "Off": false
        default: nil
        }
    }

    /// The button of a confirmation that goes ahead. By its identifier; and should the system
    /// not have been handed one (it is for a dialog made after a test first looked at the app,
    /// which a test that found the button to tap has done), by its label, among the buttons
    /// that are not the one that asked.
    @MainActor
    private func confirmation(in app: XCUIApplication, _ identifier: String, labelled label: String, askedBy asker: String) -> XCUIElement {
        let byIdentifier = app.element(withIdentifier: identifier)
        if byIdentifier.waitForExistence(timeout: 5) { return byIdentifier }
        return app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", label, asker)).firstMatch
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
        XCTAssertTrue(app.element(withIdentifier: AlertsID.ruleSummary).label.contains("Offline for 10 min"))
        XCTAssertTrue(app.navigationBars["Offline"].waitForExistence(timeout: 5), "The rule's screen carries its title")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.element(withIdentifier: AlertsID.settingsScreen).waitForExistence(timeout: 10), "Back leads to the editor")
    }

    @MainActor
    func testAnAlertThatFiresShowsAtOnceAndIsAnnounced() {
        // The demo hub's Gaming PC fills its D: drive for eight seconds; the probe tells what the
        // notifier made of it (nothing can answer the system's permission question here).
        // "Notify on this iPhone" is on for this run, to see that a demo keeps its alerts to itself.
        let app = launch("-dm-alerts-probe", "-dm-alerts-script", "disk-alert", "-dm.notifications", "YES")
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
        XCTAssertTrue(probe.label.contains("kept back, a demo"), "A demo plans its notifications and keeps them back: \(probe.label)")
        XCTAssertFalse(probe.label.contains("posted"), "Nothing about made-up devices goes to the system: \(probe.label)")
    }

    @MainActor
    func testClearingTheLogAsksFirst() {
        let app = launch()
        let clear = app.element(withIdentifier: AlertsID.clearButton)
        XCTAssertTrue(clear.waitForExistence(timeout: 20))
        clear.tap()
        let confirm = confirmation(in: app, AlertsID.clearConfirm, labelled: "Clear log", askedBy: AlertsID.clearButton)
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
        let save = saveButton(app)
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertFalse(save.isEnabled, "Nothing to save yet")
        XCTAssertFalse(app.element(withIdentifier: AlertsID.cancelButton).exists)

        let toggles = elements(in: app, withPrefix: AlertsID.ruleTogglePrefix)
        XCTAssertTrue(wait(upTo: 10) { toggles.count == 4 }, "The demo hub has four rules, found \(toggles.count)")
        let first = toggles.element(boundBy: 0)
        XCTAssertEqual(isOn(first), true, "Switch value: \(String(describing: first.value))")
        first.tap()
        XCTAssertTrue(wait(upTo: 5) { self.isOn(first) == false }, "Switch value: \(String(describing: first.value))")
        XCTAssertTrue(wait(upTo: 5) { save.isEnabled }, "An edit can be saved")
        XCTAssertTrue(app.element(withIdentifier: AlertsID.cancelButton).exists, "…or cancelled")
        attachScreenshot(of: app, named: "alert-settings-edited")

        save.tap()
        XCTAssertTrue(wait(upTo: 10) { save.exists && !save.isEnabled }, "Saved: nothing left to save")
        XCTAssertFalse(app.element(withIdentifier: AlertsID.saveError).exists)
        XCTAssertEqual(isOn(first), false, "The hub kept the rule switched off")
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
        XCTAssertTrue(wait(upTo: 5) { self.isOn(second) == false }, "Switch value: \(String(describing: second.value))")

        let cancel = app.element(withIdentifier: AlertsID.cancelButton)
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        let discard = confirmation(in: app, AlertsID.discardConfirm, labelled: "Discard changes", askedBy: AlertsID.cancelButton)
        XCTAssertTrue(discard.waitForExistence(timeout: 5), "Cancel asks before throwing edits away")
        discard.tap()

        XCTAssertTrue(wait(upTo: 5) { self.isOn(second) == true }, "The rule is on again")
        XCTAssertFalse(saveButton(app).isEnabled)
        XCTAssertTrue(wait(upTo: 5) { !cancel.exists })
    }

    @MainActor
    func testALimitTheHubWouldRefuseIsExplained() {
        // The CPU temperature rule, opened with a limit out of the hub's range.
        let app = launch("-dm-alerts-rule", "cpuTemp", "-dm-alerts-script", "limit=500", "-dm-alerts-unit", "C")
        XCTAssertTrue(app.element(withIdentifier: AlertsID.ruleScreen).waitForExistence(timeout: 20))
        let issue = app.element(withIdentifier: AlertsID.limitIssue)
        XCTAssertTrue(issue.waitForExistence(timeout: 10), "A limit out of range is explained next to the field")
        XCTAssertTrue(issue.label.contains("The limit must be between 20°C and 150°C."), issue.label)
        let field = app.element(withIdentifier: AlertsID.limitField)
        XCTAssertEqual(field.label, "Limit", "The field says which it is")
        XCTAssertEqual(field.value as? String, "500 °C")
        XCTAssertEqual(app.element(withIdentifier: "alert-rule-minutes-field").label, "Duration in minutes")
        XCTAssertFalse(saveButton(app).isEnabled, "Nothing invalid is sent")
        attachScreenshot(of: app, named: "alert-rule-invalid")
    }

    @MainActor
    func testAnEditedRuleIsValidatedBeforeItIsSent() {
        // The same rule with its limit emptied, so that typing does not depend on where a tap
        // puts the caret in a right-aligned number.
        let app = launch("-dm-alerts-rule", "cpuTemp", "-dm-alerts-script", "limit=", "-dm-alerts-unit", "C")
        XCTAssertTrue(app.element(withIdentifier: AlertsID.ruleScreen).waitForExistence(timeout: 20))
        let issue = app.element(withIdentifier: AlertsID.limitIssue)
        XCTAssertTrue(issue.waitForExistence(timeout: 10), "A missing limit is asked for next to the field")
        XCTAssertTrue(issue.label.contains("Enter a limit between 20°C and 150°C."), issue.label)
        let save = saveButton(app)
        XCTAssertFalse(save.isEnabled, "Nothing invalid is sent")

        // Put right by typing.
        let field = app.element(withIdentifier: AlertsID.limitField)
        XCTAssertEqual(field.value as? String, "Empty")
        field.tap()
        field.typeText("80")
        XCTAssertTrue(wait(upTo: 5) { !issue.exists }, "A limit in range has nothing to explain")
        XCTAssertEqual(field.value as? String, "80 °C")
        XCTAssertTrue(wait(upTo: 5) { save.isEnabled })
        save.tap()
        XCTAssertTrue(wait(upTo: 10) { save.exists && !save.isEnabled }, "Saved: nothing left to save")
        XCTAssertTrue(app.element(withIdentifier: AlertsID.ruleSummary).label.contains("CPU temperature above 80°C"))
    }

    @MainActor
    func testALimitEnteredInFahrenheitStaysShortInCelsius() {
        // 195 °F, as the hub stores it. The field shows two decimals of it; the hub's own
        // wording, in the summary, whole degrees.
        let app = launch("-dm-alerts-rule", "cpuTemp", "-dm-alerts-script", "limit=90.55555555555556", "-dm-alerts-unit", "C")
        XCTAssertTrue(app.element(withIdentifier: AlertsID.ruleScreen).waitForExistence(timeout: 20))
        let field = app.element(withIdentifier: AlertsID.limitField)
        XCTAssertTrue(wait(upTo: 10) { field.value as? String == "90.56 °C" }, "Limit field: \(String(describing: field.value))")
        XCTAssertTrue(app.element(withIdentifier: AlertsID.ruleSummary).label.contains("CPU temperature above 91°C"))
        XCTAssertFalse(app.element(withIdentifier: AlertsID.limitIssue).exists)
        attachScreenshot(of: app, named: "alert-rule-long-decimal")
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
        XCTAssertTrue(app.element(withIdentifier: AlertsID.ruleSummary).label.contains("Power draw above 500 W for 5 min"))
        XCTAssertTrue(saveButton(app).isEnabled)
        attachScreenshot(of: app, named: "alert-rule-new")

        // And goes again.
        let delete = app.element(withIdentifier: AlertsID.deleteRule)
        XCTAssertTrue(app.scrollUp(app.element(withIdentifier: AlertsID.ruleScreen), until: delete))
        delete.tap()
        let confirm = confirmation(in: app, AlertsID.deleteConfirm, labelled: "Delete rule", askedBy: AlertsID.deleteRule)
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
        XCTAssertEqual(app.element(withIdentifier: AlertsID.topicField).label, "Topic", "The field says which it is")
        XCTAssertFalse(saveButton(app).isEnabled, "Nothing invalid is sent")
        XCTAssertTrue(app.element(withIdentifier: AlertsID.cancelButton).exists)
        attachScreenshot(of: app, named: "alert-channels-invalid")
    }

    @MainActor
    func testTheAppsChannelSaysWhereItsAlertsShow() {
        // The hub's field is `channels.desktop`, but no desktop app or dashboard does anything
        // with these alerts: the switch must not promise them there.
        let app = launch("-dm-alerts-open", "settings", "-dm-alerts-scroll", "channels")
        let apps = app.element(withIdentifier: "alerts-channel-apps-toggle")
        XCTAssertTrue(apps.waitForExistence(timeout: 20))
        XCTAssertTrue(apps.label.contains("iPhone and iPad"), apps.label)
        XCTAssertFalse(apps.label.localizedCaseInsensitiveContains("desktop"), apps.label)
    }

    @MainActor
    func testSwitchingAChannelOffTakesBackWhatTheHubWouldRefuse() {
        // A topic and a webhook address the hub would refuse, typed and then given up by
        // switching the channels off again. Their fields are gone with the switches, so nothing
        // of them may be left to keep Save from working.
        let app = launch(
            "-dm-alerts-open", "settings", "-dm-alerts-scroll", "channels",
            "-dm-alerts-script", "ntfy=on,topic=bad!,ntfy=off,webhook=on,url=foo,webhook=off,resolved=off"
        )
        XCTAssertTrue(app.element(withIdentifier: AlertsID.settingsScreen).waitForExistence(timeout: 20))
        let save = saveButton(app)
        XCTAssertTrue(wait(upTo: 15) { save.exists && save.isEnabled }, "The one edit that is left can be saved")
        XCTAssertFalse(app.element(withIdentifier: AlertsID.hasErrors).exists, "No error is left where it cannot be seen")
        XCTAssertFalse(app.element(withIdentifier: AlertsID.topicField).exists)
        XCTAssertFalse(app.element(withIdentifier: AlertsID.webhookField).exists)
        attachScreenshot(of: app, named: "alert-channels-given-up")

        // Switched on again, the topic is the hub's (none), not the one that was refused.
        let ntfy = app.element(withIdentifier: AlertsID.ntfyToggle)
        XCTAssertTrue(app.scrollUp(app.element(withIdentifier: AlertsID.settingsScreen), until: ntfy))
        ntfy.tap()
        let issue = app.element(withIdentifier: AlertsID.topicIssue)
        XCTAssertTrue(issue.waitForExistence(timeout: 5))
        XCTAssertTrue(issue.label.contains("Enter a topic, or ntfy stays off."), issue.label)
        XCTAssertTrue(save.isEnabled, "A channel without an address is a warning, not an error")
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
        let field = app.element(withIdentifier: AlertsID.webhookField)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Replace brings up an empty field")
        XCTAssertEqual(field.label, "Webhook URL")

        // Typed in and emptied again, to start over: the field stays.
        field.tap()
        field.typeText("h")
        XCTAssertTrue(app.element(withIdentifier: AlertsID.cancelButton).waitForExistence(timeout: 5), "A typed address is an edit")
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(wait(upTo: 5) { !app.element(withIdentifier: AlertsID.cancelButton).exists }, "Emptied, the draft is the hub's again")
        XCTAssertTrue(field.exists, "…and the field is still there to type in")
        XCTAssertFalse(saved.exists)
    }

    @MainActor
    func testTheReplaceFieldStaysWhenItIsEmptiedAgain() {
        // The same without a keyboard: saved, Replace, one character, none.
        let app = launch(
            "-dm-alerts-open", "settings", "-dm-alerts-scroll", "channels",
            "-dm-alerts-script", "webhook=on,url=https://chat.example/hooks/demo,save,replace=on,url=h,url="
        )
        XCTAssertTrue(app.element(withIdentifier: AlertsID.settingsScreen).waitForExistence(timeout: 20))
        XCTAssertTrue(app.element(withIdentifier: AlertsID.webhookField).waitForExistence(timeout: 15), "The field Replace brought up stays")
        XCTAssertFalse(app.element(withIdentifier: AlertsID.webhookSaved).exists)
        XCTAssertFalse(app.element(withIdentifier: AlertsID.cancelButton).exists, "Nothing is edited")
        attachScreenshot(of: app, named: "alert-webhook-replacing")
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
        XCTAssertTrue(saveButton(app).isEnabled, "The edits are still there to send again")
        XCTAssertTrue(app.element(withIdentifier: AlertsID.cancelButton).exists)
        attachScreenshot(of: app, named: "alert-save-error")
    }

    // MARK: This device

    @MainActor
    func testNotificationsBlockedInSettingsLeadThereOrAreGivenUp() {
        // iOS refuses, and "Notify on this iPhone" is still wanted.
        let app = launch("-dm-alerts-notify", "blocked", "-dm.notifications", "YES")
        let banner = app.element(withIdentifier: AlertsID.blockedBanner)
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "The Alerts tab says when iOS is in the way")
        attachScreenshot(of: app, named: "alert-notifications-blocked")

        // The switch is disabled for as long as iOS refuses, so the banner takes the wish back itself.
        let dismiss = app.element(withIdentifier: AlertsID.blockedDismiss)
        XCTAssertTrue(dismiss.exists, "The banner can be answered with a no")
        dismiss.tap()
        XCTAssertTrue(wait(upTo: 5) { !banner.exists }, "…and is gone then")

        openSettings(app)
        XCTAssertTrue(app.element(withIdentifier: AlertsID.openSettings).waitForExistence(timeout: 5), "The editor still leads to the Settings app")
        let toggle = app.element(withIdentifier: AlertsID.notifyToggle)
        XCTAssertTrue(toggle.exists)
        XCTAssertEqual(isOn(toggle), false, "The switch does not claim what iOS forbids")
        XCTAssertFalse(toggle.isEnabled)
    }

    @MainActor
    func testTheDemoDoesNotOfferNotifications() {
        // A demo's alerts are never shown as notifications, so it does not invite to them…
        let demo = launch("-dm-alerts-notify", "undecided")
        XCTAssertTrue(wait(upTo: 20) { self.elements(in: demo, withPrefix: AlertsID.activePrefix).count == 2 })
        XCTAssertFalse(demo.element(withIdentifier: AlertsID.notifyBanner).exists)
        demo.terminate()

        // …where a paired app does.
        let paired = launchPaired("-dm-alerts-notify", "undecided")
        XCTAssertTrue(paired.element(withIdentifier: AlertsID.notifyBanner).waitForExistence(timeout: 20))
        attachScreenshot(of: paired, named: "alert-notifications-offered")
    }

    // MARK: The hub goes away

    @MainActor
    func testADraftOutlivesAnOutage() {
        // An edit in the editor, then the demo hub is gone for twenty seconds: after ten the tabs
        // make way for the unreachable screen, and come back when the hub does.
        let app = launch("-dm-alerts-open", "settings", "-dm-alerts-script", "resolved=off", "-dm-then", "outage")
        XCTAssertTrue(app.element(withIdentifier: AlertsID.cancelButton).waitForExistence(timeout: 20), "The draft has an edit")
        XCTAssertTrue(app.element(withIdentifier: ID.unreachable).waitForExistence(timeout: 30), "The hub is away")
        // The tabs fade out as the unreachable screen fades in.
        XCTAssertTrue(wait(upTo: 5) { !app.element(withIdentifier: AlertsID.settingsScreen).exists }, "…and so are the tabs, the editor with them")

        XCTAssertTrue(app.element(withIdentifier: AlertsID.settingsScreen).waitForExistence(timeout: 40), "Back with the hub: the editor, not the list")
        XCTAssertTrue(app.element(withIdentifier: AlertsID.cancelButton).waitForExistence(timeout: 5), "…with the edit still in it")
        XCTAssertEqual(isOn(app.element(withIdentifier: AlertsID.resolvedToggle)), false)
        XCTAssertTrue(wait(upTo: 5) { self.saveButton(app).isEnabled }, "…and still to be saved")
        attachScreenshot(of: app, named: "alert-draft-after-outage")
    }

    @MainActor
    func testLeavingTheHubTakesItsNotificationsAlong() {
        // A paired session that disconnects as soon as it is live. Notification Centre cannot be
        // looked at from here, so the probe tells what the notifier did; with the hub gone it is
        // read on the demo's Alerts tab, the one place it is shown.
        let app = launchPaired("-dm-alerts-probe", "-dm-then", "disconnect")
        let demo = app.element(withIdentifier: ID.demoButton)
        XCTAssertTrue(demo.waitForExistence(timeout: 30), "Disconnected: back at onboarding")
        demo.tap()
        let tab = app.tabBars.buttons["Alerts"]
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()

        let probe = app.element(withIdentifier: "debug-alerts-notifier")
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        let left = probe.label.range(of: "hub: left, its notifications removed")
        XCTAssertNotNil(left, "What was posted about the hub goes with it: \(probe.label)")
        if let left, let up = probe.label.range(of: "stream: up") {
            XCTAssertTrue(up.lowerBound < left.lowerBound, "…once it had been connected: \(probe.label)")
        }
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
