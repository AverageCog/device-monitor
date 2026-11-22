import Foundation
import Testing
@testable import DMCore

@MainActor
@Suite struct PreferencesTests {
    typealias Key = Preferences.Key

    /// Preferences over a suite holding `stored`, the way a previous launch (or a launch argument) left it.
    static func make(_ stored: [Key: Any] = [:]) -> (Preferences, UserDefaults) {
        let name = "dm-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        for (key, value) in stored { defaults.set(value, forKey: key.rawValue) }
        return (Preferences(defaults: defaults), defaults)
    }

    @Test func defaultsAreTheDashboards() {
        let (preferences, _) = Self.make()
        #expect(preferences.temperatureUnit == .celsius)                       // store.get('unit') || 'C'
        #expect(preferences.defaultCardRange == .tenMinutes)                   // DEFAULT_RANGE
        #expect(preferences.cardRange(for: "any") == .tenMinutes)
        #expect(preferences.historyRange == .sixHours)                         // hv.range
        #expect(preferences.advancedRange == .week)                            // adv.range
        #expect(!preferences.isAdvancedSettingsExpanded)
        #expect(!preferences.notificationsEnabled)
        #expect(preferences.lastSeenAlertID == nil && preferences.lastSeenAlertTime == nil)
        #expect(preferences.appearance == .system)
    }

    @Test func storedValuesAreReadBack() {
        let (preferences, _) = Self.make([
            .unit: "F", .range: "1h", .cardRanges: #"{"ws":"6h","mac":"10m"}"#, .hvRange: "30d", .advRange: "24h", .setAdvOpen: "1",
            .notifications: true, .alertSeenID: "abc", .alertSeenTime: 1_795_000_000_000.0,
        ])
        #expect(preferences.temperatureUnit == .fahrenheit)
        #expect(preferences.defaultCardRange == .hour)
        #expect(preferences.cardRange(for: "ws") == .sixHours && preferences.cardRange(for: "mac") == .tenMinutes)
        #expect(preferences.cardRange(for: "other") == .hour)                  // the old dashboard-wide setting
        #expect(preferences.historyRange == .month && preferences.advancedRange == .day)
        #expect(preferences.isAdvancedSettingsExpanded && preferences.notificationsEnabled)
        #expect(preferences.lastSeenAlertID == "abc" && preferences.lastSeenAlertTime == 1_795_000_000_000)
    }

    @Test func whatTheDashboardWouldNotAcceptFallsBackToTheDefault() {
        // Each range is checked against the list of its own place: a history range is not a card range.
        let (preferences, _) = Self.make([
            .unit: "K", .range: "24h", .cardRanges: #"{"a":"7d","b":"nonsense","c":5,"d":"1h"}"#, .hvRange: "10m", .advRange: "1h", .setAdvOpen: "true",
        ])
        #expect(preferences.temperatureUnit == .celsius)                       // anything but 'F' reads as Celsius
        #expect(preferences.defaultCardRange == .tenMinutes)
        #expect(preferences.cardRange(for: "a") == .tenMinutes && preferences.cardRange(for: "b") == .tenMinutes && preferences.cardRange(for: "c") == .tenMinutes)
        #expect(preferences.cardRange(for: "d") == .hour)
        #expect(preferences.historyRange == .sixHours && preferences.advancedRange == .week)
        #expect(!preferences.isAdvancedSettingsExpanded)                       // only '1' opens it

        for broken in ["", "not json", "[1,2]", "null", "7", #""1h""#] {
            let (preferences, _) = Self.make([.cardRanges: broken])
            #expect(preferences.cardRange(for: "a") == .tenMinutes)
        }
    }

    @Test func changesAreStoredInTheDashboardsForm() {
        let (preferences, defaults) = Self.make()
        let stored = { (key: Key) in defaults.string(forKey: key.rawValue) }
        preferences.temperatureUnit = .fahrenheit
        preferences.historyRange = .day
        preferences.advancedRange = .month
        preferences.isAdvancedSettingsExpanded = true
        preferences.notificationsEnabled = true
        preferences.defaultCardRange = .sixHours
        #expect(stored(.unit) == "F" && stored(.hvRange) == "24h" && stored(.advRange) == "30d" && stored(.setAdvOpen) == "1" && stored(.range) == "6h")
        #expect(defaults.bool(forKey: Key.notifications.rawValue))
        preferences.temperatureUnit = .celsius
        preferences.isAdvancedSettingsExpanded = false
        #expect(stored(.unit) == "C" && stored(.setAdvOpen) == "0")

        // A second instance over the same store sees it all, as the next launch will.
        let again = Preferences(defaults: defaults)
        #expect(again.temperatureUnit == .celsius && again.historyRange == .day && again.advancedRange == .month)
        #expect(!again.isAdvancedSettingsExpanded && again.notificationsEnabled && again.defaultCardRange == .sixHours)
    }

    @Test func aRangeFromAnotherPlaceIsIgnored() {
        let (preferences, defaults) = Self.make()
        preferences.historyRange = .tenMinutes
        preferences.advancedRange = .hour
        preferences.defaultCardRange = .week
        preferences.setCardRange(.day, for: "ws")
        #expect(preferences.historyRange == .sixHours && preferences.advancedRange == .week && preferences.defaultCardRange == .tenMinutes)
        #expect(preferences.cardRange(for: "ws") == .tenMinutes)
        #expect(Key.allCases.allSatisfy { defaults.object(forKey: $0.rawValue) == nil })
    }

