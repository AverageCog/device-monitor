import Foundation
import Testing
@testable import DMCore

/// presentation/dashboard/grid.json, menu.json and rename.json: the summary line, empty states,
/// the order of cards, the offline list and the device menu as the real dashboard produced them,
/// and what the hub's own cleanText keeps of a name.
@Suite struct DashboardGridFixtureTests {
    struct Grid: Decodable {
        struct Summary: Decodable {
            let text: String
            let short: String
            /// The dashboard hides the long text in a narrow window while this is set.
            let full: Bool
            let hasOff: Bool
            let title: String
        }

        struct Empty: Decodable {
            let small: Bool
            let title: String?
            let text: String
        }

        struct Offline: Decodable {
            struct Row: Decodable {
                struct Wake: Decodable {
                    let text: String
                    let title: String
                }

                let id: String
                let title: String
                let name: String
                let subtitle: String
                let wake: Wake?
            }

            let heading: String
            let rows: [Row]
        }

        struct Reconnecting: Decodable {
            let text: String
            let short: String
            let full: Bool
        }

        struct Expected: Decodable {
            let summary: Summary
            let empty: Empty?
            let grid: [String]
            let offline: Offline
            let reconnecting: Reconnecting
        }

        struct Case: Decodable {
            let label: String
            let now: Double
            let latestVersions: [String: String]
            let devices: [Device]
            let expected: Expected
        }

        struct Accented: Decodable {
            let label: String
            let devices: [Device]
            let expected: [String]
        }

        let cases: [Case]
        let accented: [Accented]
    }

    let grid: Grid
    private let enUS = DashFixture.enUS

    init() throws {
        grid = try DashFixture.decode(Grid.self, "dashboard/grid.json")
    }

    @Test func summaryLine() {
        var failures = [String]()
        for c in grid.cases {
            let summary = DashboardSummary(devices: c.devices), e = c.expected.summary
            if summary.text != e.text { failures.append("\(c.label): \"\(summary.text)\", dashboard \"\(e.text)\"") }
            if summary.shortText != e.short { failures.append("\(c.label): short \"\(summary.shortText)\", dashboard \"\(e.short)\"") }
            // A narrow window shows the short form in place of the long one whenever the long one is marked `full`.
            if summary.compactText != (e.full ? e.short : e.text + e.short) { failures.append("\(c.label): compact \"\(summary.compactText)\"") }
            if summary.hasOfflineDevices != e.hasOff { failures.append("\(c.label): offline list \(summary.hasOfflineDevices), dashboard \(e.hasOff)") }
            if (e.hasOff ? DashboardSummary.offlineListHint : "") != e.title { failures.append("\(c.label): the dashboard's hint is \"\(e.title)\"") }
            if summary.total != c.devices.count || summary.online != c.expected.grid.count || summary.isReconnecting { failures.append("\(c.label): counts \(summary.online)/\(summary.total)") }
            if summary != DashboardSummary(total: c.devices.count, online: c.devices.filter(\.online).count) { failures.append("\(c.label): the two initialisers disagree") }
        }
        DashFixture.report(failures, of: grid.cases.count)
    }

    @Test func reconnectingReplacesTheSummary() {
        var failures = [String]()
        for c in grid.cases {
            let summary = DashboardSummary(devices: c.devices, isReconnecting: true), e = c.expected.reconnecting
            if summary.text != e.text || summary.shortText != e.short || summary.compactText != (e.full ? e.short : e.text + e.short) || !summary.isReconnecting {
                failures.append("\(c.label): \"\(summary.text)\" / \"\(summary.shortText)\" / \"\(summary.compactText)\", dashboard \"\(e.text)\" / \"\(e.short)\"")
            }
            // The grid under the summary does not change while the stream is down.
            if summary.emptyState != DashboardSummary(devices: c.devices).emptyState || summary.hasOfflineDevices != c.expected.summary.hasOff { failures.append("\(c.label): reconnecting changed more than the text") }
        }
        DashFixture.report(failures, of: grid.cases.count)
        #expect(DashboardSummary.reconnectingText == "Reconnecting to hub\u{2026}")
    }

    @Test func emptyStates() throws {
        var seen = Set<String>()
        for c in grid.cases {
            let state = DashboardSummary(devices: c.devices).emptyState
            guard let expected = c.expected.empty else {
                #expect(state == nil, "\(c.label)")
                continue
            }
            if expected.small {
                #expect(state == .allOffline, "\(c.label)")
                #expect(state?.title == nil && state?.message == expected.text, "\(c.label)")
                seen.insert("offline")
            } else {
                #expect(state == .noDevices, "\(c.label)")
                #expect(state?.title == expected.title, "\(c.label)")
                // The dashboard's instruction is about its own "+" button; the app's says where devices are added from.
                #expect(expected.text == "Click the + button (Add device) at the top and run the command on each PC you want to monitor.")
                #expect(state?.message == "Devices are added from the hub: open its dashboard, choose Add device (+) and run the command on each PC you want to monitor.")
                seen.insert("none")
            }
        }
        #expect(seen == ["offline", "none"])
        #expect(DashboardEmptyState.allOffline.message == "All devices are offline.")
        #expect(DashboardEmptyState.noDevices.title == "No devices yet")
    }

