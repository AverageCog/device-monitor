import DMCore
import SwiftUI

/// The two ways to hand over an invitation (scan it, paste it), the name this device gets on the
/// hub, and Connect. The session controller does the pairing and words every failure.
///
/// The invitation lets whoever holds it in until it is used, so it is typed and shown hidden,
/// never logged, and dropped as soon as the hub has accepted it.
struct OnboardingPairingForm: View {
    let viewport: OnboardingViewport

    private enum Field: Hashable {
        case invitation, name
    }

    @Environment(SessionController.self) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var invitation = OnboardingPairingForm.suggestedInvitation
    @State private var name = OnboardingPairingForm.suggestedName
    /// The text the last attempt was made with. The error on show is about that text, and goes
    /// once it is edited.
    @State private var attempted: String?
    @State private var isScannerPresented = OnboardingPairingForm.opensScanner
    @State private var hasCamera = OnboardingPairingForm.deviceHasCamera
    @State private var fieldsHeight: CGFloat = 0
    /// `viewport.visibleHeight`, where a task that outlives this value of the view can read it.
    @State private var visibleHeight: CGFloat = 0
    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            scanner
            HStack(spacing: Theme.Spacing.m) {
                Hairline()
                Text(OnboardingCopy.or)
                    .dmFont(.caption)
                    .foregroundStyle(Theme.textMuted)
                Hairline()
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.m + 2) {
                invitationField
                nameField
                if let error {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs + 2) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .accessibilityHidden(true)
                        Text(error)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("pair-error")
                    }
                    .dmFont(.callout)
                    .foregroundStyle(Theme.dangerText)
                    .transition(.opacity)
                }
                connectButton
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { fieldsHeight = $0 })
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: error)
        .sheet(isPresented: $isScannerPresented) {
            OnboardingScannerSheet { text in
                isScannerPresented = false
                invitation = text
                connect(with: text)
            }
        }
        .onChange(of: focus) { reveal() }
        .onChange(of: viewport.visibleHeight, initial: true) { _, height in
            visibleHeight = height
            reveal()
        }
        #if DEBUG
        .task {
            let options = OnboardingDebugOptions.current
            guard options.focus != nil || options.scroll != nil else { return }
            try? await Task.sleep(for: .milliseconds(600))
            if let field = options.focus { focus = field == "name" ? .name : .invitation }
            switch options.scroll {
            case "fields": viewport.scroll.scrollTo(OnboardingAnchor.fields, anchor: .bottom)
            case "end": viewport.scroll.scrollTo(OnboardingAnchor.end, anchor: .bottom)
            default: break
            }
        }
        #endif
    }

    // MARK: - Parts

    private var scanner: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Button {
                focus = nil
                isScannerPresented = true
            } label: {
                Label(OnboardingCopy.scan, systemImage: "qrcode.viewfinder")
            }
            // The screen's one accent button is the next step: scanning, until there is an
            // invitation in the field, then Connect.
            .buttonStyle(.dm(canConnect ? .secondary : .primary, size: .large, fillsWidth: true))
            .disabled(isBusy || !hasCamera)
            .accessibilityIdentifier("pair-scan-button")
            if !hasCamera {
                Text(OnboardingCopy.noCamera)
                    .dmFont(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pair-scan-unavailable")
            }
        }
    }

    private var invitationField: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs + 2) {
            // The Paste button moves under the field at the text sizes where both no longer fit.
            let row = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.s))
                : AnyLayout(HStackLayout(spacing: Theme.Spacing.s))
            row {
                HStack(spacing: 0) {
                    SecureField(OnboardingCopy.invitationLabel, text: $invitation, prompt: Text(OnboardingCopy.invitationPrompt).foregroundStyle(Theme.textMuted))
                        .textFieldStyle(.plain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        // Keeps the keyboard from offering to save it as a password.
                        .textContentType(.oneTimeCode)
                        .submitLabel(.go)
                        .focused($focus, equals: .invitation)
                        .onSubmit { connect(with: invitation) }
                        .accessibilityLabel(OnboardingCopy.invitationLabel)
                        .accessibilityIdentifier("pair-invitation-field")
                    if !invitation.isEmpty, !isBusy {
                        Button {
                            invitation = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 17))
                                .foregroundStyle(Theme.textMuted)
                                .frame(width: 36, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // The glyph sits in the field's padding; its touch target reaches past it.
                        .padding(.trailing, -Theme.Spacing.s)
                        .padding(.vertical, -Theme.Spacing.s)
                        .accessibilityLabel(OnboardingCopy.clearInvitation)
                        .accessibilityIdentifier("pair-clear-button")
                    }
                }
                // Marked only when the text itself is the problem; an unreachable hub is not.
                .onboardingField(isFocused: focus == .invitation, isInvalid: error != nil && invitedOrigin == nil)
                // The system's own button: it reads the pasteboard without the "Allow Paste" question.
                // Its handler makes no promise about the thread it is called on.
                PasteButton(payloadType: String.self) { @Sendable strings in
                    guard let text = strings.first else { return }
                    Task { @MainActor in pasted(text) }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.roundedRectangle(radius: Theme.Radius.control))
                .tint(Theme.surface2)
                .accessibilityIdentifier("pair-paste-button")
            }
            .disabled(isBusy)

            // Which hub the invitation is for is no secret, and worth seeing before connecting.
            if let origin = invitedOrigin {
                HStack(spacing: Theme.Spacing.xs + 2) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.good)
                    Text(origin)
                        .monospaced()
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .dmFont(.caption)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(OnboardingCopy.invitationHub(origin))
                .accessibilityIdentifier("pair-invitation-hub")
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: invitedOrigin)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs + 2) {
            SectionLabel(OnboardingCopy.nameLabel)
                .accessibilityHidden(true)
            TextField(OnboardingCopy.nameLabel, text: $name, prompt: Text(AppModel.deviceName).foregroundStyle(Theme.textMuted))
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(canConnect ? .go : .done)
                .focused($focus, equals: .name)
                .onSubmit {
                    if canConnect { connect(with: invitation) } else { focus = nil }
                }
                .onboardingField(isFocused: focus == .name)
                .disabled(isBusy)
                .accessibilityLabel(OnboardingCopy.nameLabel)
                .accessibilityHint(OnboardingCopy.nameHint)
                .accessibilityIdentifier("pair-name-field")
            Text(OnboardingCopy.nameHint)
                .dmFont(.caption)
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
    }

    private var connectButton: some View {
        Button {
            connect(with: invitation)
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                if isBusy {
                    ProgressView()
                        .tint(Theme.onAccent)
                }
                Text(isBusy ? OnboardingCopy.verifying : OnboardingCopy.connect)
            }
        }
        .buttonStyle(.dm(.primary, size: .large, fillsWidth: true))
        .disabled(isBusy || !canConnect)
        .accessibilityIdentifier("pair-connect-button")
    }

    // MARK: - State

    private var canConnect: Bool {
        !invitation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isBusy: Bool {
        #if DEBUG
        if OnboardingDebugOptions.current.showsBusy { return true }
        #endif
        return session.isPairing
    }

    /// Why pairing failed, or why the stored enrollment could not be used: the session's words.
    private var error: String? {
        guard let message = session.pairingError, attempted == nil || attempted == invitation else { return nil }
        return message
    }

    /// The hub a well-formed invitation is for. Anything else is explained when Connect is pressed.
    private var invitedOrigin: String? {
        (try? Invitation.parse(invitation))?.origin.string
    }

    // MARK: - Actions

    private func pasted(_ text: String) {
        invitation = text.trimmingCharacters(in: .whitespacesAndNewlines)
        focus = nil
    }

    private func connect(with text: String) {
        guard !session.isPairing, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        focus = nil
        attempted = text
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if await session.pair(invitationText: text, name: label.isEmpty ? AppModel.deviceName : label) {
                // Spent: the hub takes an invitation once.
                invitation = ""
                attempted = nil
                OnboardingHaptics.success()
            } else {
                OnboardingHaptics.failure()
                if let message = session.pairingError { AccessibilityNotification.Announcement(message).post() }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                    viewport.scroll.scrollTo(OnboardingAnchor.fields, anchor: .bottom)
                }
            }
        }
    }

    /// With the keyboard up, brings the fields, the error and Connect into view together when
    /// there is room for all of them. Where there is not (a phone on its side), the system's own
    /// scrolling keeps the field being typed in on show, and the keyboard's Go key connects.
    private func reveal() {
        guard focus != nil else { return }
        Task {
            // After the keyboard has taken its room and the system has scrolled to the caret.
            try? await Task.sleep(for: .milliseconds(350))
            guard focus != nil, fieldsHeight > 0, fieldsHeight + 2 * Theme.Spacing.xl <= visibleHeight else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                viewport.scroll.scrollTo(OnboardingAnchor.fields, anchor: .bottom)
            }
        }
    }

    // MARK: - Starting values

    private static var suggestedInvitation: String {
        #if DEBUG
        DebugLaunchOptions.current.invitation ?? ""
        #else
        ""
        #endif
    }

    /// What the hub will list this device as unless the user says otherwise.
    private static var suggestedName: String {
        #if DEBUG
        DebugLaunchOptions.current.deviceName ?? AppModel.deviceName
        #else
        AppModel.deviceName
        #endif
    }

    private static var opensScanner: Bool {
        #if DEBUG
        OnboardingDebugOptions.current.scanner != nil
        #else
        false
        #endif
    }

    private static var deviceHasCamera: Bool {
        #if DEBUG
        if let pretended = OnboardingDebugOptions.current.hasCamera { return pretended }
        #endif
        return OnboardingScannerCamera.deviceHasCamera
    }
}