    @Test func cardRangesAreKeptPerDeviceAsOneJSONObject() throws {
        let (preferences, defaults) = Self.make([.cardRanges: #"{"old":"1h","odd":"12h"}"#])
        preferences.setCardRange(.sixHours, for: "ws")
        preferences.setCardRange(.hour, for: "id with \"quotes\" and \u{E9}")
        preferences.setCardRange(.tenMinutes, for: "ws")
        #expect(preferences.cardRange(for: "ws") == .tenMinutes && preferences.cardRange(for: "old") == .hour)
        #expect(preferences.cardRange(for: "id with \"quotes\" and \u{E9}") == .hour)

        // JSON.stringify(cardRanges): everything that was there stays, readable by a dashboard.
        let text = try #require(defaults.string(forKey: Key.cardRanges.rawValue))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        #expect(object == ["old": "1h", "odd": "12h", "ws": "10m", "id with \"quotes\" and \u{E9}": "1h"])
        #expect(Preferences(defaults: defaults).cardRange(for: "ws") == .tenMinutes)
    }

    @Test func theAppearanceIsStoredAndReadBack() {
        let (preferences, defaults) = Self.make()
        preferences.appearance = .light
        #expect(defaults.string(forKey: Key.appearance.rawValue) == "light")
        #expect(Preferences(defaults: defaults).appearance == .light)
        preferences.appearance = .dark
        #expect(Preferences(defaults: defaults).appearance == .dark)
        preferences.appearance = .system
        #expect(defaults.string(forKey: Key.appearance.rawValue) == "system")

        for unknown in ["", "Light", "auto", "1"] {
            #expect(Self.make([.appearance: unknown]).0.appearance == .system)
        }
    }

    @Test func theNewestSeenAlertOnlyMovesForward() {
        let (preferences, defaults) = Self.make()
        preferences.markAlertSeen(StoreFixtures.alert("b", t: 2000))
        #expect(preferences.lastSeenAlertID == "b" && preferences.lastSeenAlertTime == 2000)
        preferences.markAlertSeen(StoreFixtures.alert("a", t: 1000))           // older: ignored
        #expect(preferences.lastSeenAlertID == "b")
        preferences.markAlertSeen(id: "c", time: 2000)                         // same moment, later entry
        preferences.markAlertSeen(id: "d", time: 3000)
        #expect(preferences.lastSeenAlertID == "d" && preferences.lastSeenAlertTime == 3000)
        let again = Preferences(defaults: defaults)
        #expect(again.lastSeenAlertID == "d" && again.lastSeenAlertTime == 3000)
    }

    @Test func forgettingAHubKeepsDisplayChoices() {
        let (preferences, defaults) = Self.make()
        preferences.temperatureUnit = .fahrenheit
        preferences.historyRange = .week
        preferences.notificationsEnabled = true
        preferences.setCardRange(.hour, for: "ws")
        preferences.markAlertSeen(id: "x", time: 5)
        preferences.appearance = .light
        preferences.forgetHub()
        #expect(preferences.cardRange(for: "ws") == .tenMinutes && preferences.lastSeenAlertID == nil && preferences.lastSeenAlertTime == nil)
        #expect(preferences.temperatureUnit == .fahrenheit && preferences.historyRange == .week && preferences.notificationsEnabled)
        #expect(preferences.appearance == .light)
        let again = Preferences(defaults: defaults)
        #expect(again.cardRange(for: "ws") == .tenMinutes && again.lastSeenAlertID == nil && again.temperatureUnit == .fahrenheit)
    }

    @Test func readingAndWritingAreObserved() {
        let (preferences, _) = Self.make()
        let changes = Counter()
        func observe(_ read: @escaping @MainActor () -> Void) {
            withObservationTracking { read() } onChange: { changes.increment() }
        }
        observe { _ = preferences.temperatureUnit }
        preferences.historyRange = .day                                         // a different property: not this observer's business
        #expect(changes.count == 0)
        preferences.temperatureUnit = .fahrenheit
        #expect(changes.count == 1)
        observe { _ = preferences.cardRange(for: "ws") }
        preferences.setCardRange(.hour, for: "ws")
        #expect(changes.count == 2)
        observe { _ = preferences.lastSeenAlertID }
        preferences.markAlertSeen(id: "a", time: 1)
        #expect(changes.count == 3)
        observe { _ = preferences.appearance }                                  // what the root's colour scheme follows
        preferences.appearance = .dark
        #expect(changes.count == 4)
    }

    @Test func rangesAreTheHubsAndTheDashboardsLabels() {
        #expect(HistoryRange.allCases.map(\.rawValue) == ["10m", "1h", "6h", "24h", "7d", "30d"])
        #expect(HistoryRange.allCases.map(\.milliseconds) == [600_000, 3_600_000, 21_600_000, 86_400_000, 604_800_000, 2_592_000_000])
        #expect(HistoryRange.cardRanges.map(\.label) == ["last 10 min", "last 60 min", "last 6 hours"])           // RANGE_LABEL
        #expect(HistoryRange.advancedRanges.map(\.label) == ["last 24 hours", "last 7 days", "last 30 days"])     // rangeLabel in renderAdv
        #expect(HistoryRange.historyRanges.map(\.shortLabel) == ["1 h", "6 h", "24 h", "7 days", "30 days"])      // #hvRange buttons
        #expect(UpdatePlatform(devicePlatform: "windows") == .windows && UpdatePlatform(devicePlatform: "macos") == .mac)
        #expect(UpdatePlatform(devicePlatform: "linux") == nil && UpdatePlatform(devicePlatform: "mac") == nil && UpdatePlatform(devicePlatform: nil) == nil)
    }
}
