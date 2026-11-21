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
            let range = HistoryRange.resolve(stored: row.stored)
            let window = HistoryWindow(range: range, now: start)
            #expect(same(window, row.window), "stored \(row.stored ?? "nothing") opens \(describe(window))")
            #expect(row.requests == [url(window.request(forWidth: 900))])
            #expect(HistoryRange.allCases.map(\.id) == row.header.ranges.map(\.id))
            #expect(HistoryRange.allCases.map(\.label) == row.header.ranges.map(\.label))
            #expect(HistoryRange.allCases.map { $0 == window.selectedRange } == row.header.ranges.map(\.on))
            #expect(HistoryRange.allCases.map(\.duration) == row.ranges.map(\.ms) && HistoryRange.allCases.map(\.id) == row.ranges.map(\.id))
            #expect(window.showsReset != row.header.resetHidden && HistoryWindow.resetTitle == row.header.resetLabel)
            #expect(window.span == range.duration)
        }
        #expect(HistoryRange.default == .sixHours && HistoryWindow(now: start).range == .sixHours)
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
                window.select(try #require(HistoryRange(rawValue: step.range ?? "")), now: step.now)
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

    @Test func zoomRules() {
        let window = HistoryWindow(range: .oneHour, now: 3_600_000)
        // Less than a minute left: refused, in either direction.
        #expect(window.zoomed(to: 100_000, 159_999) == nil)
        #expect(window.zoomed(to: 100_000, 160_000)?.span == 60_000)
        #expect(window.zoomed(to: 160_000, 100_000) == window.zoomed(to: 100_000, 160_000))
        // Cut to the window.
        let clipped = window.zoomed(to: -500_000, 9_000_000)
        #expect(clipped?.from == 0 && clipped?.to == 3_600_000 && clipped?.isZoomed == true && clipped?.range == .oneHour)
        #expect(window.zoomed(to: 3_590_000, 4_000_000) == nil)
        // A drag of eight points or less is a tap.
        #expect(HistoryWindow.minimumDrag == 8 && HistoryWindow.minimumSpan == 60_000)
        #expect(window.zoomed(byDragFrom: 100, to: 108, chartWidth: 900) == nil && window.zoomed(byDragFrom: 108, to: 100, chartWidth: 900) == nil)
        #expect(window.zoomed(byDragFrom: 100, to: 400, chartWidth: 900) == window.zoomed(byDragFrom: 400, to: 100, chartWidth: 900))
        #expect(window.zoomed(byDragFrom: 100, to: 400, chartWidth: 900)?.isZoomed == true)

        var zoomed = window.zoomed(to: 1_000_000, 2_000_000)!
        #expect(zoomed.selectedRange == nil && zoomed.showsReset)
        // The timer leaves a zoomed window alone; a double tap resets it, once.
        let refreshedWhileZoomed = zoomed.refresh(now: 5_000_000)
        #expect(!refreshedWhileZoomed && zoomed.from == 1_000_000)
        let reset = zoomed.resetIfZoomed(now: 5_000_000)
        #expect(reset && !zoomed.isZoomed && zoomed.to == 5_000_000 && zoomed.from == 1_400_000)
        let resetAgain = zoomed.resetIfZoomed(now: 6_000_000)
        #expect(!resetAgain && zoomed.to == 5_000_000)
        let refreshed = zoomed.refresh(now: 6_000_000)
        #expect(refreshed && zoomed.to == 6_000_000 && zoomed.span == 3_600_000)
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
        #expect(HistoryWindow.points(forWidth: .nan) == 900 && HistoryWindow.points(forWidth: .infinity) == 1200 && HistoryWindow.points(forWidth: -40) == 200)
        // The edges are sent as whole milliseconds.
        let zoomed = HistoryWindow(range: .day, now: 86_400_000).zoomed(to: 1000.5, 70_000.49)
        #expect(zoomed?.request(forWidth: 390) == HistoryRequest(from: 1001, to: 70_000, points: 390))
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
