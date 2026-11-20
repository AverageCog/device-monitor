import Foundation
import Testing
@testable import DMCore

/// What the app sends. Each body is compared with one a real hub accepted during the capture
/// (Fixtures/models/requests.json), so the encoders are held to the hub's validators rather than
/// to a reading of them.
@Suite struct WireRequestTests {
    /// The recorded body of an accepted request.
    private func accepted(_ name: String) throws -> NSObject {
        let recorded = try ModelFixture.request(name)
        #expect(recorded.status == 200, "\(name) was not accepted by the hub")
        return try #require(recorded.body as? NSObject)
    }

    @Test func rename() throws {
        #expect(try ModelFixture.json(Wire.Rename(name: "Lab PC")) == (try accepted("rename")))
    }

    @Test func reorder() throws {
        let ids = [ModelFixture.dgx, ModelFixture.workstation, ModelFixture.macbook, ModelFixture.lab, ModelFixture.nas, ModelFixture.htpc, ModelFixture.removed]
        #expect(try ModelFixture.json(Wire.Order(ids: ids)) == (try accepted("order")))
    }

    @Test func browserInvitation() throws {
        let body = Wire.Invite(kind: .browser, origin: "https://hub.test")
        #expect(try ModelFixture.json(body) == (try accepted("invite-browser")))
        // The same request with a browser session's credential is refused: only paired apps may share.
        let refused = try ModelFixture.request("invite-browser-refused-for-browser-role")
        #expect(refused.status == 403)
        #expect(try ModelFixture.json(body) == refused.body as? NSObject)
    }

    @Test func invitationKindsAndTargets() throws {
        // Section 5.1 of the architecture brief: `id` must be absent for a mobile invitation.
        #expect(try ModelFixture.json(Wire.Invite(kind: .mobile, origin: "https://hub.test")) == ["kind": "mobile", "origin": "https://hub.test"] as NSDictionary)
        #expect(try ModelFixture.json(Wire.Invite(kind: .desktop, origin: "https://hub.test", id: "nas-01")) == ["kind": "desktop", "origin": "https://hub.test", "id": "nas-01"] as NSDictionary)
        #expect(try ModelFixture.json(Wire.Invite(kind: .agent, origin: "https://hub.test")) == ["kind": "agent", "origin": "https://hub.test"] as NSDictionary)
    }

    @Test func deviceAction() throws {
        #expect(try ModelFixture.json(Wire.DeviceAction(action: "restart")) == (try accepted("action-restart")))
        // A fixture hub never sends wake-up packets (403), but the body is the one it parsed.
        let wake = try ModelFixture.request("action-wake-fixture-hub")
        #expect(wake.status == 403)
        #expect(try ModelFixture.json(Wire.DeviceAction.wake) == wake.body as? NSObject)
        #expect(try ModelFixture.json(Wire.DeviceAction.wake) == ["action": "wake"] as NSDictionary)
    }

    @Test func mobilePair() throws {
        #expect(String(decoding: try HubJSON.encode(Wire.MobilePair(name: "Sam's iPhone")), as: UTF8.self) == #"{"name":"Sam's iPhone"}"#)
        #expect(String(decoding: try HubJSON.encode(Wire.MobilePair()), as: UTF8.self) == "{}")
    }

    @Test func flatElectricityPriceLeavesTouOut() throws {
        let flat = EnergySettings(region: "US-CA", rate: 0.316, currency: "USD")
        #expect(try ModelFixture.json(flat) == (try accepted("energy-settings-flat")))
        #expect(String(decoding: try HubJSON.encode(flat), as: UTF8.self) == #"{"currency":"USD","rate":0.316,"region":"US-CA"}"#)
        // The hub takes an empty list as flat too; it answers without `tou` either way.
        let withEmpty = try ModelFixture.request("energy-settings-flat-empty-tou")
        #expect(withEmpty.status == 200)
        #expect(try HubJSON.decode(EnergySettings.self, from: try ModelFixture.reencode(withEmpty.response)) == EnergySettings(region: "DE", rate: 0.39, currency: "EUR"))
    }

    @Test func timeOfUseElectricityPrice() throws {
        let sent = EnergySettings(region: "custom", rate: 0.25, currency: "EUR", tou: [TouPeriod(from: 16, to: 21, rate: 0.42), TouPeriod(from: 0, to: 6.5, rate: 0.123456)])
        #expect(try ModelFixture.json(sent) == (try accepted("energy-settings-tou")))
        // What comes back is sorted and rounded, and that is what the app should then hold.
        let stored = try HubJSON.decode(EnergySettings.self, from: try ModelFixture.reencode(try ModelFixture.request("energy-settings-tou").response))
        #expect(stored.tou == [TouPeriod(from: 0, to: 6.5, rate: 0.1235), TouPeriod(from: 16, to: 21, rate: 0.42)])
        #expect(try HubJSON.decode(EnergySettings.self, from: try HubJSON.encode(stored)) == stored)
    }

