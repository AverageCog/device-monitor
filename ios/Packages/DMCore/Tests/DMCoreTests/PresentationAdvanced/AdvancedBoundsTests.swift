import Foundation
import Testing
@testable import DMCore

/// advBounds against bounds.json: the dashboard's function run in Node under 23 time zones, at
/// instants spread around every clock change of 2026 and 2027.
@Suite struct AdvancedBoundsTests {
    struct BoundsFile: Decodable {
        /// `[first edge, [gap in minutes, how many times], …]`
        struct Packed: Decodable {
            let edges: [Double]

            init(from decoder: Decoder) throws {
                var items = try decoder.unkeyedContainer()
                var edges = [try items.decode(Double.self)]
                while !items.isAtEnd {
                    var run = try items.nestedUnkeyedContainer()
                    let gap = try run.decode(Double.self), count = try run.decode(Int.self)
                    for _ in 0..<count { edges.append(edges[edges.count - 1] + gap * 60_000) }
                }
                self.edges = edges
            }
        }

        /// `[now, bounds for 24h, for 7d, for 30d]`
        struct Row: Decodable {
            let now: Double
            let bounds: [Packed]

            init(from decoder: Decoder) throws {
                var items = try decoder.unkeyedContainer()
                now = try items.decode(Double.self)
                bounds = [try items.decode(Packed.self), try items.decode(Packed.self), try items.decode(Packed.self)]
            }
        }

        struct Zone: Decodable {
            let tz: String
            /// `[instant, offset before in minutes, offset after]`
            let transitions: [[Double]]
            let rows: [Row]
        }

        let tzdata: String
        let zones: [Zone]
    }

    private static let loaded = Result { try JSONDecoder().decode(BoundsFile.self, from: try Fixture.data("presentation/advanced/bounds.json")) }
    private static let ranges: [AdvancedRange] = [.day, .week, .month]

