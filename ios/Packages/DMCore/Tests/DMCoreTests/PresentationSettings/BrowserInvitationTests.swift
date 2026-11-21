import Foundation
import Testing
@testable import DMCore

/// The browser link's states, against updateCmd in public/index.html.
@Suite struct BrowserInvitationTests {
    private let link = URL(string: "https://hub.test/unlock#join=" + String(repeating: "c", count: 43))!
    private let other = URL(string: "https://hub.test/unlock#join=" + String(repeating: "d", count: 43))!
    private let now = 1_795_000_000_000.0

    /// Starts a request that the hub is expected to be asked for.
    private func begin(_ invitation: inout BrowserInvitation, canShare: Bool? = true) throws -> Int {
        let request = invitation.begin(canShare: canShare)
        return try #require(request)
    }

    @Test func itStartsWithNothingToShow() {
        let invitation = BrowserInvitation()
        #expect(invitation.state == .idle && invitation.link == nil && invitation.expires == nil && invitation.message == nil)
        #expect(invitation.actionLabel == "Create link" && !invitation.isCreating)
    }

    @Test func aLinkIsShownForTenSecondsShortOfTenMinutes() throws {
        var invitation = BrowserInvitation()
        let request = try begin(&invitation)
        #expect(invitation.isCreating && invitation.message == "Creating an invitation\u{2026}" && invitation.actionLabel == nil)
        invitation.finish(request, link: link, now: now)
        #expect(invitation.state == .ready(link: link, expires: now + 590_000))
        #expect(invitation.link == link && invitation.expires == now + 590_000 && invitation.message == nil)
        #expect(invitation.actionLabel == "New link")

        invitation.expire(now: now + 589_999)
        #expect(invitation.link == link, "Not before its time")
        invitation.expire(now: now + 590_000)
        #expect(invitation.state == .expired && invitation.link == nil)
        #expect(invitation.message == "This invitation has expired." && invitation.actionLabel == "New link")
    }

    @Test func aHubThatHasNotAnsweredYetIsAskedAnyway() throws {
        var invitation = BrowserInvitation()
        _ = try begin(&invitation, canShare: nil)
        #expect(invitation.isCreating)
    }

    @Test func aCallerThatMayNotShareIsToldWhereInvitationsComeFrom() {
        var invitation = BrowserInvitation()
        let request = invitation.begin(canShare: false)
        #expect(request == nil)
        #expect(invitation.state == .unavailable && invitation.actionLabel == nil)
        #expect(invitation.message == "Create new invitations in the hub app or its local operator dashboard.")
    }

    @Test func aRefusalIsShownInTheHubsWords() throws {
        var invitation = BrowserInvitation()
        var request = try begin(&invitation)
        invitation.fail(request, .http(status: 400, message: "Configure a trusted HTTPS hub address for remote devices."))
        #expect(invitation.state == .failed("Configure a trusted HTTPS hub address for remote devices."))
        #expect(invitation.message == "Configure a trusted HTTPS hub address for remote devices." && invitation.actionLabel == "Try again")

        request = try begin(&invitation)
        invitation.fail(request, .unreachable("Could not connect to the hub."))
        #expect(invitation.message == "Could not connect to the hub.")

        // out.error || 'Cannot create invitation'
        request = try begin(&invitation)
        invitation.fail(request, .http(status: 500, message: ""))
        #expect(invitation.message == "Cannot create invitation")
    }

    @Test func aRequestThatWasGivenUpSaysNothing() throws {
        var invitation = BrowserInvitation()
        let request = try begin(&invitation)
        invitation.fail(request, .cancelled)
        #expect(invitation.state == .idle)
    }

