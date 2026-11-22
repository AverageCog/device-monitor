import Foundation
import Testing
@testable import DMCore

/// The periods "One rate" replaces, across editors. The dashboard keeps them in `lastTou`, a
/// variable of its page (public/index.html, above function setPriceMode), so they survive closing
/// and reopening the settings dialog. The app makes an editor for every screen that shows the
/// price and hands the memory from one to the next with `PriceEditor.remember(_:)`.
@Suite struct PriceEditorMemoryTests {
    private let enUS = Locale(identifier: "en_US")
    private let periods = [TouPeriod(from: 7, to: 11, rate: 0.42), TouPeriod(from: 17, to: 21, rate: 0.55)]

    private func editor(_ saved: EnergySettings) -> PriceEditor {
        PriceEditor(saved: saved, guessedRegion: "US-CA", locale: enUS)
    }

    private var timeOfUse: EnergySettings { EnergySettings(region: "US-CA", rate: 0.3, currency: "USD", tou: periods) }
    private var oneRate: EnergySettings { EnergySettings(region: "US-CA", rate: 0.3, currency: "USD") }

    @Test func periodsReplacedInOneEditorComeBackInAnother() {
        // "One rate" in the sheet…
        var sheet = editor(timeOfUse)
        let flat = sheet.setMode(.flat)
        #expect(flat == oneRate)
        #expect(sheet.rememberedPeriods == periods)

        // …and "Time of use" in an editor made later, which was not there to see it.
        var later = editor(oneRate)
        #expect(later.rememberedPeriods == nil)
        later.remember(sheet.rememberedPeriods)
        let restored = later.setMode(.timeOfUse)
        #expect(restored == timeOfUse)
    }

    @Test func anEditorThatWasHandedNothingStartsWithTheUsualPeriod() {
        // [{ from: 16, to: 21, rate: s.rate }]
        let usual = EnergySettings(region: "US-CA", rate: 0.3, currency: "USD", tou: [TouPeriod(from: 16, to: 21, rate: 0.3)])
        var fresh = editor(oneRate)
        let unaided = fresh.setMode(.timeOfUse)
        #expect(unaided == usual)

        var handedNothing = editor(oneRate)
        handedNothing.remember(nil)
        let afterNothing = handedNothing.setMode(.timeOfUse)
        #expect(afterNothing == usual)

        // lastTou?.length: an empty list counts as nothing remembered.
        var handedNone = editor(oneRate)
        handedNone.remember([])
        let afterNone = handedNone.setMode(.timeOfUse)
        #expect(afterNone == usual)
    }

    /// The way the app uses it: one memory beside all its editors, handed over before each action
    /// and read back after it.
    @Test func editorsThatHandTheMemoryOnBehaveLikeOnePage() throws {
        var memory: [TouPeriod]?
        var settings = editor(timeOfUse)
        var sheet = editor(timeOfUse)
        /// An action in one editor; the hub's answer reaches both.
        func act(inSheet: Bool, _ action: (inout PriceEditor) -> EnergySettings?) throws -> EnergySettings {
            var acting = inSheet ? sheet : settings
            acting.remember(memory)
            let sent = action(&acting)
            memory = acting.rememberedPeriods
            let body = try #require(sent)
            let stored = try #require(EnergyPricing.hubStored(body))
            acting.hubSaved(stored)
            if inSheet {
                sheet = acting
                settings.hubSaved(stored)
            } else {
                settings = acting
                sheet.hubSaved(stored)
            }
            return body
        }

        // Removing the last period goes back to one rate, and remembers what the hub had.
        _ = try act(inSheet: false) { $0.removePeriod(at: 1) }
        #expect(memory == nil)
        let flat = try act(inSheet: false) { $0.removePeriod(at: 0) }
        #expect(flat == oneRate)
        #expect(memory == [periods[0]])

        // The other editor brings that back, and what it replaces later is the first one's to restore.
        let restored = try act(inSheet: true) { $0.setMode(.timeOfUse) }
        #expect(restored.tou == [periods[0]])
        let longer = try act(inSheet: true) { $0.addPeriod() }
        #expect(longer.tou.count == 2)
        _ = try act(inSheet: true) { $0.setMode(.flat) }
        #expect(memory == longer.tou)
        let back = try act(inSheet: false) { $0.setMode(.timeOfUse) }
        #expect(back == longer)
    }

    /// The memory this mirrors is still a variable of the dashboard's page, not of its dialog.
    @Test func theDashboardStillRemembersForItsWholePage() {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        // Only where the repository is checked out around the package.
        guard let page = try? String(contentsOf: root.appendingPathComponent("public/index.html"), encoding: .utf8) else { return }
        #expect(page.contains("// Switching back and forth keeps the periods you had, for this session.\nlet lastTou = null;"))
    }
}