    @Test func cardsAreOrderedLikeTheGrid() {
        var failures = [String]()
        for c in grid.cases {
            let online = DashboardOrder.online(c.devices, locale: enUS).map(\.id)
            if online != c.expected.grid { failures.append("\(c.label): \(names(online, c.devices)), dashboard \(names(c.expected.grid, c.devices))") }
            let all = DashboardOrder.sorted(c.devices, locale: enUS)
            if all.filter(\.online).map(\.id) != online || Set(all.map(\.id)) != Set(c.devices.map(\.id)) || all.count != c.devices.count { failures.append("\(c.label): sorted() and online() disagree") }
        }
        DashFixture.report(failures, of: grid.cases.count)
    }

    @Test func namesWithAccentsSortAsInABrowser() {
        var failures = [String]()
        for c in grid.accented {
            let sorted = DashboardOrder.sorted(c.devices, locale: enUS).map(\.id)
            if sorted != c.expected { failures.append("\(c.label): \(names(sorted, c.devices)), dashboard \(names(c.expected, c.devices))") }
        }
        DashFixture.report(failures, of: grid.accented.count)
    }

    private func names(_ ids: [String], _ devices: [Device]) -> String {
        ids.map { id in devices.first { $0.id == id }?.name ?? "<\(id)>" }.joined(separator: " < ")
    }

    @Test func offlineList() {
        var failures = [String]()
        var rows = 0, wakeable = 0
        for c in grid.cases {
            let list = OfflineDeviceList(devices: c.devices, latestVersions: c.latestVersions, now: c.now, locale: enUS), e = c.expected.offline
            if e.heading != OfflineDeviceList.title { failures.append("\(c.label): heading \(e.heading)") }
            if list.rows.map(\.id) != e.rows.map(\.id) {
                failures.append("\(c.label): \(names(list.rows.map(\.id), c.devices)), dashboard \(names(e.rows.map(\.id), c.devices))")
                continue
            }
            if list.isEmpty != e.rows.isEmpty || list.isEmpty == c.expected.summary.hasOff { failures.append("\(c.label): isEmpty \(list.isEmpty)") }
            for (row, expected) in zip(list.rows, e.rows) {
                rows += 1
                if row.name != expected.name { failures.append("\(c.label), \(row.id): name \"\(row.name)\", dashboard \"\(expected.name)\"") }
                if row.subtitle != expected.subtitle { failures.append("\(c.label), \(row.id): \"\(row.subtitle)\", dashboard \"\(expected.subtitle)\"") }
                if row.canWake != (expected.wake != nil) { failures.append("\(c.label), \(row.id): wake \(row.canWake)") }
                if expected.title != OfflineDeviceList.rowHint { failures.append("\(c.label), \(row.id): row hint \(expected.title)") }
                if let wake = expected.wake {
                    wakeable += 1
                    if wake.text != WakeButton.idle.title || wake.title != WakeButton.hint { failures.append("\(c.label), \(row.id): wake button \(wake.text) / \(wake.title)") }
                }
                guard let device = c.devices.first(where: { $0.id == row.id }) else { continue }
                if row != OfflineDeviceRow(device: device, latestVersions: c.latestVersions, now: c.now) { failures.append("\(c.label), \(row.id): the list and the row initialiser disagree") }
            }
        }
        DashFixture.report(failures, of: rows)
        #expect(rows > 60 && wakeable > 5)
    }

    @Test func wakeButtonTexts() {
        // $('#offPop') click handler: btn.disabled = true; btn.textContent = 'Sending…'; … btn.textContent = r?.ok ? 'Sent ✓' : 'Failed';
        #expect(WakeButton.allCases.map(\.title) == ["Wake", "Sending\u{2026}", "Sent \u{2713}", "Failed"])
        #expect(WakeButton.allCases.map(\.isEnabled) == [true, false, false, false])
    }

    // MARK: Menu

    struct Menu: Decodable {
        struct Item: Decodable {
            let action: String
            let text: String
            let danger: Bool
        }

        struct Labels: Decodable {
            let options: String
            let grip: String
            let chart: String
            let range: String
            let details: String
            let offlineRow: String
            let offlineOptions: String
        }

        struct Prompt: Decodable {
            let message: String
            let value: String?
        }

        struct Case: Decodable {
            let device: Device
            let prompt: Prompt
            let confirm: String
        }

        let items: [Item]
        let labels: Labels
        let cases: [Case]
    }

