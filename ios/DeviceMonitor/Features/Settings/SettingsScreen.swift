import DMCore
import SwiftUI
import UIKit

/// The Settings tab: the dashboard's settings dialog (#settingsDlg in public/index.html) as a
/// paired phone sees it. Display unit and appearance, this device and the way out, a browser link to share, the
/// hub, the electricity price under "Advanced settings", and the app itself. What only a
/// computer has (firewall, start at sign-in, updates, quit) is not here.
struct SettingsScreen: View {
    @Environment(HubStore.self) private var store
    @Environment(SessionController.self) private var session
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The hub's TLS pin. It only changes when the hub proves a new key, on a reconnect.
    @State private var pin: String?
    @State private var showsLicense = SettingsLaunch.showsLicense

    var body: some View {
        let overview = overview
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: Theme.Spacing.xl) {
                    SettingsDisplaySection()
                    SettingsDeviceSection(overview: overview)
                        .id(SettingsAnchor.device)
                    SettingsHubSection(overview: overview)
                        .id(SettingsAnchor.hub)
                    SettingsAdvancedSection()
                        .id(SettingsAnchor.advanced)
                    SettingsAboutSection(overview: overview, showsLicense: $showsLicense)
                        .id(SettingsAnchor.about)
                }
                .frame(maxWidth: 560)
                .padding(Theme.Layout.screenPadding(for: sizeClass))
                .settingsDebugWidth()
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("screen-settings")
            .task {
                // DEBUG launch argument only: open at a section further down.
                guard let anchor = SettingsLaunch.scrollAnchor else { return }
                try? await Task.sleep(for: .milliseconds(400))
                proxy.scrollTo(anchor, anchor: .top)
            }
        }
        .navigationTitle(SettingsOverview.Labels.title)
        .navigationDestination(isPresented: $showsLicense) { SettingsLicenseScreen() }
        .task {
            pin = session.hubPin
            // Asked for with every connection; again here if that answer never came.
            if store.info == nil { _ = try? await store.refreshInfo() }
        }
        .onChange(of: store.connection) { pin = session.hubPin }
    }

    private var overview: SettingsOverview {
        SettingsOverview(
            device: UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone,
            isDemo: session.isDemo,
            hubOrigin: session.hubOriginText,
            pairedName: session.hub?.name,
            info: store.info,
            pin: pin,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }
}

/// The sections a DEBUG launch argument can open the screen at.
nonisolated enum SettingsAnchor: String, Hashable, Sendable {
    case device, hub, advanced, about
    /// In the add-device sheet: "View from another device".
    case link
}

// MARK: - Display

/// `#setUnit`, and the app's own appearance: every screen follows at once, because they all read
/// `Preferences`.
private struct SettingsDisplaySection: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        SettingsSection {
            SettingsAdaptiveRow(SettingsOverview.Labels.temperatureUnit) {
                DMSegmentedControl(
                    SettingsOverview.Labels.temperatureUnit, selection: $preferences.temperatureUnit,
                    segments: TemperatureUnit.allCases.map { DMSegment($0, $0.symbol, identifier: $0.rawValue) },
                    identifier: "settings-unit"
                )
            }
            // Three words do not fit beside the title on a phone: the control has a line of its own.
            SettingsRow(SettingsOverview.Labels.appearance, layout: .stacked) {
                DMSegmentedControl(
                    SettingsOverview.Labels.appearance, selection: $preferences.appearance,
                    segments: Appearance.allCases.map { DMSegment($0, $0.label, identifier: $0.rawValue) },
                    fillsWidth: true, identifier: "settings-appearance"
                )
            }
        }
        .sensoryFeedback(.selection, trigger: preferences.temperatureUnit)
        .sensoryFeedback(.selection, trigger: preferences.appearance)
    }
}

// MARK: - This device, and sharing

/// "This computer" and "Dashboard link" of the dashboard's dialog.
private struct SettingsDeviceSection: View {
    let overview: SettingsOverview

    @Environment(SessionController.self) private var session
    @State private var isConfirming = false