    @Test func onlyTheNewestRequestIsAnswered() throws {
        var invitation = BrowserInvitation()
        let first = try begin(&invitation)
        let second = try begin(&invitation)
        #expect(first != second)
        invitation.finish(first, link: link, now: now)
        #expect(invitation.isCreating, "The first answer came too late")
        invitation.fail(first, .unreachable("late"))
        #expect(invitation.isCreating)
        invitation.finish(second, link: other, now: now)
        #expect(invitation.link == other)
        // An answer cannot replace a link that is already on show.
        invitation.finish(second, link: link, now: now + 1)
        #expect(invitation.link == other && invitation.expires == now + 590_000)
    }

    @Test func aLinkThatWasPutAwayStaysAway() throws {
        var invitation = BrowserInvitation()
        let request = try begin(&invitation)
        invitation.discard()
        #expect(invitation.state == .idle)
        invitation.finish(request, link: link, now: now)
        #expect(invitation.state == .idle && invitation.link == nil, "The screen that asked is gone")

        let again = try begin(&invitation)
        invitation.finish(again, link: link, now: now)
        invitation.discard()
        #expect(invitation.link == nil && invitation.actionLabel == "Create link")
        invitation.expire(now: now + 600_000)
        #expect(invitation.state == .idle)
    }

    @Test func askingAgainPutsTheOldLinkAway() throws {
        var invitation = BrowserInvitation()
        let request = try begin(&invitation)
        invitation.finish(request, link: link, now: now)
        _ = try begin(&invitation)
        #expect(invitation.link == nil && invitation.isCreating)
    }

    @Test func noDescriptionCarriesTheLink() throws {
        var invitation = BrowserInvitation()
        let request = try begin(&invitation)
        invitation.finish(request, link: link, now: now)
        let code = String(repeating: "c", count: 43)
        var dumped = ""
        dump(invitation, to: &dumped)
        dump(invitation.state, to: &dumped)
        for text in ["\(invitation)", "\(invitation.state)", String(describing: invitation), String(reflecting: invitation.state), dumped] {
            #expect(!text.contains(code), "\(text)")
        }
        #expect("\(invitation)" == "BrowserInvitation(ready(link: <redacted>))")
    }

    @Test func theWordingIsTheDashboards() {
        #expect(BrowserInvitation.Labels.title == "Dashboard link")
        #expect(BrowserInvitation.Labels.hint == "Share a single-use browser invitation. It signs in one browser tab for eight hours.")
        #expect(AddDeviceGuide.title == "Add a device")
        #expect(AddDeviceGuide.enrollOnHub == "Create device enrollments on the hub.")
        #expect(AddDeviceGuide.viewTitle == "View from another device")
        #expect(AddDeviceGuide.viewText == "Open this link on any phone, tablet or computer on your network. It is a single-use, ten-minute invitation for one browser tab.")
        #expect(AddDeviceGuide.computerOptions == ["Windows command", "Desktop app (Windows / Mac)", "Mac / Linux command"])
        #expect(AddDeviceGuide.mobileLead == "On the hub, choose + \u{2192} iPhone / iPad app.")
    }

    /// The tab names and sentences quoted from the dashboard are still in the dashboard.
    @Test func theQuotedWordingIsStillInTheDashboard() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        // The package can be checked out without the repository around it; then there is nothing to compare with.
        guard let page = try? String(contentsOf: root.appendingPathComponent("public/index.html"), encoding: .utf8) else { return }
        let quoted = AddDeviceGuide.computerOptions + [
            AddDeviceGuide.mobileOption, AddDeviceGuide.title, AddDeviceGuide.viewTitle, AddDeviceGuide.viewText, AddDeviceGuide.enrollOnHub,
            AddDeviceGuide.computersNote, BrowserInvitation.Labels.unavailable, BrowserInvitation.Labels.failure, BrowserInvitation.Labels.title,
            SettingsOverview.Labels.temperatureUnit, SettingsOverview.Labels.advanced, "Connected to the hub at ",
        ]
        for text in quoted {
            #expect(page.contains(text), "The dashboard no longer says \"\(text)\"")
        }
    }
}
