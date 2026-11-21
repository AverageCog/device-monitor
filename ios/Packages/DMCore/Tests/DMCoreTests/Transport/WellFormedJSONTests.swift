import Foundation
import Testing
@testable import DMCore

/// `HubClient.wellFormedJSON`: what the hub's `JSON.stringify` writes for a string that `str()` in
/// `security.js` cut inside a surrogate pair, turned into JSON Foundation accepts.
@Suite struct WellFormedJSONTests {
    /// A row of `Fixtures/transport/json-vectors.json` (see `generate-json-vectors.cjs`).
    struct Row: Decodable {
        let note: String
        /// JSON text as the hub, or another serialiser, writes it.
        let json: String
        /// The same text with every unpaired surrogate escape replaced.
        let repaired: String
        /// Whether `json` parses in JavaScript.
        let valid: Bool
    }

    static func rows() throws -> [Row] {
        try JSONDecoder().decode([Row].self, from: Fixture.data("transport/json-vectors.json"))
    }

    /// The six characters of an escape as they appear in JSON text.
    static func escape(_ hex: String) -> String { "\\u" + hex }

    @Test func matchesTheVectorsMadeWithTheHubsOwnCode() throws {
        let rows = try Self.rows()
        #expect(rows.count >= 30)
        #expect(rows.filter { $0.json != $0.repaired }.count >= 18 && rows.filter { $0.json == $0.repaired }.count >= 8)
        for row in rows {
            let output = HubClient.wellFormedJSON(Data(row.json.utf8))
            #expect(output == Data(row.repaired.utf8), "\(row.note): \(String(decoding: output, as: UTF8.self))")
            #expect(HubClient.wellFormedJSON(output) == output, "\(row.note)")
            guard row.valid else { continue }
            #expect(throws: Never.self, "\(row.note)") {
                try JSONSerialization.jsonObject(with: output, options: .fragmentsAllowed)
            }
        }

        // What the result decodes to is what a browser shows: the half replaced by U+FFFD.
        func shown(_ note: String) throws -> String? {
            guard let row = rows.first(where: { $0.note == note }) else { return nil }
            return try JSONSerialization.jsonObject(with: HubClient.wellFormedJSON(Data(row.json.utf8)), options: .fragmentsAllowed) as? String
        }
        #expect(try shown("half a pair at the end") == "aaa\u{FFFD}")
        #expect(try shown("an escaped pair is left alone") == "😀")
        #expect(try shown("a backslash followed by the text of an escape") == "\\ud83d")
        struct Named: Decodable { let name: String }
        let label = try #require(rows.first { $0.note.hasPrefix("a dashboard label cut") })
        let name = try JSONDecoder().decode(Named.self, from: HubClient.wellFormedJSON(Data(label.json.utf8))).name
        #expect(name.hasPrefix(String(repeating: "x", count: 59)) && name.unicodeScalars.count <= 60)

        // A slice of a larger buffer, as a frame cut out of a stream may be.
        let half = try #require(rows.first { $0.note == "half a pair at the end" })
        let buffer = Data("data: ".utf8) + Data(half.json.utf8)
        #expect(HubClient.wellFormedJSON(buffer[6...]).elementsEqual(Data(half.repaired.utf8)))
    }

    /// Strings assembled from pieces whose meaning is known, so the expected text is worked out
    /// from the pieces and not by reading the bytes a second time.
    @Test func agreesWithAModelOverRandomStrings() throws {
        enum Kind { case text, high, low }
        let pieces: [(String, Kind)] = [
            ("a", .text), ("é", .text), ("😀", .text), (" ", .text), ("u", .text), ("d83d", .text), ("ude00", .text),
            ("\\\\", .text), ("\\\"", .text), ("\\n", .text), ("\\/", .text),
            (Self.escape("0041"), .text), (Self.escape("d7ff"), .text), (Self.escape("e000"), .text), (Self.escape("FFFD"), .text),
            (Self.escape("d83d"), .high), (Self.escape("DBFF"), .high), (Self.escape("d800"), .high),
            (Self.escape("de00"), .low), (Self.escape("DC00"), .low), (Self.escape("dfff"), .low),
        ]
        var generator = SplitMix64(seed: 0x4A50_4E00_0001)
        var repairs = 0, pairs = 0
        for _ in 0..<4000 {
            let chosen = (0..<Int.random(in: 0...12, using: &generator)).map { _ in pieces[Int.random(in: 0..<pieces.count, using: &generator)] }
            var expected = "\""
            var index = 0
            while index < chosen.count {
                let (text, kind) = chosen[index]
                if kind == .high, index + 1 < chosen.count, chosen[index + 1].1 == .low {
                    expected += text + chosen[index + 1].0
                    index += 2
                    pairs += 1
                    continue
                }
                if kind == .text {
                    expected += text
                } else {
                    expected += Self.escape("fffd")
                    repairs += 1
                }
                index += 1
            }
            expected += "\""
            let json = "\"" + chosen.map(\.0).joined() + "\""
            let output = HubClient.wellFormedJSON(Data(json.utf8))
            #expect(output == Data(expected.utf8), "\(json)")
            #expect(throws: Never.self, "\(json)") {
                try JSONSerialization.jsonObject(with: output, options: .fragmentsAllowed)
            }
        }
        #expect(repairs > 1000 && pairs > 100)
    }

    /// Truncated and garbled input is not JSON anyway; it must only never crash, read out of
    /// bounds or change length.
    @Test func neverCrashesOnTruncatedOrGarbledInput() throws {
        for row in try Self.rows() {
            let whole = Data(row.json.utf8)
            for length in stride(from: 0, through: whole.count, by: whole.count > 400 ? 7 : 1) {
                let cut = whole.prefix(length)
                let output = HubClient.wellFormedJSON(cut)
                #expect(output.count == cut.count)
                #expect(HubClient.wellFormedJSON(output) == output)
            }
        }
        let alphabet = Array("\\\\\\uuddd8c0fF\"x".utf8)
        var generator = SplitMix64(seed: 0x4A50_4E00_0002)
        for _ in 0..<4000 {
            let noise = Data((0..<Int.random(in: 0...40, using: &generator)).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
            let output = HubClient.wellFormedJSON(noise)
            #expect(output.count == noise.count)
            #expect(HubClient.wellFormedJSON(output) == output)
        }
        // Megabytes without a single escape pass straight through.
        let large = Data(repeating: UInt8(ascii: "a"), count: 4 * 1024 * 1024)
        #expect(HubClient.wellFormedJSON(large) == large)
    }
}