    var body: some View {
        SettingsSection {
            SettingsAdaptiveRow(overview.deviceTitle, description: SettingsText.keepingAddressesWhole(overview.deviceDetail)) {
                Button(session.isDisconnecting ? SettingsOverview.Labels.disconnecting : overview.leaveLabel) {
                    if overview.confirmsLeaving {
                        isConfirming = true
                    } else {
                        leave()
                    }
                }
                .buttonStyle(.dm(.destructive, size: .small))
                .disabled(session.isDisconnecting)
                .accessibilityIdentifier("settings-disconnect-button")
                // Here, so that on an iPad it points at the button.
                .confirmationDialog(overview.disconnectQuestion, isPresented: $isConfirming, titleVisibility: .visible) {
                    Button(SettingsOverview.Labels.confirmDisconnect, role: .destructive, action: leave)
                    Button(SettingsOverview.Labels.cancel, role: .cancel) {}
                } message: {
                    Text(overview.disconnectDetail)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings-device")
            SettingsLinkRows()
        }
        .task {
            // DEBUG launch argument only: the question, without the tap.
            guard SettingsLaunch.confirmsDisconnect, overview.confirmsLeaving else { return }
            try? await Task.sleep(for: .milliseconds(400))
            isConfirming = true
        }
    }

    /// The session tells the hub, forgets the enrollment and returns the app to onboarding.
    private func leave() {
        Task { await session.disconnect() }
    }
}

/// "Dashboard link": makes a fresh browser invitation on request and offers to copy or share it.
/// The link is gone again when the tab is left, the app leaves the foreground, or it lapses.
private struct SettingsLinkRows: View {
    @Environment(HubStore.self) private var store
    @Environment(SessionController.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AddDeviceInvitationModel(script: SettingsLaunch.settingsLink)

    var body: some View {
        let invitation = model.invitation
        // One view with a lifetime of its own: what is attached below must not come and go with
        // the lines under the row.
        VStack(alignment: .leading, spacing: 0) {
            SettingsAdaptiveRow(BrowserInvitation.Labels.title, description: BrowserInvitation.Labels.hint) {
                // Every label is laid out, so the row does not rewrap when the button changes.
                Button {
                    model.create(from: store)
                } label: {
                    ZStack {
                        ForEach([BrowserInvitation.Labels.create, BrowserInvitation.Labels.renew, BrowserInvitation.Labels.retry], id: \.self) { label in
                            Text(label).opacity(label == (invitation.actionLabel ?? BrowserInvitation.Labels.create) ? 1 : 0)
                        }
                    }
                    .accessibilityHidden(true)
                }
                .buttonStyle(.dm(size: .small))
                .disabled(invitation.actionLabel == nil)
                .accessibilityLabel(invitation.actionLabel ?? BrowserInvitation.Labels.create)
                .accessibilityIdentifier("settings-link-button")
            }
            // Belongs to the row above: no hairline, and the row's own bottom padding.
            if invitation.state != .idle {
                details(invitation)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 11)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: invitation.state)
        .sensoryFeedback(trigger: invitation.state) { _, state in
            if case .failed = state { .error } else { nil }
        }
        .task {
            if model.asksAtOnce { model.create(from: store) }
        }
        .onDisappear { model.discard() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.discard() }
        }
    }

    @ViewBuilder
    private func details(_ invitation: BrowserInvitation) -> some View {
        switch invitation.state {
        case .idle:
            EmptyView()
        case .creating:
            HStack(spacing: Theme.Spacing.s) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.textSecondary)
                note(BrowserInvitation.Labels.creating)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings-link-loading")
        case .ready(let link, let expires):
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                AddDeviceLinkText(link: link, identifier: "settings-link")
                // Side by side while they fit; one under the other at the largest text sizes.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Spacing.s) {
                        AddDeviceLinkActions(link: link, expires: expires, identifier: "settings-link")
                    }
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        AddDeviceLinkActions(link: link, expires: expires, identifier: "settings-link")
                    }
                }
                note(session.isDemo ? AddDeviceGuide.demoNote : BrowserInvitation.Labels.validity)
            }
        case .failed(let text):
            Text(text)
                .dmFont(.callout)
                .foregroundStyle(Theme.dangerText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-link-error")
        case .expired, .unavailable:
            note(invitation.message ?? "")
                .accessibilityIdentifier("settings-link-note")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .dmFont(.caption)
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - The hub

/// Which hub this is (`GET /api/info`), the electricity price it holds, and the TLS key the app
/// trusts it by.
private struct SettingsHubSection: View {
    let overview: SettingsOverview

    @Environment(HubStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var showsWholeIdentity = SettingsLaunch.showsWholeIdentity

    var body: some View {
        SettingsSection(SettingsOverview.Labels.hub, footer: overview.fingerprint == nil ? nil : HubFingerprint.hint) {
            fact(SettingsOverview.Labels.hostName, overview.hostName, identifier: "settings-hub-host")
            fact(SettingsOverview.Labels.address, overview.address, isMonospaced: true, identifier: "settings-hub-address")
            SettingsAdaptiveRow(SettingsOverview.Labels.electricityPrice, description: price) {
                Button(SettingsOverview.Labels.changePrice) { router.showElectricityPrice() }
                    .buttonStyle(.dm(size: .small))
                    .accessibilityIdentifier("settings-price-button")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings-hub-price")
            if let fingerprint = overview.fingerprint {
                SettingsAdaptiveRow(
                    HubFingerprint.label, description: showsWholeIdentity ? fingerprint.grouped : fingerprint.short, isMonospaced: true
                ) {
                    Button(showsWholeIdentity ? HubFingerprint.hide : HubFingerprint.show) { showsWholeIdentity.toggle() }
                        .buttonStyle(.dm(size: .small))
                        .accessibilityIdentifier("settings-hub-identity-button")
                }
                .contextMenu {
                    Button {
                        AddDevicePasteboard.copy(fingerprint.pin)
                    } label: {
                        Label(BrowserInvitation.Labels.copy, systemImage: "doc.on.doc")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings-hub-identity")
            }
        }
    }

    /// Something the hub said about itself; an ellipsis until it has.
    private func fact(_ label: String, _ value: String?, isMonospaced: Bool = false, identifier: String) -> some View {
        let value = value ?? SettingsOverview.Labels.pending
        return SettingsRow(label, description: SettingsText.keepingAddressesWhole(value), isMonospaced: isMonospaced)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityIdentifier(identifier)
    }

    /// The price in force, as the Advanced tab states it.
    private var price: String {
        guard store.isEnergySettingsLoaded else { return SettingsOverview.Labels.pending }
        return PriceEditorNotes.summary(of: EnergyPrice(saved: store.energySettings))
    }
}

// MARK: - Advanced settings

/// `<details class="set-adv" id="setAdv">`: the electricity price editor, folded away until asked
/// for. Whether it is open is remembered, as the dashboard remembers `setAdvOpen`.
private struct SettingsAdvancedSection: View {
    @Environment(Preferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A DEBUG launch argument can open or close it for one run without touching the preference.
    @State private var forced = SettingsLaunch.advancedExpanded

    var body: some View {
        let isExpanded = forced ?? preferences.isAdvancedSettingsExpanded
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    forced = nil
                    preferences.isAdvancedSettingsExpanded = !isExpanded
                }
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: 8))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    Text(SettingsOverview.Labels.advanced)
                        .dmFont(.callout)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.textSecondary)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsRowButtonStyle())
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("settings-advanced-toggle")
            if isExpanded {
                Hairline()
                SettingsPriceEditor(placement: .settings)
                    .padding(.vertical, Theme.Spacing.m)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .dmSurface(Theme.surface1, radius: Theme.Radius.card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-advanced")
    }
}

// MARK: - About

private struct SettingsAboutSection: View {
    let overview: SettingsOverview
    @Binding var showsLicense: Bool

    var body: some View {
        SettingsSection(SettingsOverview.Labels.about) {
            SettingsRow(SettingsOverview.Labels.appName, description: "\(overview.version)\n\(overview.companion)")
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings-about-version")
            Button {
                showsLicense = true
            } label: {
                SettingsRow(SettingsOverview.Labels.license, description: SettingsOverview.licenseSummary) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsRowButtonStyle())
            .accessibilityIdentifier("settings-license-button")
        }
    }
}

/// The repository's LICENSE.
struct SettingsLicenseScreen: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                ForEach(Array(SettingsOverview.licenseParagraphs.enumerated()), id: \.offset) { index, paragraph in
                    Text(paragraph)
                        .dmFont(index == 0 ? .bodyStrong : .callout)
                        .foregroundStyle(index < 2 ? Theme.textPrimary : Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 560, alignment: .leading)
            .padding(Theme.Spacing.l)
            .dmSurface(Theme.surface1, radius: Theme.Radius.card)
            .padding(Theme.Layout.screenPadding(for: sizeClass))
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("screen-license")
        .navigationTitle(SettingsOverview.Labels.license)
        .navigationBarTitleDisplayMode(.inline)
        .dmScreen()
    }
}

// MARK: - Pieces

/// A settings row whose control sits beside the text while there is room, and under it at the
/// accessibility text sizes, where a button beside a paragraph leaves neither enough width.
struct SettingsAdaptiveRow<Trailing: View>: View {
    private let title: String
    private let description: String?
    private let isMonospaced: Bool
    private let trailing: Trailing

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ title: String, description: String? = nil, isMonospaced: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.description = description
        self.isMonospaced = isMonospaced
        self.trailing = trailing()
    }

    var body: some View {
        SettingsRow(title, description: description, isMonospaced: isMonospaced, layout: dynamicTypeSize.isAccessibilitySize ? .stacked : .inline) {
            trailing
        }
    }
}

nonisolated enum SettingsText {
    /// The same text for display, with invisible hints where an address may be broken: never
    /// right after "https://" (which strands the scheme at a line's end), and, when the address
    /// is longer than the line, after a dot of the host instead of in the middle of a name.
    /// Not for text the user can select and copy.
    static func keepingAddressesWhole(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let scheme = rest.range(of: "://") {
            // A word joiner: no line break here.
            out += rest[..<scheme.upperBound] + "\u{2060}"
            rest = rest[scheme.upperBound...]
            let end = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
            // A zero-width space: a line break may go here.
            out += rest[..<end].replacingOccurrences(of: ".", with: ".\u{200B}")
            rest = rest[end...]
        }
        return out + rest
    }
}

/// A whole row that is a button: it dims while pressed.
struct SettingsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

#Preview("Settings, demo") {
    NavigationStack { SettingsScreen().dmScreen() }
        .demoEnvironment(tab: .settings)
}

#Preview("License") {
    NavigationStack { SettingsLicenseScreen() }
}