    private func iso(_ t: Double, _ zone: TimeZone) -> String {
        Date(timeIntervalSince1970: t / 1000).formatted(Date.ISO8601FormatStyle(timeZone: zone).year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }

    /// Whether this machine's time zone data has the clock changes Node saw for a zone. Where it
    /// does not (rules change, and the two ship different tzdata releases), comparing bounds would
    /// test tzdata versions rather than the port, so such a zone is left out.
    private func agrees(_ zone: BoundsFile.Zone, _ tz: TimeZone) -> Bool {
        zone.transitions.allSatisfy { change in
            let at = Date(timeIntervalSince1970: change[0] / 1000)
            return Double(tz.secondsFromGMT(for: at.addingTimeInterval(-0.001))) == change[1] * 60 && Double(tz.secondsFromGMT(for: at)) == change[2] * 60
        }
    }

    private func comparableZones() throws -> [(zone: BoundsFile.Zone, tz: TimeZone)] {
        try Self.loaded.get().zones.compactMap { zone in
            guard let tz = TimeZone(identifier: zone.tz), agrees(zone, tz) else { return nil }
            return (zone, tz)
        }
    }

    @Test func timeZoneDataAgreesWithNodeForNearlyEveryZone() throws {
        let all = try Self.loaded.get().zones, comparable = try comparableZones(), tzdata = try Self.loaded.get().tzdata
        #expect(all.count >= 22)
        #expect(comparable.count >= all.count - 3, "only \(comparable.map(\.zone.tz)) agree with Node's tzdata \(tzdata)")
        // The zones with long-settled rules must be among them, clock changes and all.
        for name in ["America/Los_Angeles", "America/New_York", "Europe/London", "Europe/Berlin", "Australia/Sydney", "Australia/Lord_Howe", "Asia/Kolkata", "UTC"] {
            #expect(comparable.contains { $0.zone.tz == name }, "\(name)")
        }
        #expect(comparable.filter { !$0.zone.transitions.isEmpty }.count >= 10)
    }

    @Test func boundsMatchTheDashboardInEveryZone() throws {
        let fixture = try Self.loaded.get()
        var failures: [String] = [], compared = 0
        for (zone, tz) in try comparableZones() {
            for row in zone.rows {
                for (range, expected) in zip(Self.ranges, row.bounds) {
                    compared += 1
                    let ours = range.bounds(now: row.now, timeZone: tz)
                    guard ours != expected.edges else { continue }
                    let at = Array(zip(ours, expected.edges)).firstIndex { $0 != $1 } ?? min(ours.count, expected.edges.count)
                    failures.append("\(zone.tz) \(range.rawValue) at \(iso(row.now, tz)): edge \(at) is \(at < ours.count ? iso(ours[at], tz) : "missing"), the dashboard has \(at < expected.edges.count ? iso(expected.edges[at], tz) : "none") (\(ours.count) vs \(expected.edges.count) edges)")
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.count) of \(compared) differ (Node's tzdata is \(fixture.tzdata)):\n\(failures.prefix(20).joined(separator: "\n"))")
        #expect(compared > 5000)
    }

    @Test func requestBoundsAreWhatTheHubAccepts() throws {
        var repaired = 0, nowOutsideLastBucket = 0
        for (zone, tz) in try comparableZones() {
            for row in zone.rows {
                for (range, expected) in zip(Self.ranges, row.bounds) {
                    let request = range.requestBounds(now: row.now, timeZone: tz)
                    // server.js: at least two edges, strictly increasing, no more than 32 days in all.
                    let ok = request.count >= 2 && zip(request, request.dropFirst()).allSatisfy { $0 < $1 } && request[request.count - 1] - request[0] <= 32 * 86_400_000
                    #expect(ok, "\(zone.tz) \(range.rawValue) at \(iso(row.now, tz))")
                    let dashboardIsValid = zip(expected.edges, expected.edges.dropFirst()).allSatisfy { $0 < $1 }
                    if dashboardIsValid {
                        #expect(request == expected.edges)
                    } else {
                        repaired += 1
                        // Only the repeated edge of the skipped hour goes; the span stays.
                        #expect(request.count == expected.edges.count - 1)
                        #expect(request.first == expected.edges.first && request.last == expected.edges.last)
                        #expect(Set(request) == Set(expected.edges))
                    }
                    // "Now" is in the last bucket, except for the minutes after a clock change that is
                    // not on the hour (Lord Howe, Chatham), where the dashboard's last hour starts just
                    // after it or ends just before it. Those are counted, not hidden.
                    #expect(request[0] <= row.now)
                    if !(request[request.count - 2] <= row.now && row.now < request[request.count - 1]) {
                        nowOutsideLastBucket += 1
                        #expect(zone.tz == "Australia/Lord_Howe" || zone.tz == "Pacific/Chatham", "\(zone.tz) \(range.rawValue) at \(iso(row.now, tz))")
                        #expect(range == .day)
                    }
                }
            }
        }
        #expect(repaired > 100)
        #expect(nowOutsideLastBucket < 30)
    }

    @Test func rangeOptionsAreTheDashboardsButtons() throws {
        let page = try AdvancedFixtures.page()
        #expect(AdvancedRange.allCases.map(\.rawValue) == page.rangeButtons.map { $0[0] })
        #expect(AdvancedRange.allCases.map(\.label) == page.rangeButtons.map { $0[1] })
        #expect(AdvancedRange.default.rawValue == page.defaultRange)
        #expect(AdvancedRange(stored: nil) == .week)
        #expect(AdvancedRange(stored: "24h") == .day)
        #expect(AdvancedRange(stored: "30d") == .month)
        #expect(AdvancedRange(stored: "1h") == .week)
        #expect(AdvancedRange.allCases.map(\.bucketCount) == [24, 7, 30])
    }

    @Test func fractionsOfAMillisecondAreDropped() throws {
        let tz = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = 1_795_214_200_000.0
        #expect(AdvancedRange.day.bounds(now: now + 0.75, timeZone: tz) == AdvancedRange.day.bounds(now: now, timeZone: tz))
        // One millisecond before the hour still belongs to the hour that is ending.
        let hour = 1_795_215_600_000.0
        #expect(AdvancedRange.day.bounds(now: hour - 0.5, timeZone: tz).last == hour)
        #expect(AdvancedRange.day.bounds(now: hour, timeZone: tz).last == hour + 3_600_000)
    }

    @Test func liveFiguresRedrawAtMostOnceASecond() {
        #expect(AdvancedRefresh.reloadInterval == 60)
        #expect(AdvancedRefresh.liveInterval == 1)
        var throttle = AdvancedRefresh.LiveThrottle()
        let first = throttle.reportArrived(now: 10_000)
        #expect(first == 11_000)
        let second = throttle.reportArrived(now: 10_400)
        let third = throttle.reportArrived(now: 10_999)
        #expect(second == nil && third == nil)
        #expect(throttle.due == 11_000)
        throttle.redrawn()
        #expect(throttle.due == nil)
        let next = throttle.reportArrived(now: 11_050)
        #expect(next == 12_050)
    }
}