    @Test func alertSettingsEditedFromTheDefaults() throws {
        // What the app does: read the settings, change them, send them back.
        var settings = try ModelFixture.decode(AlertsResponse.self, "alerts-default.json").settings
        let defaults = Dictionary(uniqueKeysWithValues: settings.rules.map { ($0.type, $0) })
        var offline = try #require(defaults[.offline])
        offline.device = ModelFixture.htpc
        offline.minutes = 1
        var gpuTemp = try #require(defaults[.gpuTemp])
        gpuTemp.enabled = false
        settings.rules = [
            offline,
            AlertRule(id: "b0b0b0b0b0b1", type: .offline, device: ModelFixture.nas, minutes: 1),
            try #require(defaults[.cpuTemp]),
            gpuTemp,
            try #require(defaults[.disk]),
            AlertRule(id: "c0ffee123456", type: .cpu, device: ModelFixture.workstation, threshold: 90),
            AlertRule(id: "feedfacecafe", type: .power, threshold: 1000),
            AlertRule(id: "deadbeef0001", type: .dailyCost, threshold: 0.01),
            AlertRule(id: "abcdef012345", type: .mem, threshold: 97.5, minutes: 5),
        ]
        settings.channels.ntfy = .init(enabled: true, topic: "dm-fixture-topic", email: "alerts@example.com")
        settings.channels.webhook = .init(enabled: true, url: "https://hooks.example.com/services/fixture")
        #expect(settings.rules.allSatisfy { $0.isAcceptable })
        #expect(try ModelFixture.json(settings) == (try accepted("alerts-put")))

        // And the hub stored exactly those rules, in that order.
        let stored = try ModelFixture.decode(AlertsUpdate.self, "alerts-put.json").settings
        #expect(stored.rules == settings.rules)
        #expect(stored.channels.ntfy == settings.channels.ntfy)
    }

    @Test func alertSettingsSentBackKeepTheStoredWebhook() throws {
        // GET never returns the webhook URL. Sending the settings back untouched must not erase it.
        var settings = try ModelFixture.decode(AlertsUpdate.self, "alerts-put.json").settings
        #expect(settings.channels.webhook == .init(enabled: true, url: "", keepUrl: true))
        settings.notifyResolved = false
        settings.tempUnit = .fahrenheit
        #expect(try ModelFixture.json(settings) == (try accepted("alerts-put-keep-webhook")))

        let answer = try HubJSON.decode(AlertsUpdate.self, from: try ModelFixture.reencode(try ModelFixture.request("alerts-put-keep-webhook").response))
        #expect(answer.settings.channels.webhook == .init(enabled: true, url: "", keepUrl: true))   // still stored, still on
        #expect(answer.settings == settings)
    }

    @Test func webhookEncodesAsNewUrlKeepOrRemove() throws {
        typealias Webhook = AlertChannels.Webhook
        // validSettings: `hook.url ? httpUrl(hook.url) : hook.keepUrl && prev ? prev.channels.webhook.url : ''`
        #expect(try ModelFixture.json(Webhook(enabled: true, url: "https://example.com/hook", keepUrl: true)) == ["enabled": true, "url": "https://example.com/hook"] as NSDictionary)
        #expect(try ModelFixture.json(Webhook(enabled: true, url: "", keepUrl: true)) == ["enabled": true, "keepUrl": true] as NSDictionary)
        #expect(try ModelFixture.json(Webhook(enabled: false, url: "", keepUrl: false)) == ["enabled": false, "url": ""] as NSDictionary)
        #expect(Webhook(enabled: true, url: "", keepUrl: false).hasUrl == false)
        #expect(Webhook(url: "https://example.com/hook").hasUrl)
    }

    @Test func rulesTheHubRefusesAreNotAcceptable() throws {
        // Each of these was sent to the hub and answered 400 "invalid alert settings".
        for name in ["alerts-put-bad-threshold", "alerts-put-offline-zero-minutes"] {
            let recorded = try ModelFixture.request(name)
            #expect(recorded.status == 400)
            let body = try HubJSON.decode(AlertSettings.self, from: try ModelFixture.reencode(recorded.body))
            #expect(body.rules.count == 1)
            #expect(body.rules.allSatisfy { !$0.isAcceptable }, "\(name)")
        }
        #expect(!AlertRule(type: .cpu, threshold: nil).isAcceptable)
        #expect(!AlertRule(type: .cpu, threshold: 100.5).isAcceptable)
        #expect(AlertRule(type: .cpu, threshold: 100).isAcceptable)
        #expect(!AlertRule(type: .cpuTemp, threshold: 19.9).isAcceptable)
        #expect(AlertRule(type: .dailyCost, threshold: 0.01).isAcceptable)
        #expect(!AlertRule(type: .dailyCost, threshold: 0.009).isAcceptable)
        #expect(AlertRule(type: .offline, minutes: 1).isAcceptable)
        #expect(AlertRule(type: .offline, threshold: 5, minutes: 1440).isAcceptable)   // an offline rule's threshold is ignored
        #expect(!AlertRule(type: .offline, minutes: 1441).isAcceptable)
        #expect(!AlertRule(type: .mem, threshold: 50, minutes: -1).isAcceptable)
        #expect(!AlertRule(type: .mem, device: "", threshold: 50).isAcceptable)
        #expect(!AlertRule(type: .mem, device: "has space", threshold: 50).isAcceptable)
        #expect(!AlertRule(type: .mem, device: String(repeating: "a", count: 65), threshold: 50).isAcceptable)
        #expect(AlertRule(type: .mem, device: "A1B2-c3.d4:e5_f6", threshold: 50).isAcceptable)
    }

    @Test func refusedPricesShowWhatTheValidatorRejects() throws {
        // Lower-case currency, a zero rate, a period that ends before it starts.
        for name in ["energy-settings-bad-currency", "energy-settings-bad-rate", "energy-settings-bad-tou"] {
            let recorded = try ModelFixture.request(name)
            #expect(recorded.status == 400)
            #expect(try HubJSON.decode(Wire.Failure.self, from: try ModelFixture.reencode(recorded.response)) == Wire.Failure(error: "invalid settings"))
        }
    }
}
