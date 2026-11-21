import Foundation
import Testing
@testable import DMCore

@Suite struct InvitationTests {
    static let code = "vQZQ-sH2nBEYHfiE0uy58cZyG76jJ790eLJVZBZ_0p4"
    static let hub = "https://hub.example"

    static func problem(_ text: String) -> Invitation.Problem? {
        do {
            _ = try Invitation.parse(text)
            return nil
        } catch HubError.invalidInvitation(let problem) {
            return problem
        } catch {
            Issue.record("unexpected error \(error) for \(text.debugDescription)")
            return nil
        }
    }

    @Test func parsesWhatTheHubShows() throws {
        #expect(DMCore.invitationPath == "/mobile")
        let cases: [(String, String)] = [
            ("\(Self.hub)/mobile#join=\(Self.code)", "https://hub.example"),
            ("\(Self.hub):8443/mobile#join=\(Self.code)", "https://hub.example:8443"),
            ("https://my-pc.tailnet-1234.ts.net/mobile#join=\(Self.code)", "https://my-pc.tailnet-1234.ts.net"),
            ("https://192.168.1.20:7443/mobile#join=\(Self.code)", "https://192.168.1.20:7443"),
            ("https://[::1]:7443/mobile#join=\(Self.code)", "https://[::1]:7443"),
            ("HTTPS://HUB.EXAMPLE/mobile#join=\(Self.code)", "https://hub.example"),
            ("\(Self.hub):443/mobile#join=\(Self.code)", "https://hub.example"),
            // Only surrounding white space is forgiven: a paste often carries a newline.
            ("  \(Self.hub)/mobile#join=\(Self.code)\n", "https://hub.example"),
            ("\n\t\(Self.hub)/mobile#join=\(Self.code)  \r\n", "https://hub.example"),
            // The fragment is URL-encoded parameters.
            ("\(Self.hub)/mobile#x=1&join=\(Self.code)", "https://hub.example"),
            ("\(Self.hub)/mobile#join=\(Self.code)&x=1", "https://hub.example"),
            ("\(Self.hub)/mobile#&&join=\(Self.code)&", "https://hub.example"),
            ("\(Self.hub)/mobile#jo%69n=\(Self.code)", "https://hub.example"),
            ("\(Self.hub)/mobile#join=\(Self.code.replacingOccurrences(of: "-", with: "%2D").replacingOccurrences(of: "_", with: "%5f"))", "https://hub.example"),
        ]
        for (text, origin) in cases {
            let invitation = try Invitation.parse(text)
            #expect(invitation.origin.string == origin, "\(text.debugDescription)")
            #expect(invitation.code == Self.code, "\(text.debugDescription)")
        }
        // The first `join` is the one that counts.
        let other = String(Self.code.reversed())
        #expect(try Invitation.parse("\(Self.hub)/mobile#join=\(Self.code)&join=\(other)").code == Self.code)
        #expect(Self.problem("\(Self.hub)/mobile#join=bad&join=\(Self.code)") == .malformed)
    }

    @Test func namesTheOtherKindsOfInvitation() {
        #expect(Self.problem("\(Self.hub)/pair#join=\(Self.code)") == .desktopInvitation)
        #expect(Self.problem("\(Self.hub):8443/pair#join=\(Self.code)") == .desktopInvitation)
        #expect(Self.problem("  \(Self.hub)/pair#join=\(Self.code)\n") == .desktopInvitation)
        #expect(Self.problem("\(Self.hub)/unlock#join=\(Self.code)") == .browserLink)
        #expect(Self.problem("\(Self.hub)/unlock#join=\(Self.code)&x=1") == .browserLink)
        // The hub's own local link is plain HTTP on loopback.
        #expect(Self.problem("http://127.0.0.1:7777/unlock#join=\(Self.code)") == .browserLink)
        #expect(Self.problem("HTTP://127.0.0.1:7777/unlock#join=\(Self.code)") == .browserLink)

        let desktop = HubError.invalidInvitation(.desktopInvitation).errorDescription ?? ""
        let browser = HubError.invalidInvitation(.browserLink).errorDescription ?? ""
        for message in [desktop, browser] {
            #expect(message.contains("+ → iPhone / iPad app"))
            #expect(!message.contains(Self.code))
        }
        #expect(desktop != browser)
        #expect(HubError.invalidInvitation(.malformed).errorDescription == "Scan or paste the complete invitation shown on the hub.")
    }

