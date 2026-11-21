import Foundation
import Testing
@testable import DMCore

/// The Settings tab's wording against the dashboard's settings dialog and main.js.
@Suite struct SettingsOverviewTests {
    private let pin = "q83vEjRWeJ0Iq83vEjRWeJ0Iq83vEjRWeJ0IKf0x9dE="
    private let info = HubInfo(hostname: "den-pc", port: 7777, canEnroll: false, canShare: true, origin: "https://den-pc.tail1234.ts.net")

    private func paired(_ device: SettingsOverview.Device = .phone, name: String? = "Jay's iPhone", info: HubInfo? = nil) -> SettingsOverview {
        SettingsOverview(
            device: device, isDemo: false, hubOrigin: "https://hub.example:8443", pairedName: name, info: info, pin: pin,
            appVersion: "1.0.0", appBuild: "1")
    }

    @Test func aPairedPhoneReadsLikeTheDesktopInConnectMode() {
        let s = paired()
        #expect(s.deviceTitle == "This iPhone")
        // `Connected to the hub at ${s.hubUrl}`
        #expect(s.connection == "Connected to the hub at https://hub.example:8443")
        #expect(s.pairedAs == "Paired as Jay's iPhone")
        #expect(s.deviceDetail == "Connected to the hub at https://hub.example:8443\nPaired as Jay's iPhone")
        #expect(s.leaveLabel == "Disconnect\u{2026}" && s.confirmsLeaving)
        // 'Disconnect this computer and change setup?'
        #expect(s.disconnectQuestion == "Disconnect this iPhone and change setup?")
        #expect(s.disconnectDetail == "The hub forgets this iPhone. To connect again, pair it with a new invitation from the hub.")
        #expect(SettingsOverview.Labels.confirmDisconnect == "Disconnect")
    }

    @Test func aTabletIsCalledOne() {
        let s = paired(.pad, name: "Kitchen iPad")
        #expect(s.deviceTitle == "This iPad")
        #expect(s.disconnectQuestion == "Disconnect this iPad and change setup?")
        #expect(s.disconnectDetail.hasPrefix("The hub forgets this iPad."))
        #expect(s.companion.hasSuffix("never reports this iPad's own stats."))
    }

    @Test func theDemoSaysWhatItIsAndLeavesWithoutAsking() {
        let s = SettingsOverview(device: .phone, isDemo: true, hubOrigin: "https://hub.demo.example", pairedName: "ignored")
        #expect(s.connection == "Running the demo on a hub that exists only in memory. Nothing is stored.")
        #expect(s.pairedAs == nil && s.deviceDetail == s.connection)
        #expect(s.leaveLabel == "Exit demo" && !s.confirmsLeaving)
        #expect(s.fingerprint == nil)
    }

    @Test func withoutAHubItIsNotSetUp() {
        let s = SettingsOverview(device: .phone, isDemo: false, hubOrigin: nil)
        #expect(s.connection == "Not set up" && s.pairedAs == nil && s.address == nil && s.hostName == nil)
    }

    @Test func anEmptyLabelIsNoLabel() {
        #expect(paired(name: "").pairedAs == nil)
        #expect(paired(name: nil).deviceDetail == "Connected to the hub at https://hub.example:8443")
    }

    @Test func theHubsOwnAnswerNamesItOnceItHasArrived() {
        let before = paired()
        #expect(before.hostName == nil)
        #expect(before.address == "https://hub.example:8443", "Until the hub answers, the address is the one the app is enrolled at")
        let after = paired(info: info)
        #expect(after.hostName == "den-pc")
        #expect(after.address == "https://den-pc.tail1234.ts.net")
        let bare = paired(info: HubInfo(hostname: "", origin: nil))
        #expect(bare.hostName == nil && bare.address == "https://hub.example:8443")
    }

    @Test func theVersionLineIsTheDashboardsWithTheBuild() {
        #expect(paired().version == "Version 1.0.0 (1)")
        #expect(SettingsOverview(device: .phone, isDemo: false, hubOrigin: nil, appVersion: "2.1").version == "Version 2.1")
        #expect(SettingsOverview(device: .phone, isDemo: false, hubOrigin: nil, appVersion: "", appBuild: "7").version == "Version unknown")
    }

    @Test func theFingerprintIsThePinShortenedAndGrouped() throws {
        let fingerprint = try #require(paired().fingerprint)
        #expect(fingerprint.pin == pin)
        #expect(fingerprint.short == "q83vEjRW\u{2026}Kf0x9dE=")
        #expect(fingerprint.grouped == "q83v EjRW eJ0I q83v EjRW eJ0I q83v EjRW eJ0I Kf0x 9dE=")
        #expect(fingerprint.grouped.replacingOccurrences(of: " ", with: "") == pin)
    }

    @Test(arguments: [nil, "", "not a pin", String(repeating: "A", count: 44), String(repeating: "A", count: 42) + "=", String(repeating: "-", count: 43) + "="])
    func whatIsNotAPinHasNoFingerprint(text: String?) {
        #expect(HubFingerprint(pin: text) == nil)
    }

    /// The notice the app shows is the repository's LICENSE, word for word.
    @Test func theLicenseIsTheRepositorys() throws {
        // …/ios/Packages/DMCore/Tests/DMCoreTests/PresentationSettings/<this file>
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        // The package can be checked out without the repository around it; then there is nothing to compare with.
        guard let license = try? String(contentsOf: root.appendingPathComponent("LICENSE"), encoding: .utf8) else { return }
        let words = { (text: String) in text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        #expect(words(SettingsOverview.licenseParagraphs.joined(separator: "\n\n")) == words(license))
        let paragraphs = license.components(separatedBy: "\n\n").map(words).filter { !$0.isEmpty }
        #expect(SettingsOverview.licenseParagraphs == paragraphs)
        #expect(SettingsOverview.licenseSummary == "MIT License \u{B7} Copyright (c) 2026 Matt")
    }
}

/// The notes around the price editor.
@Suite struct PriceEditorNotesTests {
    @Test func failuresCarryTheHubsOrTheTransportsWords() {
        #expect(PriceEditorNotes.saveFailed(.http(status: 400, message: "invalid settings")) == "Could not save the electricity price. invalid settings")
        #expect(PriceEditorNotes.saveFailed(.unreachable("Could not connect to the hub.")) == "Could not save the electricity price. Could not connect to the hub.")
        #expect(PriceEditorNotes.loadFailed(.unreachable("The hub did not answer in time.")) == "Could not load the electricity price. The hub did not answer in time.")
        #expect(PriceEditorNotes.loadFailed(.http(status: 500, message: "")) == "Could not load the electricity price.")
    }

    @Test func periodsAreNamedByTheirHours() throws {
        var editor = PriceEditor(saved: EnergySettings(region: "US-CA", rate: 0.3, currency: "USD", tou: [TouPeriod(from: 16, to: 21, rate: 0.5), TouPeriod(from: 0, to: 12, rate: 0.2)]), guessedRegion: "US")
        #expect(editor.periods.map(PriceEditorNotes.span(of:)) == ["4 pm to 9 pm", "12 am to noon"])
        #expect(PriceEditorNotes.removeLabel(for: try #require(editor.periods.first)) == "Remove 4 pm to 9 pm")
        _ = editor.setPeriodEnd(at: 0, hour: 24)
        #expect(PriceEditorNotes.span(of: editor.periods[0]) == "4 pm to midnight")
        #expect(PriceEditorNotes.periodLimit == "The hub keeps at most 12 time periods.")
    }
}
