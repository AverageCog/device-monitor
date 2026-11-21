import DMCore
import SwiftUI

/// The "+" of the dashboard as a paired phone sees it (#addDlg with `canEnroll` false): where
/// new devices are enrolled, and a browser link to view the dashboard from another device.
/// Presented by the tab shell for `AppRouter.showAddDevice()`; the environment is the tabs'.
struct AddDeviceSheet: View {
    @Environment(HubStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model = AddDeviceInvitationModel(makesQRCode: true, script: SettingsLaunch.addDeviceLink)

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                        enrollment
                        AddDeviceViewSection(model: model)
                            .id(SettingsAnchor.link)
                    }
                    .frame(maxWidth: 560)
                    .padding(Theme.Layout.screenPadding(for: sizeClass))
                    .frame(maxWidth: .infinity)
                }
                .task {
                    // DEBUG launch argument only: open at the link.
                    guard SettingsLaunch.scrollAnchor == .link else { return }
                    try? await Task.sleep(for: .milliseconds(600))
                    proxy.scrollTo(SettingsAnchor.link, anchor: .top)
                }
            }
            .accessibilityIdentifier("screen-add-device")
            .navigationTitle(AddDeviceGuide.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AddDeviceGuide.done) { dismiss() }
                        .accessibilityIdentifier("add-device-done-button")
                }
            }
            .dmScreen()
        }
        .preferredColorScheme(.dark)
        // The link is made when the sheet opens (the dashboard's enrollmentOptions), and is gone
        // with it: $('#addDlg').addEventListener('close', () => { invitationRequest++; … }).
        .onAppear {
            // Not again when the share sheet closes over a link that is still good.
            if model.invitation.state == .idle { model.create(from: store) }
        }
        .onDisappear { model.discard() }
        // Nor does it stay behind in the app switcher's picture of the app.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.discard() }
        }
    }

    private var enrollment: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Text(AddDeviceGuide.enrollOnHub)
                .dmFont(.body)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Spacing.xs)
                .accessibilityIdentifier("add-device-enroll-hint")

            AddDeviceCard(AddDeviceGuide.computersTitle) {
                AddDeviceParagraph(AddDeviceGuide.computersLead)
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    AddDeviceOption(AddDeviceGuide.computerOptions[0], systemImage: "terminal")
                    AddDeviceOption(AddDeviceGuide.computerOptions[1], systemImage: "desktopcomputer")
                    AddDeviceOption(AddDeviceGuide.computerOptions[2], systemImage: "terminal")
                }
                AddDeviceParagraph(AddDeviceGuide.computersNote, isQuiet: true)
            }
            .accessibilityIdentifier("add-device-computers")

            AddDeviceCard(AddDeviceGuide.mobileTitle) {
                AddDeviceParagraph(AddDeviceGuide.mobileLead)
                AddDeviceOption(AddDeviceGuide.mobileOption, systemImage: "iphone")
                AddDeviceParagraph(AddDeviceGuide.mobileSteps, isQuiet: true)
            }
            .accessibilityIdentifier("add-device-mobile")
        }
    }
}

/// "View from another device": the dashboard's text and the link, as text and as a QR code.
private struct AddDeviceViewSection: View {
    @Environment(HubStore.self) private var store
    let model: AddDeviceInvitationModel

    var body: some View {
        let invitation = model.invitation
        AddDeviceCard(AddDeviceGuide.viewTitle) {
            AddDeviceParagraph(AddDeviceGuide.viewText)
            switch invitation.state {
            case .ready(let link, let expires):
                ready(link, expires: expires)
            case .creating:
                waiting
            case .failed(let text):
                BannerView(text, kind: .critical, actionTitle: BrowserInvitation.Labels.retry) { model.create(from: store) }
                    .accessibilityIdentifier("add-device-link-error")
            case .unavailable:
                BannerView(BrowserInvitation.Labels.unavailable, kind: .info)
                    .accessibilityIdentifier("add-device-link-unavailable")
            case .expired, .idle:
                lapsed(invitation)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: invitation.state)
        .accessibilityIdentifier("add-device-view")
    }

    @ViewBuilder
    private func ready(_ link: URL, expires: Double) -> some View {
        Group {
            if let code = model.qrCode {
                AddDeviceQRView(code: code)
                    .accessibilityIdentifier("add-device-qr")
            }
        }
        .frame(maxWidth: .infinity)
        AddDeviceParagraph(AddDeviceGuide.scanHint, isQuiet: true, alignment: .center)
        AddDeviceLinkText(link: link, identifier: "add-device-link")
        AddDeviceButtonRow {
            AddDeviceLinkActions(link: link, expires: expires, size: .regular, identifier: "add-device")
        } trailing: {
            Button(BrowserInvitation.Labels.renew) { model.create(from: store) }
                .buttonStyle(.dm())
                .accessibilityIdentifier("add-device-new-link-button")
        }
        AddDeviceParagraph(BrowserInvitation.Labels.validity, isQuiet: true)
    }

    /// The same shape as a link that is ready, so the sheet does not jump when the hub answers.
    @ViewBuilder
    private var waiting: some View {
        AddDeviceQRPlaceholder {
            ProgressView()
                .tint(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
        HStack(spacing: Theme.Spacing.s) {
            Text(BrowserInvitation.Labels.creating)
                .dmFont(.callout)
                .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("add-device-link-loading")
    }

    @ViewBuilder
    private func lapsed(_ invitation: BrowserInvitation) -> some View {
        AddDeviceQRPlaceholder {
            Image(systemName: invitation.state == .expired ? "clock.badge.xmark" : "qrcode")
                .font(.system(size: 34))
                .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
        if let message = invitation.message {
            AddDeviceParagraph(message, alignment: .center)
                .accessibilityIdentifier("add-device-link-expired")
        }
        if let label = invitation.actionLabel {
            Button(label) { model.create(from: store) }
                .buttonStyle(.dm(.primary, fillsWidth: true))
                .accessibilityIdentifier("add-device-new-link-button")
        }
    }
}

/// A headed card of the sheet: an uppercase label over a surface.
private struct AddDeviceCard<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionLabel(title)
                .padding(.horizontal, Theme.Spacing.xs)
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.l)
            .dmSurface(Theme.surface1, radius: Theme.Radius.card)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct AddDeviceParagraph: View {
    private let text: String
    private let isQuiet: Bool
    private let alignment: TextAlignment

    init(_ text: String, isQuiet: Bool = false, alignment: TextAlignment = .leading) {
        self.text = text
        self.isQuiet = isQuiet
        self.alignment = alignment
    }

    var body: some View {
        Text(text)
            .dmFont(isQuiet ? .caption : .callout)
            .foregroundStyle(isQuiet ? Theme.textMuted : Theme.textSecondary)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
    }
}

/// One of the hub's own choices under "+", named as the hub names it.
private struct AddDeviceOption: View {
    private let title: String
    private let systemImage: String

    @ScaledMetric(relativeTo: .callout) private var iconWidth: CGFloat = 22

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.accent)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dmFont(.bodyStrong)
    }
}

/// Buttons side by side while they fit, stacked at large text sizes.
private struct AddDeviceButtonRow<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.s) {
                leading
                Spacer(minLength: Theme.Spacing.s)
                trailing
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(spacing: Theme.Spacing.s) { leading }
                trailing
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                leading
                trailing
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Add a device") {
    AddDeviceSheet()
        .demoEnvironment()
}
