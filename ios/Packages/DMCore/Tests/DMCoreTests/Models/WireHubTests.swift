import Foundation
import Testing
@testable import DMCore

/// The hub's small answers: who you are, remote access, updates, invitations, errors.
@Suite struct WireHubTests {
    @Test func infoDependsOnWhoAsks() throws {
        let info = try ModelFixture.decode([String: HubInfo].self, "info.json")

        let root = try #require(info["root"])
        #expect(root.isDeviceMonitor && !root.locked)
        #expect(root.hostname == "hub-pc")
        #expect(root.canEnroll && root.canShare)
        #expect(root.origin == "https://hub.test")
        let port = try #require(root.port)
        #expect(root.localOrigin == "http://127.0.0.1:\(port)")

        // What a paired app sees: it may share browser links but not enrol devices, and it is
        // never shown the loopback origin.
        let client = try #require(info["client"])
        #expect(client == HubInfo(hostname: "hub-pc", port: port, canEnroll: false, canShare: true, origin: "https://hub.test", localOrigin: nil))

        let browser = try #require(info["browser"])
        #expect(!browser.canEnroll && !browser.canShare)
        #expect(browser.origin == "https://hub.test" && browser.localOrigin == nil)

        // Without a credential the hub says only that it is a locked Device Monitor hub.
        let locked = try #require(info["locked"])
        #expect(locked == HubInfo(locked: true))
        #expect(locked.isDeviceMonitor && locked.hostname == nil && locked.port == nil && locked.origin == nil)

        #expect(try HubJSON.decode(HubInfo.self, from: Data(#"{"app":"something-else"}"#.utf8)).isDeviceMonitor == false)
    }

