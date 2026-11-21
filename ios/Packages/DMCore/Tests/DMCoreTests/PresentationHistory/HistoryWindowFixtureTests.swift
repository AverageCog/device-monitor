import Foundation
import Testing
@testable import DMCore

/// presentation/history/windows.json and headers.json: a session on the real history page (range
/// buttons, drags to zoom, double-clicks, the reset button, the 30-second timer) with the window
/// and the request after each step; and the device chips and heading for several fleets.
@Suite struct HistoryWindowFixtureTests {
    struct Windows: Decodable {
        struct Window: Decodable {
            let range: String
            let from: Double
            let to: Double
            let zoomed: Bool
        }

        struct RangeButton: Decodable {
            let id: String
            let label: String
            let on: Bool
        }

        struct Header: Decodable {
            let ranges: [RangeButton]
            let resetHidden: Bool
            let resetLabel: String
        }

        struct Duration: Decodable {
            let id: String
            let ms: Double
        }

        struct Stored: Decodable {
            let stored: String?
            let window: Window
            let header: Header
            let requests: [String]
            let ranges: [Duration]
        }

        struct Step: Decodable {
            struct Lit: Decodable {
                let on: [String]
                let resetHidden: Bool
            }

            let action: String
            let now: Double
            let width: Double
            let before: Window
            let after: Window
            let x1: Double?
            let x2: Double?
            let a: Double?
            let b: Double?
            let range: String?
            let requests: [String]
            let header: Lit
        }

        struct PointsFor: Decodable {
            let width: Double
            let points: Int
        }

        struct Meta: Decodable {
            let timer: Double
            let hint: String
        }

        let meta: Meta
        let stored: [Stored]
        let steps: [Step]
        let pointsFor: [PointsFor]
    }

    let windows: Windows
    /// The moment the recorded session started at.
    private let start = 1_795_213_953_000.0

    init() throws {
        windows = try DashFixture.decode(Windows.self, "history/windows.json")
    }

    private func same(_ window: HistoryWindow, _ expected: Windows.Window) -> Bool {
        window.range.id == expected.range && window.isZoomed == expected.zoomed && abs(window.from - expected.from) < 1e-6 && abs(window.to - expected.to) < 1e-6
    }

    private func describe(_ window: HistoryWindow) -> String {
        "\(window.range.id) \(window.from)…\(window.to)\(window.isZoomed ? " zoomed" : "")"
    }

    /// `/api/history/${id}?from=${Math.round(hv.from)}&to=${Math.round(hv.to)}&points=${w}`
    private func url(_ request: HistoryRequest) -> String {
        "/api/history/hist?from=\(JS.string(request.from))&to=\(JS.string(request.to))&points=\(request.points)"
    }

    @Test func rangesAndTheStoredChoice() {
        #expect(windows.stored.count == 10)
        for row in windows.stored {
            let range = HistoryPageRange.resolve(stored: row.stored)
            let window = HistoryWindow(range: range, now: start)
            #expect(same(window, row.window), "stored \(row.stored ?? "nothing") opens \(describe(window))")
            #expect(row.requests == [url(window.request(forWidth: 900))])
            #expect(HistoryPageRange.allCases.map(\.id) == row.header.ranges.map(\.id))
            #expect(HistoryPageRange.allCases.map(\.label) == row.header.ranges.map(\.label))
            #expect(HistoryPageRange.allCases.map { $0 == window.selectedRange } == row.header.ranges.map(\.on))
            #expect(HistoryPageRange.allCases.map(\.duration) == row.ranges.map(\.ms) && HistoryPageRange.allCases.map(\.id) == row.ranges.map(\.id))
            #expect(window.showsReset != row.header.resetHidden && HistoryWindow.resetTitle == row.header.resetLabel)
            #expect(window.span == range.duration)
        }
        #expect(HistoryPageRange.default == .sixHours && HistoryWindow(now: start).range == .sixHours)
    }

