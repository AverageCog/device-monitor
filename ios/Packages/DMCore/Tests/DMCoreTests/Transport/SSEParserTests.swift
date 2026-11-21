import Foundation
import Testing
@testable import DMCore

@Suite struct SSEParserTests {
    static func text(_ frames: [Data]) -> [String] {
        frames.map { String(decoding: $0, as: UTF8.self) }
    }

    /// Feeds `stream` cut at the given offsets and returns every payload produced.
    static func feed(_ stream: Data, cuts: [Int]) throws -> [Data] {
        var parser = SSEParser()
        var out: [Data] = []
        var start = 0
        for cut in cuts.sorted() + [stream.count] where cut > start {
            out += try parser.feed(stream.subdata(in: start..<min(cut, stream.count)))
            start = min(cut, stream.count)
        }
        #expect(parser.pendingByteCount == 0 || !stream.suffix(2).elementsEqual([0x0A, 0x0A]))
        return out
    }

    @Test func parsesTheHubsFrames() throws {
        var parser = SSEParser()
        let frames = try parser.feed(Data(#"data: {"type":"snapshot","devices":[]}"#.utf8) + Data("\n\n".utf8) + Data(#"data: {"type":"status","online":{}}"#.utf8) + Data("\n\n".utf8))
        #expect(Self.text(frames) == [#"{"type":"snapshot","devices":[]}"#, #"{"type":"status","online":{}}"#])
        #expect(parser.pendingByteCount == 0)
        #expect(try parser.feed(Data()).isEmpty)
    }

    @Test func holdsAnIncompleteFrame() throws {
        var parser = SSEParser()
        #expect(try parser.feed(Data("data: {\"a\":".utf8)).isEmpty)
        #expect(try parser.feed(Data("1}".utf8)).isEmpty)
        #expect(try parser.feed(Data("\n".utf8)).isEmpty)
        #expect(parser.pendingByteCount == 14)
        #expect(Self.text(try parser.feed(Data("\ndata: next".utf8))) == ["{\"a\":1}"])
        #expect(parser.pendingByteCount == 10)
        #expect(Self.text(try parser.feed(Data("\n\n".utf8))) == ["next"])
    }

    @Test func ignoresLinesThatAreNotData() throws {
        var parser = SSEParser()
        let stream = ": keep-alive\n\nevent: message\nid: 7\ndata: one\nretry: 3000\n\nnot a field\n\ndata:two\n\ndata: \n\n\n\ndata: a\ndata: b\n\n"
        #expect(Self.text(try parser.feed(Data(stream.utf8))) == ["one", "two", "", "a\nb"])
        // Only one space after the colon belongs to the syntax.
        #expect(Self.text(try parser.feed(Data("data:  two spaces\n\n".utf8))) == [" two spaces"])
        #expect(Self.text(try parser.feed(Data("data\n\ndatax: no\n\nDATA: no\n\n".utf8))) == [])
    }

    @Test func everySplitPointGivesTheSameFrames() throws {
        let stream = Data("data: {\"name\":\"Zoë’s 漢字 😀 PC\"}\n\n: ping\n\ndata: {\"type\":\"status\"}\n\ndata: x\n\n".utf8)
        let expected = ["{\"name\":\"Zoë’s 漢字 😀 PC\"}", "{\"type\":\"status\"}", "x"]
        #expect(Self.text(try Self.feed(stream, cuts: [])) == expected)
        // One cut anywhere: inside a multi-byte character, between the two newlines, mid-prefix.
        for cut in 1..<stream.count {
            #expect(Self.text(try Self.feed(stream, cuts: [cut])) == expected, "cut at \(cut)")
        }
        // Two cuts anywhere.
        for first in stride(from: 1, to: stream.count, by: 3) {
            for second in stride(from: first + 1, to: stream.count, by: 5) {
                #expect(Self.text(try Self.feed(stream, cuts: [first, second])) == expected, "cuts at \(first), \(second)")
            }
        }
        // One byte at a time.
        #expect(Self.text(try Self.feed(stream, cuts: Array(1..<stream.count))) == expected)
    }

    @Test func randomChunkingGivesTheSameFrames() throws {
        var generator = SplitMix64(seed: 0x55E0_0001)
        var payloads: [String] = []
        var stream = Data()
        for index in 0..<400 {
            let length = Int(generator.next() % 600)
            let text = String((0..<length).map { _ in "aé漢😀 \"\\/{}:,0".randomElement(using: &generator)! })
            payloads.append("\(index):" + text)
            stream.append(Data("data: \(index):\(text)\n\n".utf8))
            if generator.next() % 5 == 0 { stream.append(Data(": comment\n\n".utf8)) }
        }
        for _ in 0..<20 {
            var parser = SSEParser()
            var out: [Data] = []
            var offset = 0
            while offset < stream.count {
                let size = min(stream.count - offset, 1 + Int(generator.next() % 4000))
                out += try parser.feed(stream.subdata(in: offset..<offset + size))
                offset += size
            }
            #expect(Self.text(out) == payloads)
            #expect(parser.pendingByteCount == 0)
        }
    }

    @Test func acceptsChunksThatAreSlices() throws {
        let padded = Data("xxxxdata: sliced\n\nyy".utf8)
        var parser = SSEParser()
        #expect(Self.text(try parser.feed(padded[4..<padded.count - 2])) == ["sliced"])
    }

    @Test func deliversAMultiMegabyteFrameInLinearTime() throws {
        let size = 24 * 1024 * 1024
        let body = Data(repeating: UInt8(ascii: "x"), count: size)
        var stream = Data("data: ".utf8)
        stream.append(body)
        stream.append(Data("\n\ndata: after\n\n".utf8))
        var parser = SSEParser()
        var out: [Data] = []
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            var offset = 0
            while offset < stream.count {
                let end = min(stream.count, offset + 16 * 1024)          // the size URLSession typically delivers
                out += try parser.feed(stream.subdata(in: offset..<end))
                offset = end
            }
        }
        #expect(out.count == 2)
        #expect(out.first?.count == size)
        #expect(out.first == body)
        #expect(Self.text([out[1]]) == ["after"])
        #expect(parser.pendingByteCount == 0)
        // Rescanning the buffer on every chunk would take minutes; a single pass takes milliseconds.
        #expect(elapsed < .seconds(5), "took \(elapsed)")
    }

    @Test func capsThePendingBuffer() throws {
        #expect(SSEParser.defaultLimit == 48 * 1024 * 1024)
        var parser = SSEParser(limit: 1024)
        #expect(try parser.feed(Data(repeating: 0x61, count: 1024)).isEmpty)
        #expect(throws: HubError.responseTooLarge) { try parser.feed(Data([0x61])) }
        // The parser is usable again afterwards, starting from nothing.
        #expect(parser.pendingByteCount == 0)
        #expect(Self.text(try parser.feed(Data("data: ok\n\n".utf8))) == ["ok"])

        // Complete frames do not count against the limit once delivered.
        var steady = SSEParser(limit: 64)
        for index in 0..<1000 {
            #expect(Self.text(try steady.feed(Data("data: frame \(index)\n\n".utf8))) == ["frame \(index)"])
        }
        // Like session.js, the check precedes extraction: a chunk that overflows is refused whole.
        var strict = SSEParser(limit: 16)
        #expect(throws: HubError.responseTooLarge) { try strict.feed(Data("data: 0123456789\n\ndata: x\n\n".utf8)) }
    }

    @Test func aRealSnapshotPrefixParses() throws {
        // What streamDashboard() writes: the frame arrives as many small writes.
        var parser = SSEParser()
        var out = try parser.feed(Data(#"data: {"type":"snapshot","devices":["#.utf8))
        out += try parser.feed(Data(#"{"id":"ws","name":"Workstation","online":true}"#.utf8))
        out += try parser.feed(Data(#",{"id":"nas","name":"NAS","online":false}"#.utf8))
        #expect(out.isEmpty)
        out += try parser.feed(Data("]}\n\n".utf8))
        let frame = try #require(out.first)
        let object = try #require(try JSONSerialization.jsonObject(with: frame) as? [String: Any])
        #expect(object["type"] as? String == "snapshot")
        #expect((object["devices"] as? [[String: Any]])?.count == 2)
    }
}