    @Test func rejectsHostileAndIncompleteText() {
        let c = Self.code, o = Self.hub
        let hostile = [
            "", "   ", "hello", c, "join=\(c)", "#join=\(c)", "mobile#join=\(c)", "/mobile#join=\(c)", "hub.example/mobile#join=\(c)",
            o, "\(o)/", "\(o)/mobile", "\(o)/mobile#", "\(o)/mobile#join", "\(o)/mobile#join=", "\(o)/mobile#=\(c)",
            // not HTTPS
            "http://hub.example/mobile#join=\(c)", "http://127.0.0.1:7777/mobile#join=\(c)", "ftp://hub.example/mobile#join=\(c)",
            // userinfo
            "https://user@hub.example/mobile#join=\(c)", "https://user:pw@hub.example/mobile#join=\(c)", "https://hub.example@evil.example/mobile#join=\(c)",
            // path
            "\(o)/mobile/#join=\(c)", "\(o)//mobile#join=\(c)", "\(o)/Mobile#join=\(c)", "\(o)/MOBILE#join=\(c)", "\(o)/mobilex#join=\(c)",
            "\(o)/xmobile#join=\(c)", "\(o)/a/mobile#join=\(c)", "\(o)/./mobile#join=\(c)", "\(o)/x/../mobile#join=\(c)", "\(o)/%6Dobile#join=\(c)",
            "\(o)\\mobile#join=\(c)", "\(o)/mobile;x#join=\(c)", "\(o)/mo\tbile#join=\(c)", "\(o)/mobile #join=\(c)",
            // query
            "\(o)/mobile?x=1#join=\(c)", "\(o)/mobile?#join=\(c)", "\(o)/mobile?join=\(c)",
            // fragment
            "\(o)/mobile#JOIN=\(c)", "\(o)/mobile#?join=\(c)", "\(o)/mobile#join%3D\(c)", "\(o)/mobile#join=\(c)#extra", "\(o)/mobile##join=\(c)",
            "\(o)/mobile# join=\(c)", "\(o)/mobile#join= \(c)", "\(o)/mobile#jo\nin=\(c)", "\(o)/mobile#join=\(c);x=1",
            // code of the wrong length or alphabet
            "\(o)/mobile#join=\(c.dropFirst())", "\(o)/mobile#join=\(c)A", "\(o)/mobile#join=\(c.dropLast())+", "\(o)/mobile#join=\(c.dropLast())/",
            "\(o)/mobile#join=\(c.dropLast())=", "\(o)/mobile#join=\(c.dropLast())%", "\(o)/mobile#join=\(c.dropLast())%zz",
            "\(o)/mobile#join=\(String(repeating: "é", count: 43))", "\(o)/mobile#join=\(c)\u{200B}",
            // host
            "https://bücher.example/mobile#join=\(c)", "\(o)./mobile#join=\(c)", "https://017.0.0.1/mobile#join=\(c)", "\(o)/mobile\u{200B}#join=\(c)",
            "https://hub.example:0/mobile#join=\(c)", "https:///mobile#join=\(c)",
            // two invitations pasted together
            "\(o)/mobile#join=\(c)\n\(o)/mobile#join=\(c)",
        ]
        for text in hostile {
            #expect(Self.problem(text) == .malformed, "\(text.debugDescription)")
        }
    }

    /// One direction only: this parser is stricter than `pairWithHub()`, never looser.
    @Test func neverAcceptsWhatTheDesktopParserRejects() throws {
        let rows = try HubOriginTests.vectors().invitations
        #expect(rows.count >= 75)
        var accepted = 0
        for row in rows {
            guard let ours = try? Invitation.parse(row.input) else { continue }
            accepted += 1
            #expect(ours.origin.string == row.parsed?.origin, "\(row.input.debugDescription)")
            #expect(ours.code == row.parsed?.code, "\(row.input.debugDescription)")
        }
        #expect(accepted >= 12)
    }

    @Test func initializerChecksTheCode() throws {
        let origin = try HubOrigin(Self.hub)
        #expect(try Invitation(origin: origin, code: Self.code).code == Self.code)
        #expect(throws: HubError.invalidInvitation(.malformed)) { try Invitation(origin: origin, code: "short") }
        #expect(try Invitation(origin: origin, code: Self.code) == Invitation.parse("\(Self.hub)/mobile#join=\(Self.code)"))
    }

    @Test func textNeverContainsTheCode() throws {
        let invitation = try Invitation.parse("\(Self.hub)/mobile#join=\(Self.code)")
        var dumped = ""
        dump(invitation, to: &dumped)
        for text in [invitation.description, invitation.debugDescription, "\(invitation)", String(reflecting: invitation), "\([invitation])", dumped] {
            #expect(!text.contains(Self.code), "\(text)")
            #expect(!text.contains(String(Self.code.prefix(10))), "\(text)")
            #expect(text.contains("hub.example"))
        }
    }
}