    @Test func remoteAccessWithoutAndWithTailscale() throws {
        let none = try ModelFixture.decode(RemoteStatus.self, "remote.json")
        #expect(!none.installed && !none.running && !none.canConfigure)
        #expect(none.urls.isEmpty && none.httpsUrl == nil && none.ip == nil && none.state == nil)
        #expect(none.platform == "linux")
        #expect(none.port != nil)

        // A hub with Tailscale serving HTTPS: the fields of readStatus() in tailscale.js.
        let running = try HubJSON.decode(RemoteStatus.self, from: Data(#"""
        {"installed":true,"running":true,"state":"Running","ip":"100.101.102.103","dnsName":"hub-pc.tail1234.ts.net",
         "httpsUrl":"https://hub-pc.tail1234.ts.net","urls":["https://hub-pc.tail1234.ts.net","http://100.101.102.103:7777","http://hub-pc.tail1234.ts.net:7777"],
         "tailnet":"example.github","port":7777,"canConfigure":false,"platform":"win32"}
        """#.utf8))
        #expect(running.installed && running.running)
        #expect(running.state == "Running" && running.ip == "100.101.102.103" && running.dnsName == "hub-pc.tail1234.ts.net")
        #expect(running.httpsUrl == "https://hub-pc.tail1234.ts.net" && running.urls.count == 3 && running.urls.first == running.httpsUrl)
        #expect(running.tailnet == "example.github" && running.port == 7777 && running.platform == "win32")

        // Installed but stopped: no addresses at all.
        let stopped = try HubJSON.decode(RemoteStatus.self, from: Data(#"{"installed":true,"running":false,"state":"NotRunning","port":7777,"canConfigure":true,"platform":"darwin"}"#.utf8))
        #expect(stopped.installed && !stopped.running && stopped.canConfigure && stopped.urls.isEmpty && stopped.state == "NotRunning")
    }

    @Test func updateManifestOrNotFound() throws {
        let stages = try JSONSerialization.jsonObject(with: try ModelFixture.data("update.json")) as? [String: Any] ?? [:]
        let published = try HubJSON.decode(UpdateManifest.self, from: try ModelFixture.reencode(stages["published"] ?? NSNull()))
        #expect(published.platform == "windows")
        #expect(published.version == "1.2.33")
        #expect(published.file == "Device Monitor Setup 1.2.33.exe")
        #expect(published.size == 4096)
        #expect(published.sha256?.count == 64)
        #expect(published.released?.hasSuffix("Z") == true)
        #expect(Data(base64Encoded: published.signature ?? "")?.count == 64)   // Ed25519

        // Nothing published for a platform is a 404 with an error body, not a manifest.
        for stage in ["notPublished", "otherPlatform"] {
            let body = try ModelFixture.reencode(stages[stage] ?? NSNull())
            #expect(try HubJSON.decode(Wire.Failure.self, from: body) == Wire.Failure(error: "no update published"))
            #expect(throws: DecodingError.self) { try HubJSON.decode(UpdateManifest.self, from: body) }
        }
    }

    @Test func browserInvitation() throws {
        let invite = try ModelFixture.decode(InviteResponse.self, "invite-browser.json")
        #expect(invite.code.count == 43)
        #expect(invite.code.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        #expect(invite.origin == "https://hub.test")
        let expires = try #require(invite.expires)
        #expect(invite.expiresDate == Date(timeIntervalSince1970: expires / 1000))
        // Ten minutes after it was issued.
        let issued = try #require(try ModelFixture.decode([Device].self, "devices.json").compactMap(\.firstSeen).min())
        #expect(expires - issued > 600_000 && expires - issued < 700_000)
        #expect(throws: DecodingError.self) { try HubJSON.decode(InviteResponse.self, from: Data(#"{"error":"Create this invitation on the hub."}"#.utf8)) }
    }

    @Test func invitationCodeStaysOutOfLogs() throws {
        let invite = InviteResponse(code: "s3cret-invitation-code-0000000000000000000A", origin: "https://hub.test", expires: 1_795_213_596_000)
        var dumped = ""
        dump(invite, to: &dumped)
        for text in [String(describing: invite), String(reflecting: invite), "\(invite)", "\([invite])", "\(Optional(invite) as Any)", dumped] {
            #expect(!text.contains("s3cret"), "\(text)")
            #expect(text.contains("https://hub.test"))
        }
        // Encoding is how the code is meant to travel, and still carries it.
        #expect(try HubJSON.decode(InviteResponse.self, from: try HubJSON.encode(invite)).code == invite.code)
    }

    @Test func mobileClients() throws {
        // GET /api/mobile (section 5.1 of the architecture brief): lastSeen is null until the
        // phone has made a request since the hub started.
        let list = try HubJSON.decodeList(MobileClient.self, from: Data(#"""
        [{"id":"0b9f6c1e-6f0a-4c36-9a55-3f2a7d1c8e40","name":"Sam's iPhone","created":1795213000000,"lastSeen":1795213953000},
         {"id":"7d3e2a10-1b2c-4d5e-8f90-a1b2c3d4e5f6","name":"iPad","created":1795000000000,"lastSeen":null},
         {"name":"no id"}]
        """#.utf8))
        #expect(list.count == 2)
        #expect(list[0] == MobileClient(id: "0b9f6c1e-6f0a-4c36-9a55-3f2a7d1c8e40", name: "Sam's iPhone", created: 1_795_213_000_000, lastSeen: 1_795_213_953_000))
        #expect(list[0].createdDate == Date(timeIntervalSince1970: 1_795_213_000))
        #expect(list[0].lastSeenDate == Date(timeIntervalSince1970: 1_795_213_953))
        #expect(list[1].lastSeen == nil && list[1].lastSeenDate == nil && list[1].name == "iPad")
        #expect(try HubJSON.decode([MobileClient].self, from: try HubJSON.encode(list)) == list)
    }

    @Test func acknowledgementsAndErrors() throws {
        for name in ["order", "remove", "alerts-clear-log"] {
            let recorded = try ModelFixture.request(name)
            #expect(recorded.status == 200)
            #expect(try HubJSON.decode(Wire.OK.self, from: try ModelFixture.reencode(recorded.response)) == Wire.OK(ok: true))
        }
        // A queued power action also names the command.
        let queued = try HubJSON.decode(Wire.OK.self, from: try ModelFixture.reencode(try ModelFixture.request("action-restart").response))
        #expect(queued.ok && queued.id?.count == 12)

        let errors: [String: (Int, String)] = [
            "action-wake-fixture-hub": (403, "Host integrations disabled"),
            "action-wake-no-mac": (400, "This device hasn't reported a network card address yet."),
            "action-not-allowed": (409, "Remote power control is turned off on Sams-MacBook-Pro."),
            "action-unknown": (400, "unknown action"),
            "invite-browser-refused-for-browser-role": (403, "Create this invitation on the hub."),
            "invite-desktop-refused-for-client-role": (403, "Create this invitation on the hub."),
            "energy-settings-bad-currency": (400, "invalid settings"),
            "energy-bad-bounds": (400, "bad bounds"),
            "alerts-put-bad-threshold": (400, "invalid alert settings"),
            "history-bad-range": (400, "bad range"),
            "history-unknown-device": (404, "not found"),
        ]
        for (name, (status, message)) in errors {
            let recorded = try ModelFixture.request(name)
            #expect(recorded.status == status, "\(name)")
            let failure = try HubJSON.decode(Wire.Failure.self, from: try ModelFixture.reencode(recorded.response))
            #expect(failure.error == message, "\(name)")
            // An error body is not mistaken for success.
            #expect(try HubJSON.decode(Wire.OK.self, from: try ModelFixture.reencode(recorded.response)).ok == false)
        }
    }

    @Test func hubTimeIsMillisecondsSince1970() {
        #expect(Date(hubTime: 1_795_213_953_000) == Date(timeIntervalSince1970: 1_795_213_953))
        #expect(Date(timeIntervalSince1970: 1_795_213_953.25).hubTime == 1_795_213_953_250)
        #expect(Date(hubTime: 0).hubTime == 0)
    }

    @Test func sharedCodersAgree() throws {
        // Same value, same bytes: keys sorted, slashes left alone.
        let info = HubInfo(hostname: "hub-pc", port: 7777, canShare: true, origin: "https://hub.test")
        let text = String(decoding: try HubJSON.encode(info), as: UTF8.self)
        #expect(text == #"{"app":"device-monitor","canEnroll":false,"canShare":true,"hostname":"hub-pc","locked":false,"origin":"https://hub.test","port":7777}"#)
        #expect(try HubJSON.decode(HubInfo.self, from: Data(text.utf8)) == info)
    }
}
