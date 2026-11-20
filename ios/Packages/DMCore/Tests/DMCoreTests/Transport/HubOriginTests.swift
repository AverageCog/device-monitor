import Foundation
import Testing
@testable import DMCore

@Suite struct HubOriginTests {
    struct Vectors: Decodable {
        struct Origin: Decodable { let input: String; let origin: String? }
        struct Invitation: Decodable {
            struct Parsed: Decodable { let origin: String; let code: String }
            let input: String
            let parsed: Parsed?
        }

        let origins: [Origin]
        let invitations: [Invitation]
    }

    static func vectors() throws -> Vectors {
        try JSONDecoder().decode(Vectors.self, from: Fixture.data("transport/origin-vectors.json"))
    }

    @Test func acceptsAndNormalises() throws {
        let cases: [(String, String, String, Int?)] = [
            ("https://hub.example", "https://hub.example", "hub.example", nil),
            ("https://hub.example/", "https://hub.example", "hub.example", nil),
            ("https://hub.example:8443", "https://hub.example:8443", "hub.example", 8443),
            ("https://hub.example:8443/", "https://hub.example:8443", "hub.example", 8443),
            ("https://hub.example:443", "https://hub.example", "hub.example", nil),
            ("HTTPS://HUB.EXAMPLE", "https://hub.example", "hub.example", nil),
            ("Https://Hub.Example:7777/", "https://hub.example:7777", "hub.example", 7777),
            ("https://my-pc.tailnet-1234.ts.net", "https://my-pc.tailnet-1234.ts.net", "my-pc.tailnet-1234.ts.net", nil),
            ("https://xn--bcher-kva.example", "https://xn--bcher-kva.example", "xn--bcher-kva.example", nil),
            ("https://127.0.0.1:7443", "https://127.0.0.1:7443", "127.0.0.1", 7443),
            ("https://192.168.1.20", "https://192.168.1.20", "192.168.1.20", nil),
            ("https://localhost:7443", "https://localhost:7443", "localhost", 7443),
            ("https://hub.example:1", "https://hub.example:1", "hub.example", 1),
            ("https://hub.example:65535", "https://hub.example:65535", "hub.example", 65535),
            ("https://[::1]", "https://[::1]", "[::1]", nil),
            ("https://[::1]:8443", "https://[::1]:8443", "[::1]", 8443),
            ("https://[0:0:0:0:0:0:0:1]", "https://[::1]", "[::1]", nil),
            ("https://[2001:DB8::1]", "https://[2001:db8::1]", "[2001:db8::1]", nil),
            ("https://[2001:db8:0:0:1:0:0:1]", "https://[2001:db8::1:0:0:1]", "[2001:db8::1:0:0:1]", nil),
            ("https://[2001:0db8:0000:0000:0000:0000:0000:0001]", "https://[2001:db8::1]", "[2001:db8::1]", nil),
            ("https://[::ffff:192.168.1.5]", "https://[::ffff:c0a8:105]", "[::ffff:c0a8:105]", nil),
            ("https://[::]", "https://[::]", "[::]", nil),
            ("https://[1::]", "https://[1::]", "[1::]", nil),
            ("https://[1:0:0:2:0:0:0:3]", "https://[1:0:0:2::3]", "[1:0:0:2::3]", nil),
            ("https://[1:2:3:4:5:6:7:8]", "https://[1:2:3:4:5:6:7:8]", "[1:2:3:4:5:6:7:8]", nil),
        ]
        for (input, string, host, port) in cases {
            let origin = try HubOrigin(input)
            #expect(origin.string == string, "\(input)")
            #expect(origin.host == host, "\(input)")
            #expect(origin.port == port, "\(input)")
            #expect(origin.description == string)
            // The canonical form is a fixed point.
            #expect(try HubOrigin(string) == origin)
        }
    }