    @Test func aSessionOfZoomingAndResetting() throws {
        var window = HistoryWindow(range: .oneHour, now: start)
        var failures = [String]()
        var zooms = 0, refused = 0
        for (index, step) in windows.steps.enumerated() {
            let name = "step \(index) (\(step.action))"
            guard same(window, step.before) else {
                failures.append("\(name): starts from \(describe(window)), the dashboard from \(step.before)")
                break
            }
            var reloads = false
            switch step.action {
            case "drag":
                let x1 = try #require(step.x1), x2 = try #require(step.x2)
                // The times under the two ends of the drag, as hvT gave them.
                let layout = HistoryChartLayout(width: step.width, from: window.from, to: window.to)
                if abs(layout.time(atX: min(x1, x2)) - (step.a ?? .nan)) > 1e-6 || abs(layout.time(atX: max(x1, x2)) - (step.b ?? .nan)) > 1e-6 { failures.append("\(name): the drag covers other times than on the dashboard") }
                if let next = window.zoomed(byDragFrom: x1, to: x2, chartWidth: step.width) {
                    window = next
                    reloads = true
                    zooms += 1
                } else {
                    refused += 1
                }
            case "timer":
                reloads = window.refresh(now: step.now)
            case "doubleClick":
                reloads = window.resetIfZoomed(now: step.now)
            case "reset":
                window.reset(now: step.now)
                reloads = true
            case "range":
                window.select(try #require(HistoryPageRange(rawValue: step.range ?? "")), now: step.now)
                reloads = true
            default:
                failures.append("\(name): unknown action")
            }
            if !same(window, step.after) { failures.append("\(name): ends at \(describe(window)), the dashboard at \(step.after)") }
            if step.requests != (reloads ? [url(window.request(forWidth: step.width))] : []) { failures.append("\(name): \(reloads ? "asks for \(url(window.request(forWidth: step.width)))" : "asks for nothing"), the dashboard for \(step.requests)") }
            if step.header.on != (window.selectedRange.map { [$0.id] } ?? []) || step.header.resetHidden == window.showsReset { failures.append("\(name): range buttons or the reset button differ") }
        }
        DashFixture.report(failures, of: windows.steps.count)
        #expect(zooms >= 15 && refused >= 8)
    }

    @Test func theSessionCoversTheEdgesOfTheRules() {
        let drags = windows.steps.filter { $0.action == "drag" }
        func moved(_ step: Windows.Step) -> Double { abs((step.x2 ?? 0) - (step.x1 ?? 0)) }
        func selected(_ step: Windows.Step) -> Double { min(step.before.to, step.b ?? 0) - max(step.before.from, step.a ?? 0) }
        func zoomed(_ step: Windows.Step) -> Bool { !step.requests.isEmpty }
        // Eight points are a click whatever they span; a little more is a selection.
        #expect(drags.contains { moved($0) == 8 && selected($0) > 600_000 && !zoomed($0) })
        #expect(drags.contains { moved($0) > 8 && moved($0) < 9 && zoomed($0) })
        // Exactly a minute is enough; the next smaller selection is not.
        #expect(drags.contains { selected($0) == 60_000 && zoomed($0) })
        #expect(drags.contains { selected($0) < 60_000 && selected($0) > 59_999.99 && moved($0) > 8 && !zoomed($0) })
        // Selections reaching past either edge, and both.
        #expect(drags.contains { ($0.a ?? 0) < $0.before.from && zoomed($0) } && drags.contains { ($0.b ?? 0) > $0.before.to && zoomed($0) })
        #expect(drags.contains { ($0.x1 ?? 0) > ($0.x2 ?? 0) })
        // The timer with and without a zoom, a double-click with and without one.
        for action in ["timer", "doubleClick"] {
            #expect(windows.steps.contains { $0.action == action && $0.before.zoomed } && windows.steps.contains { $0.action == action && !$0.before.zoomed })
        }
    }

    @Test func zoomingByTimesMatchesZoomingByDrag() throws {
        var window = HistoryWindow(range: .oneHour, now: start)
        var compared = 0
        // Every drag that started from a whole range, on that range's own window.
        for step in windows.steps where step.action == "drag" && !step.before.zoomed {
            guard let x1 = step.x1, let x2 = step.x2, let a = step.a, let b = step.b else { continue }
            window = HistoryWindow(range: HistoryPageRange(rawValue: step.before.range) ?? .oneHour, now: step.before.to)
            // The same stretch given as times, in either order, is the same zoom.
            let byTimes = window.zoomed(to: a, b)
            #expect(byTimes == window.zoomed(to: b, a))
            if let byDrag = window.zoomed(byDragFrom: x1, to: x2, chartWidth: step.width) {
                let zoomed = try #require(byTimes)
                #expect(abs(zoomed.from - byDrag.from) < 1e-6 && abs(zoomed.to - byDrag.to) < 1e-6 && zoomed.isZoomed && zoomed.range == byDrag.range)
                compared += 1
            }
            #expect(window.zoomed(to: .nan, b) == nil && window.zoomed(to: a, .nan) == nil)
        }
        #expect(compared >= 5)
        #expect(window.fromDate == Date(hubTime: window.from) && window.toDate == Date(hubTime: window.to))
    }

    @Test func theTimerAndTheHint() {
        #expect(HistoryWindow.refreshInterval == windows.meta.timer)
        #expect(HistoryModel.pointerHint == windows.meta.hint)
        #expect(windows.meta.hint.hasSuffix(HistoryModel.bandsHint))
    }

    @Test func pointsFollowTheWidth() {
        #expect(windows.pointsFor.count >= 18)
        for row in windows.pointsFor {
            #expect(HistoryWindow.points(forWidth: row.width) == row.points, "\(row.width) wide")
        }
        // Widths no browser reports still give a number within the hub's limits.
        for width in [Double.nan, .infinity, -.infinity, -40, 1e300] {
            #expect((200...1200).contains(HistoryWindow.points(forWidth: width)), "\(width) wide")
        }
        // The session above has zoomed windows with fractional edges; they are asked for as whole milliseconds.
        #expect(windows.steps.contains { step in
            step.after.from != step.after.from.rounded() && step.requests.contains { $0.contains("from=\(JS.string(JS.round(step.after.from)))&") }
        })
    }

    // MARK: Chips and heading

    struct Headers: Decodable {
        struct Chip: Decodable, Equatable {
            let id: String
            let name: String
            let selected: Bool
            let online: Bool
        }

        struct Expected: Decodable {
            let chips: [Chip]
            let title: String
            let subtitle: String
        }

        struct Case: Decodable {
            let label: String
            let selected: String
            let devices: [Device]
            let expected: Expected
        }

        struct Button: Decodable {
            let label: String
            let devices: [Device]
            let last: String?
            let opens: String?
        }

        let cases: [Case]
        let button: [Button]
    }

    @Test func chipsAndHeading() throws {
        let headers = try DashFixture.decode(Headers.self, "history/headers.json")
        var failures = [String]()
        var unknown = 0
        for c in headers.cases {
            let name = "\(c.label), \(c.selected)"
            let chips = HistoryDeviceChipModel.chips(for: c.devices, selected: c.selected).map { Headers.Chip(id: $0.id, name: $0.name, selected: $0.isSelected, online: $0.isOnline) }
            if chips != c.expected.chips { failures.append("\(name): chips \(chips.map { $0.name + ($0.selected ? "*" : "") }), dashboard \(c.expected.chips.map { $0.name + ($0.selected ? "*" : "") })") }
            let header = HistoryHeaderModel(devices: c.devices, selected: c.selected)
            if header.title != c.expected.title || header.subtitle != c.expected.subtitle { failures.append("\(name): \"\(header.title)\" / \"\(header.subtitle)\", dashboard \"\(c.expected.title)\" / \"\(c.expected.subtitle)\"") }
            let device = c.devices.first { $0.id == c.selected }
            if header != HistoryHeaderModel(device: device) || header.isOnline != device?.online { failures.append("\(name): the two initialisers disagree") }
            if device == nil { unknown += 1 }
        }
        DashFixture.report(failures, of: headers.cases.count)
        #expect(unknown >= 3 && HistoryHeaderModel(device: nil).title == "Unknown device" && HistoryHeaderModel(device: nil).subtitle.isEmpty)

        #expect(headers.button.count >= 6)
        for b in headers.button {
            #expect(HistoryDeviceChipModel.defaultDevice(among: b.devices, last: b.last) == b.opens, "\(b.label)")
        }
    }
}