    @Test func deviceMenu() throws {
        let menu = try DashFixture.decode(Menu.self, "dashboard/menu.json")
        #expect(DeviceMenu.items.map(\.rawValue) == menu.items.map(\.action))
        #expect(DeviceMenu.items.map(\.title) == menu.items.map(\.text))
        #expect(DeviceMenu.items.map(\.isDestructive) == menu.items.map(\.danger))
        #expect(DeviceMenu.Item.allCases == DeviceMenu.items)
        #expect(DeviceMenu.buttonLabel == menu.labels.options && DeviceMenu.buttonLabel == menu.labels.offlineOptions)
        #expect(DeviceCardText.reorderHandleLabel == menu.labels.grip)
        #expect(DeviceCardText.chartHint == menu.labels.chart && OfflineDeviceList.rowHint == menu.labels.offlineRow)
        #expect(DeviceCardText.rangePickerLabel == menu.labels.range)
        #expect(DeviceCardText.details == menu.labels.details)
        #expect(menu.cases.count >= 8)
        for c in menu.cases {
            #expect(DeviceMenu.renamePrompt == c.prompt.message)
            // prompt('Device name', d.name): the field starts out with the device's name.
            #expect(c.device.name == c.prompt.value)
            #expect(DeviceMenu.removeConfirmation(for: c.device) == c.confirm)
            #expect(DeviceMenu.removeConfirmation(name: c.device.name ?? "") == c.confirm)
        }
    }

    // MARK: Rename

    struct Rename: Decodable {
        struct Meta: Decodable {
            let max: Int
        }

        struct Row: Decodable {
            let input: [UInt16]
            let output: [UInt16]?
        }

        let meta: Meta
        let rows: [Row]
    }

    @Test func renamingKeepsWhatTheHubKeeps() throws {
        let rename = try DashFixture.decode(Rename.self, "dashboard/rename.json")
        #expect(DeviceRename.maxLength == rename.meta.max)
        var failures = [String]()
        var cut = 0, refused = 0
        for row in rename.rows {
            let input = String(decoding: row.input, as: UTF16.self)
            #expect(Array(input.utf16) == row.input, "The fixture holds an input a Swift string cannot")
            // A name the hub cut through a character holds half a surrogate pair; over the wire, and
            // in a Swift string, that half is U+FFFD.
            let expected = row.output.map { String(decoding: $0, as: UTF16.self) }
            let stored = DeviceRename.stored(for: input)
            if stored != expected { failures.append("\(row.input) is stored as \(stored.map { Array($0.utf16) }.map(String.init(describing:)) ?? "nothing"), the hub keeps \(row.output.map(String.init(describing:)) ?? "nothing")") }
            if DeviceRename.isAltered(input) != (expected != input) { failures.append("\(row.input): isAltered \(DeviceRename.isAltered(input))") }
            if row.output == nil { refused += 1 }
            if let output = row.output, output.count == rename.meta.max, row.input.count > rename.meta.max { cut += 1 }

            // What the app sends is something the hub stores as it is.
            let sendable = DeviceRename.sendable(input)
            if (sendable == nil) != (expected == nil) { failures.append("\(row.input): sendable \(sendable ?? "nil") but the hub keeps \(expected ?? "nil")") }
            if let sendable {
                if DeviceRename.stored(for: sendable) != sendable { failures.append("\(row.input): the hub would change the sendable name \(Array(sendable.utf16))") }
                if sendable.utf16.count > rename.meta.max || sendable.unicodeScalars.contains("\u{FFFD}") != input.unicodeScalars.contains("\u{FFFD}") { failures.append("\(row.input): sendable name \(Array(sendable.utf16)) is too long or broken") }
                // It is the stored name, or the stored name without its cut-off last character and the space before it.
                if let expected, !expected.hasPrefix(sendable) { failures.append("\(row.input): sendable \(Array(sendable.utf16)) is not the start of what the hub keeps") }
            }
        }
        DashFixture.report(failures, of: rename.rows.count)
        #expect(cut >= 8 && refused >= 5)
    }

    @Test func renameExamples() {
        #expect(DeviceRename.stored(for: "  Lab PC \n") == "Lab PC")
        #expect(DeviceRename.stored(for: "\t\u{7F} ") == nil)
        #expect(DeviceRename.sendable("   ") == nil)
        #expect(DeviceRename.sendable(" Büro\u{0}-PC ") == "Büro-PC")
        #expect(!DeviceRename.isAltered("Lab PC") && DeviceRename.isAltered(" Lab PC"))
        let long = String(repeating: "x", count: 59) + "\u{1F4BB}"
        #expect(DeviceRename.stored(for: long) == String(repeating: "x", count: 59) + "\u{FFFD}")
        #expect(DeviceRename.sendable(long) == String(repeating: "x", count: 59))
        #expect(DeviceRename.sendable(String(repeating: "x", count: 58) + "  tail") == String(repeating: "x", count: 58))
    }
}