    @Test func rejectsEverythingElse() {
        let hostile = [
            "", " ", "hub.example", "//hub.example", "http://hub.example", "http://127.0.0.1:7777", "http://localhost:7777",
            "ftp://hub.example", "wss://hub.example", "javascript:alert(1)", "https:hub.example", "https:/hub.example", "https:\\\\hub.example",
            // userinfo
            "https://user@hub.example", "https://user:pw@hub.example", "https://:pw@hub.example", "https://@hub.example",
            "https://hub.example\\@evil.example", "https://evil.example\\.hub.example",
            // path, query, fragment
            "https://hub.example/path", "https://hub.example//", "https://hub.example/?", "https://hub.example/?q=1", "https://hub.example/#",
            "https://hub.example/#frag", "https://hub.example?x", "https://hub.example#x", "https://hub.example\\",
            // host
            "https://", "https:///", "https://:443", "https://hub_example", "https://hub.example.", "https://hub..example", "https://.hub.example",
            "https://bücher.example", "https://例え.テスト", "https://ＨＵＢ.example", "https://hub。example", "https://hub.example\u{200B}",
            "https://ⓗub.example", "https://hub%2eexample", "https://hub.example%2f", "https://hub.example%00",
            "https://hub .example", " https://hub.example", "https://hub.example ", "https://hub.example\n", "https://hub\t.example",
            "https://" + String(repeating: "a", count: 64) + ".example", "https://" + String(repeating: "a.", count: 127) + "example",
            // numbers that a URL parser would rewrite into a different address
            "https://1.2.3", "https://1.2.3.4.5", "https://0x7f.0.0.1", "https://017.0.0.1", "https://256.1.1.1", "https://127.1",
            "https://2130706433", "https://1.2.3.04", "https://127.0.0.1.", "https://example.0x10", "https://example.1",
            // port
            "https://hub.example:", "https://hub.example:0", "https://hub.example:65536", "https://hub.example:080", "https://hub.example:8443x",
            "https://hub.example:-1", "https://hub.example:+80", "https://hub.example:443:443", "https://hub.example:999999",
            // IPv6
            "https://[::1", "https://::1", "https://[::1]]", "https://[:::1]", "https://[1::2::3]", "https://[12345::1]", "https://[::1]:",
            "https://[::1]x", "https://[::g]", "https://[1.2.3.4]", "https://[]", "https://[:]", "https://[fe80::1%25en0]", "https://[fe80::1%en0]",
            "https://[0:0:0:0:0:0:0:0:1]", "https://[::ffff:192.168.01.5]",
        ]
        for input in hostile {
            #expect(throws: HubError.invalidOrigin, "\(input.debugDescription)") { try HubOrigin(input) }
        }
    }

    /// Whatever this parser accepts, the hub's own parser accepts and serialises identically. The
    /// origin string is signed in the rotation proof, so a difference here would break recovery.
    @Test func neverDisagreesWithTheHubsParser() throws {
        let rows = try Self.vectors().origins
        #expect(rows.count >= 120)
        var accepted = 0
        for row in rows {
            guard let ours = try? HubOrigin(row.input) else { continue }
            accepted += 1
            #expect(ours.string == row.origin, "\(row.input.debugDescription)")
        }
        #expect(accepted >= 25)
    }

    @Test func codableUsesTheCanonicalString() throws {
        let origin = try HubOrigin("https://Hub.Example:8443/")
        let data = try JSONEncoder().encode([origin])
        #expect(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/") == #"["https://hub.example:8443"]"#)
        #expect(try JSONDecoder().decode([HubOrigin].self, from: data) == [origin])
        for stored in ["https://hub.example:8443/", "https://HUB.example:8443", "https://hub.example:443", "http://hub.example", "https://[0:0:0:0:0:0:0:1]", ""] {
            let json = try JSONEncoder().encode([stored])
            #expect(throws: (any Error).self, "\(stored)") { try JSONDecoder().decode([HubOrigin].self, from: json) }
        }
    }

    @Test func buildsURLsOnlyOnItself() throws {
        let origin = try HubOrigin("https://hub.example:8443")
        #expect(origin.url(path: "/api/info")?.absoluteString == "https://hub.example:8443/api/info")
        #expect(origin.url(path: "/api/energy", query: "bounds=1,2")?.absoluteString == "https://hub.example:8443/api/energy?bounds=1,2")
        let v6 = try HubOrigin("https://[::1]:7443")
        let url = try #require(v6.url(path: "/api/stream"))
        #expect(url.absoluteString == "https://[::1]:7443/api/stream")
        #expect(url.port == 7443)
        // Anything URL would have to rewrite is refused rather than sent somewhere unexpected.
        #expect(origin.url(path: "/a b") == nil)
        #expect(origin.url(path: "/é") == nil)
    }
}
