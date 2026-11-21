import Foundation
import Testing
@testable import DMCore

/// The Settings price editor, replayed against editor.json: the dashboard's own handlers were
/// driven action by action behind a fake page, with the hub's validEnergySettings answering.
@Suite struct PriceEditorTests {
    private static let loaded = Result { try EnergyFixtures.load(EnergyFixtures.Editor.self, "editor.json") }
    private let enUS = EnergyFixtures.enUS

    private func focus(_ name: String) -> PriceEditor.Focus {
        switch name {
        case "rate": .flatRate
        case "tou": .timeOfUse
        default: .none
        }
    }

    private func differences(_ editor: PriceEditor, _ expected: EnergyFixtures.Editor.Snapshot) -> [String] {
        var out: [String] = []
        func check<T: Equatable>(_ what: String, _ ours: T, _ theirs: T) {
            if ours != theirs { out.append("\(what): ours \(ours), dashboard \(theirs)") }
        }
        check("hint", editor.hint, expected.hint)
        check("mode", editor.mode, expected.isTou ? .timeOfUse : .flat)
        check("region", editor.regionCode, expected.region)
        check("currency", editor.currency, expected.currency)
        check("guessed", editor.price.guessed, expected.guessed)
        check("rate field", editor.rateText, expected.rate)
        check("remembered periods", editor.rememberedPeriods, expected.lastTou)
        if let rows = expected.rows {
            check("rows", editor.periods.map { "\(JS.string($0.from))-\(JS.string($0.to)) \"\($0.rateText)\"\($0.isInvalid ? " bad" : "")" },
                  rows.map { "\(JS.string($0.from))-\(JS.string($0.to)) \"\($0.rate)\"\($0.bad ? " bad" : "")" })
            check("other hours", "\"\(editor.baseRateText)\"\(editor.baseRateIsInvalid ? " bad" : "")", expected.base.map { "\"\($0.value)\"\($0.bad ? " bad" : "")" } ?? "none")
        } else {
            check("rows in flat mode", editor.periods.count, 0)
        }
        return out
    }

