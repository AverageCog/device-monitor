import SwiftUI

/// A centred title, message and optional actions for a screen or panel with nothing to show
/// (`.empty`, and the layout of app/offline.html).
struct EmptyStateView<Actions: View>: View {
    private let title: String?
    private let message: String
    private let hint: String?
    private let systemImage: String?
    private let isCompact: Bool
    private let actions: Actions

    /// - Parameters:
    ///   - title: Omit for the one-line form, e.g. "All devices are offline."
    ///   - hint: A smaller muted note under the actions.
    ///   - isCompact: Less padding and smaller text (`.empty.small`), for use inside a panel.
    init(
        title: String? = nil,
        message: String,
        hint: String? = nil,
        systemImage: String? = nil,
        isCompact: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.message = message
        self.hint = hint
        self.systemImage = systemImage
        self.isCompact = isCompact
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: isCompact ? 24 : 34, weight: .regular))
                    .foregroundStyle(Theme.accent)
                    .padding(.bottom, 14)
                    .accessibilityHidden(true)
            }
            if let title {
                Text(title)
                    .dmFont(.emptyTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)
            }
            // Each text keeps its full height: inside a container that offers less than the content
            // needs (a centred phase screen), an unfixed Text gives up its last line instead of growing.
            Text(message)
                .dmFont(isCompact ? .statValue : .body)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if Actions.self != EmptyView.self {
                // Side by side while the labels fit; stacked at large text sizes instead of truncating.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Spacing.s) { actions }
                    VStack(spacing: Theme.Spacing.s) { actions }
                }
                .padding(.top, 18)
            }
            if let hint {
                Text(hint)
                    .dmFont(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
        .padding(.horizontal, 20)
        .padding(.vertical, isCompact ? 28 : 40)
        .frame(maxWidth: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(title: String? = nil, message: String, hint: String? = nil, systemImage: String? = nil, isCompact: Bool = false) {
        self.init(title: title, message: message, hint: hint, systemImage: systemImage, isCompact: isCompact) { EmptyView() }
    }
}

extension EmptyStateView where Actions == EmptyStateAction {
    /// The common case: one primary action.
    init(
        title: String? = nil,
        message: String,
        hint: String? = nil,
        systemImage: String? = nil,
        isCompact: Bool = false,
        actionTitle: String,
        action: @escaping () -> Void
    ) {
        self.init(title: title, message: message, hint: hint, systemImage: systemImage, isCompact: isCompact) {
            EmptyStateAction(title: actionTitle, action: action)
        }
    }
}

/// The single primary button of the `actionTitle:action:` form of `EmptyStateView`.
struct EmptyStateAction: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.dm(.primary))
    }
}

/// An inline status strip (`.legacy-banner`): tinted background and border, an icon or spinner,
/// a message and an optional action. Use `.neutral` with `showsProgress` for "Reconnecting to hub…".
struct BannerView: View {
    nonisolated enum Kind: Sendable {
        case neutral, info, success, warning, critical

        var tint: Color? {
            switch self {
            case .neutral: nil
            case .info: Theme.accent
            case .success: Theme.good
            case .warning: Theme.warning
            case .critical: Theme.critical
            }
        }

        var defaultSymbol: String? {
            switch self {
            case .neutral: nil
            case .info: "info.circle"
            case .success: "checkmark.circle"
            case .warning: "exclamationmark.triangle"
            case .critical: "exclamationmark.octagon"
            }
        }
    }

    private let text: String
    private let kind: Kind
    private let systemImage: String?
    private let showsProgress: Bool
    private let actionTitle: String?
    private let action: (() -> Void)?

    /// - Parameters:
    ///   - systemImage: Overrides the kind's symbol.
    ///   - showsProgress: Shows a spinner in place of the symbol.
    init(
        _ text: String,
        kind: Kind = .neutral,
        systemImage: String? = nil,
        showsProgress: Bool = false,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.text = text
        self.kind = kind
        self.systemImage = systemImage
        self.showsProgress = showsProgress
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        let tint = kind.tint
        HStack(spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.m) {
                // One width for spinner and symbols, so stacked banners line their text up.
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tint ?? Theme.textSecondary)
                        .frame(width: 22)
                } else if let symbol = systemImage ?? kind.defaultSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(tint ?? Theme.textSecondary)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                }
                Text(text)
                    .dmFont(.callout)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.dm(kind == .neutral ? .secondary : .primary, size: .small))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .dmSurface(
            tint.map { $0.opacity(0.08) } ?? Theme.surface2,
            radius: Theme.Radius.banner,
            border: tint.map { $0.opacity(0.35) } ?? Theme.border
        )
    }
}

#Preview("Feedback") {
    ScrollView {
        VStack(spacing: 14) {
            BannerView("Reconnecting to hub…", showsProgress: true)
            BannerView("This app is out of date. Version 1.2.32 is available.", kind: .warning, systemImage: "arrow.down.to.line", actionTitle: "Update") {}
            BannerView("Wake signal sent.", kind: .success)
            BannerView("Could not save the electricity price.", kind: .critical)
            EmptyStateView(
                title: "Can't reach the hub",
                message: "The PC hosting the dashboard may be off or asleep.",
                hint: "Certificate renewals reconnect automatically."
            ) {
                Button("Try again") {}.buttonStyle(.dm(.primary))
                Button("Change setup") {}.buttonStyle(.dm())
            }
            EmptyStateView(message: "All devices are offline.", isCompact: true)
                .dmSurface(radius: Theme.Radius.tile)
        }
        .padding()
    }
    .background(Theme.page)
}
