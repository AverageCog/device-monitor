import SwiftUI

/// A group of settings rows: an optional uppercase heading over a card whose rows are separated by
/// hairlines (the dashboard's `.set-section`, drawn as a card because the app has a whole screen).
struct SettingsSection<Content: View>: View {
    private let header: String?
    private let footer: String?
    private let content: Content

    init(_ header: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if let header {
                SectionLabel(header)
                    .padding(.horizontal, Theme.Spacing.xs)
            }
            VStack(spacing: 0) {
                content
            }
            // Every row draws a hairline on its top edge; shifting the stack up by that hairline and
            // clipping hides the first one, which leaves separators only between rows.
            .padding(.top, -Theme.Layout.hairline)
            .clipped()
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.xs)
            .dmSurface(Theme.surface1, radius: Theme.Radius.card)
            if let footer {
                Text(footer)
                    .dmFont(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, Theme.Spacing.xs)
            }
        }
    }
}

/// One settings row (`.set-row`): title, optional description and a trailing control.
///
///     SettingsRow("Temperature unit") {
///         DMSegmentedControl("Temperature unit", selection: $unit, segments: …)
///     }
struct SettingsRow<Trailing: View>: View {
    nonisolated enum Arrangement: Sendable {
        /// Text on the left, control on the right.
        case inline
        /// Control under the text, for wide controls (`.set-row.wrap`).
        case stacked
    }

    private let title: String
    private let description: String?
    private let descriptionStyle: DMTextStyle
    private let layout: Arrangement
    private let trailing: Trailing

    /// - Parameters:
    ///   - description: Secondary text under the title.
    ///   - isMonospaced: Shows the description in the monospaced face, for addresses and invitations.
    init(
        _ title: String,
        description: String? = nil,
        isMonospaced: Bool = false,
        layout: Arrangement = .inline,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.description = description
        self.descriptionStyle = isMonospaced ? .mono : .callout
        self.layout = layout
        self.trailing = trailing()
    }

    var body: some View {
        Group {
            switch layout {
            case .inline:
                HStack(alignment: .center, spacing: Theme.Spacing.l) {
                    text
                    trailing
                }
            case .stacked:
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    text
                    trailing
                }
            }
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .overlay(alignment: .top) { Hairline() }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .dmFont(.rowTitle)
                .foregroundStyle(Theme.textPrimary)
            if let description {
                Text(description)
                    .dmFont(descriptionStyle)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SettingsRow where Trailing == EmptyView {
    /// A row that only shows text.
    init(_ title: String, description: String? = nil, isMonospaced: Bool = false) {
        self.init(title, description: description, isMonospaced: isMonospaced) { EmptyView() }
    }
}

/// A settings row that is a switch as a whole (`label.set-row` with `.switch`).
struct SettingsToggleRow: View {
    private let title: String
    private let description: String?
    @Binding private var isOn: Bool

    init(_ title: String, description: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.description = description
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .dmFont(.rowTitle)
                    .foregroundStyle(Theme.textPrimary)
                if let description {
                    Text(description)
                        .dmFont(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.dm)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .overlay(alignment: .top) { Hairline() }
    }
}

/// The dashboard's switch (`.switch`): grid-coloured track with a secondary knob; accent track with
/// a dark knob when on. The whole row toggles.
struct DMToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        DMToggleBody(configuration: configuration)
    }
}

extension ToggleStyle where Self == DMToggleStyle {
    static var dm: DMToggleStyle { DMToggleStyle() }
}

private struct DMToggleBody: View {
    let configuration: ToggleStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Theme.Spacing.l) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
            Capsule()
                .fill(configuration.isOn ? Theme.accent : Theme.grid)
                .frame(width: 46, height: 28)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(configuration.isOn ? Theme.onAccent : Theme.textSecondary)
                        .frame(width: 20, height: 20)
                        .padding(4)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isOn)
        }
        .opacity(isEnabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

extension View {
    /// The look of a text input (`select`, `.set-price input`): surface-2, hairline border, radius 8.
    /// Use on a `TextField` with `.textFieldStyle(.plain)`.
    func dmField(isInvalid: Bool = false) -> some View {
        dmFont(.body)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .dmSurface(Theme.surface2, radius: Theme.Radius.control, border: isInvalid ? Theme.critical : Theme.border)
    }
}

/// Selectable monospaced text on the inset background (`.cmd code`): invitations, links, commands.
struct MonoBlock: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .dmFont(.mono)
            .foregroundStyle(Theme.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .dmSurface(Theme.inset, radius: Theme.Radius.control)
    }
}

#Preview("Settings rows") {
    @Previewable @State var unit = "C"
    @Previewable @State var notifications = true
    @Previewable @State var name = "My iPhone"
    ScrollView {
        VStack(spacing: 22) {
            SettingsSection("Display") {
                SettingsRow("Temperature unit") {
                    DMSegmentedControl("Temperature unit", selection: $unit, segments: [DMSegment("C", "°C"), DMSegment("F", "°F")])
                }
                SettingsToggleRow("Alert notifications", description: "Show a notification when a device crosses one of your alert rules.", isOn: $notifications)
            }
            SettingsSection("Hub", footer: "Disconnecting removes this iPhone from the hub.") {
                SettingsRow("Address", description: "https://hub.tailnet.ts.net", isMonospaced: true)
                SettingsRow("This device", layout: .stacked) {
                    TextField("Name", text: $name).textFieldStyle(.plain).dmField()
                }
                SettingsRow("Dashboard link", description: "Copy a single-use browser invitation.") {
                    Button("Copy") {}.buttonStyle(.dm(size: .small))
                }
            }
            MonoBlock("https://hub.tailnet.ts.net/unlock#join=Zm9vYmFyYmF6cXV4")
        }
        .padding()
    }
    .background(Theme.page)
    .preferredColorScheme(.dark)
}