    @Test func everyScenarioSendsWhatTheDashboardSendsAndShowsWhatItShows() throws {
        let scenarios = try Self.loaded.get().scenarios
        #expect(scenarios.count >= 45)
        var failures: [String] = []
        var steps = 0, sent = 0, refusedByHub = 0
        for scenario in scenarios {
            #expect(PriceRegions.guess(timeZoneIdentifier: scenario.tz, languageTag: scenario.language) == scenario.guessedRegion)
            var editor = PriceEditor(saved: scenario.saved, guessedRegion: scenario.guessedRegion, locale: enUS)
            for problem in differences(editor, scenario.initial) { failures.append("\(scenario.name), at the start: \(problem)") }
            for (number, step) in scenario.steps.enumerated() {
                steps += 1
                let action = step.action, focus = focus(action.focus)
                let where_ = "\(scenario.name), step \(number + 1) (\(action.type) \(action.code ?? action.text ?? action.mode ?? "")\(action.index.map { " row \($0)" } ?? "")\(action.hour.map { " hour \(JS.string($0))" } ?? ""))"
                var body: EnergySettings?
                switch action.type {
                case "region": body = editor.chooseRegion(try #require(action.code))
                case "currency": body = editor.chooseCurrency(try #require(action.code))
                case "rate": body = editor.setRate(try #require(action.text), focus: focus)
                case "mode": body = editor.setMode(action.mode == "tou" ? .timeOfUse : .flat)
                case "periodFrom": body = editor.setPeriodStart(at: try #require(action.index), hour: try #require(action.hour))
                case "periodTo": body = editor.setPeriodEnd(at: try #require(action.index), hour: try #require(action.hour))
                case "periodRate": body = editor.setPeriodRate(at: try #require(action.index), text: try #require(action.text))
                case "baseRate": body = editor.setBaseRate(try #require(action.text))
                case "removePeriod": body = editor.removePeriod(at: try #require(action.index))
                case "addPeriod": body = editor.addPeriod()
                case "hubEvent": editor.hubSaved(action.settings, focus: focus)
                default: Issue.record("unknown action \(action.type)")
                }

                // The editor sends exactly what the dashboard sends, except what the hub would refuse.
                let expectedBody: EnergySettings?
                switch step.answer {
                case .none:
                    expectedBody = nil
                    if step.put != nil { refusedByHub += 1 }
                case .same, .stored:
                    expectedBody = step.put
                }
                if body != expectedBody {
                    failures.append("\(where_): sends \(body.map { "\($0)" } ?? "nothing"), the dashboard \(expectedBody.map { "\($0)" } ?? "nothing")")
                }
                if let body {
                    sent += 1
                    let stored = EnergyPricing.hubStored(body)
                    let hubAnswer: EnergySettings? = switch step.answer {
                    case .none: nil
                    case .same: step.put
                    case .stored(let settings): settings
                    }
                    if stored != hubAnswer { failures.append("\(where_): hubStored gives \(stored.map { "\($0)" } ?? "nil"), the hub \(hubAnswer.map { "\($0)" } ?? "nil")") }
                    editor.hubSaved(hubAnswer, focus: focus)
                    // The exact JSON matters too: a flat price carries no `tou` key.
                    let json = String(decoding: try HubJSON.encode(body), as: UTF8.self)
                    if body.tou.isEmpty == json.contains("\"tou\"") { failures.append("\(where_): body encodes as \(json)") }
                }
                if editor.saved != step.saved { failures.append("\(where_): saved is \(editor.saved.map { "\($0)" } ?? "nil"), the dashboard has \(step.saved.map { "\($0)" } ?? "nil")") }
                for problem in differences(editor, step.after) { failures.append("\(where_): \(problem)") }
                if failures.count > 30 { break }
            }
        }
        #expect(failures.isEmpty, "\(failures.count) differences:\n\(failures.prefix(30).joined(separator: "\n"))")
        #expect(steps > 900)
        #expect(sent > 300)
        #expect(refusedByHub >= 3)   // the thirteenth period
    }

    @Test func everythingSentPassesTheHubsCheck() throws {
        // Free-form abuse of the editor: whatever comes out must be something the hub stores.
        var generator = PresentationTestRandom(seed: 0x5EED)
        let texts = ["0.25", "0", "", "x", "1000", "1000.5", "0.00001", "0.00004", "0.00005", "1e-9", "-2", "31", "0.1234567", "5e2", "Infinity", "NaN"]
        let hours: [Double] = [0, 1, 5.5, 12, 16.01, 16.02, 23, 23.99, 24, 25, -1, .nan, .infinity]
        for round in 0..<60 {
            let start: EnergySettings? = round % 3 == 0 ? nil : EnergySettings(region: "custom", rate: 0.25, currency: "EUR", tou: round % 3 == 1 ? [] : [TouPeriod(from: 0.25, to: 6.5, rate: 0.1)])
            var editor = PriceEditor(saved: start, guessedRegion: "US-CA", locale: enUS)
            for _ in 0..<80 {
                let index = Int(generator.next() % 4)
                let text = texts[Int(generator.next() % UInt64(texts.count))]
                let hour = hours[Int(generator.next() % UInt64(hours.count))]
                let body: EnergySettings? = switch generator.next() % 12 {
                case 0: editor.chooseRegion(["US", "DE", "custom", "nope", ""][Int(generator.next() % 5)])
                case 1: editor.chooseCurrency(["USD", "EUR", "usd", "EURO", ""][Int(generator.next() % 5)])
                case 2: editor.setRate(text)
                case 3: editor.setMode(.flat)
                case 4: editor.setMode(.timeOfUse)
                case 5: editor.setPeriodStart(at: index, hour: hour)
                case 6: editor.setPeriodEnd(at: index, hour: hour)
                case 7: editor.setPeriodRate(at: index, text: text)
                case 8: editor.setBaseRate(text)
                case 9: editor.removePeriod(at: index)
                default: editor.addPeriod()
                }
                guard let body else { continue }
                let stored = EnergyPricing.hubStored(body)
                #expect(stored != nil, "the hub would refuse \(body)")
                editor.hubSaved(stored)
                #expect(editor.price.tou.count <= EnergyPricing.maxPeriods)
            }
        }
    }

    @Test func aRateTheHubWouldRoundToZeroIsMarkedNotSent() {
        var editor = PriceEditor(saved: EnergySettings(region: "custom", rate: 0.25, currency: "EUR", tou: [TouPeriod(from: 0, to: 6, rate: 0.1)]), guessedRegion: "US", locale: enUS)
        var body = editor.setPeriodRate(at: 0, text: "0.00004")
        #expect(body == nil)
        #expect(editor.periods[0].isInvalid)
        body = editor.setPeriodRate(at: 0, text: "0.00005")
        #expect(body != nil)
        #expect(!editor.periods[0].isInvalid)
        body = editor.setBaseRate("0.00001")
        #expect(body == nil)
        #expect(editor.baseRateIsInvalid)
        body = editor.setRate("0.00004")
        #expect(body == nil)
        #expect(editor.rateText == "0.25")
    }

    @Test func quarterHoursSavedByAnotherClientAreKept() throws {
        let saved = EnergySettings(region: "custom", rate: 0.25, currency: "EUR", tou: [TouPeriod(from: 0.5, to: 6.25, rate: 0.1235)])
        var editor = PriceEditor(saved: saved, guessedRegion: "US", locale: enUS)
        let row = try #require(editor.periods.first)
        #expect(row.from == 0.5 && row.to == 6.25)
        #expect(editor.startHourOptions(for: row).map(\.hour) == [0, 0.5] + (1...23).map(Double.init))
        #expect(editor.startHourOptions(for: row)[1].label == "12:30 am")
        #expect(editor.endHourOptions(for: row).first { $0.hour == 6.25 }?.label == "6:15 am")
        #expect(editor.endHourOptions(for: row).count == 25)
        // Changing only the rate sends the hours back untouched.
        let body = editor.setPeriodRate(at: 0, text: "0.13")
        #expect(body?.tou == [TouPeriod(from: 0.5, to: 6.25, rate: 0.13)])
        // A whole-hour row offers just the dashboard's lists.
        editor.hubSaved(EnergySettings(region: "custom", rate: 0.25, currency: "EUR", tou: [TouPeriod(from: 16, to: 21, rate: 0.4)]))
        let whole = try #require(editor.periods.first)
        #expect(editor.startHourOptions(for: whole) == PriceEditor.startHours)
        #expect(editor.endHourOptions(for: whole) == PriceEditor.endHours)
    }

    @Test func hourPickersAndLabelsAreTheDashboards() throws {
        let fixture = try EnergyFixtures.load(EnergyFixtures.Hours.self, "hours.json")
        #expect(PriceEditor.startHours.map(\.hour) == fixture.from.map(\.hour))
        #expect(PriceEditor.startHours.map(\.label) == fixture.from.map(\.label))
        #expect(PriceEditor.endHours.map(\.hour) == fixture.to.map(\.hour))
        #expect(PriceEditor.endHours.map(\.label) == fixture.to.map(\.label))
        #expect(fixture.from.count == 24 && fixture.to.count == 24)
        let ours: [String: String] = [
            "title": PriceEditor.Labels.title, "perKwh": PriceEditor.Labels.perKwh, "to": PriceEditor.Labels.to,
            "otherHours": PriceEditor.Labels.otherHours, "addPeriod": PriceEditor.Labels.addPeriod,
            "removePeriod": PriceEditor.Labels.removePeriod, "region": PriceEditor.Labels.region,
            "currency": PriceEditor.Labels.currency, "rate": PriceEditor.Labels.rate, "baseRate": PriceEditor.Labels.baseRate,
            "from": PriceEditor.Labels.from, "until": PriceEditor.Labels.until,
            "flat": PriceEditor.Mode.flat.label, "timeOfUse": PriceEditor.Mode.timeOfUse.label, "custom": PriceRegions.customName,
        ]
        #expect(ours == fixture.labels)
    }

    @Test func currencyPickerKeepsACurrencyItDoesNotList() {
        let listed = PriceEditor(saved: EnergySettings(region: "custom", rate: 1, currency: "EUR"), guessedRegion: "US", locale: enUS)
        #expect(listed.currencyOptions == PriceRegions.currencies)
        let unlisted = PriceEditor(saved: EnergySettings(region: "custom", rate: 1, currency: "ISK"), guessedRegion: "US", locale: enUS)
        #expect(unlisted.currencyOptions.count == PriceRegions.currencies.count + 1)
        #expect(unlisted.currencyOptions == unlisted.currencyOptions.sorted())
        #expect(unlisted.currencyOptions.contains("ISK"))
    }

    @Test func aFailedSaveShowsTheSavedPriceAgain() {
        var editor = PriceEditor(saved: EnergySettings(region: "DE", rate: 0.39, currency: "EUR"), guessedRegion: "US", locale: Locale(identifier: "de_DE"))
        #expect(editor.rateText == "0,39")
        let body = editor.setRate("0,41")
        #expect(body?.rate == 0.41)
        #expect(editor.rateText == "0,41")
        editor.saveFailed()
        #expect(editor.rateText == "0,39")
        #expect(editor.saved?.rate == 0.39)
        // Still typing: the field is left alone.
        _ = editor.setRate("0,4", focus: .flatRate)
        editor.saveFailed(focus: .flatRate)
        #expect(editor.rateText == "0,4")
    }

    @Test func rowIdentitiesSurviveEditsButNotARebuild() throws {
        var editor = PriceEditor(saved: EnergySettings(region: "custom", rate: 0.2, currency: "USD", tou: [TouPeriod(from: 0, to: 6, rate: 0.1), TouPeriod(from: 16, to: 21, rate: 0.4)]), guessedRegion: "US", locale: enUS)
        let ids = editor.periods.map(\.id)
        #expect(Set(ids).count == 2)
        let sent = editor.setPeriodEnd(at: 0, hour: 7)
        let body = try #require(sent)
        #expect(editor.periods.map(\.id) == ids)
        editor.hubSaved(EnergyPricing.hubStored(body), focus: .timeOfUse)
        #expect(editor.periods.map(\.id) == ids)
        editor.hubSaved(editor.saved)
        #expect(Set(editor.periods.map(\.id)).isDisjoint(with: ids))
    }

    @Test func outOfRangeRowsAreIgnored() {
        var editor = PriceEditor(saved: EnergySettings(region: "custom", rate: 0.2, currency: "USD", tou: [TouPeriod(from: 0, to: 6, rate: 0.1)]), guessedRegion: "US", locale: enUS)
        let before = editor
        let bodies = [editor.setPeriodStart(at: 3, hour: 1), editor.setPeriodEnd(at: -1, hour: 1), editor.setPeriodRate(at: 1, text: "1"), editor.removePeriod(at: 1)]
        #expect(bodies == [nil, nil, nil, nil])
        #expect(editor == before)
    }
}

/// A small deterministic generator, so the free-form test does the same thing on every run.
struct PresentationTestRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
