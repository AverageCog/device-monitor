import DMCore
import SwiftUI
import UIKit

/// The devices an alert or a rule may name: id and name, in the dashboard's order. Stripped of
/// readings, so it changes when a device is added, removed or renamed and not with every report.
nonisolated struct AlertsDirectory: Equatable, Sendable {
    private(set) var devices: [Device] = []

    init() {}

    init(_ devices: [Device]) {
        self.devices = devices.map { Device(id: $0.id, name: $0.name, hostname: $0.hostname) }
    }

    func contains(_ id: String) -> Bool {
        devices.contains { $0.id == id }
    }

    /// The hub's name for the device a rule is for: "All devices", its name, or the id of one that is gone.
    func name(of id: String) -> String {
        AlertText.deviceName(id, devices: devices)
    }
}

/// Keeps the directory and the current day in step with the store. Reports arrive every two
/// seconds; only this invisible view is re-evaluated for them, and it hands on a change only
/// when the device list or the date really changed.
struct AlertsStoreWatcher: View {
    @Environment(HubStore.self) private var store
    @Binding var directory: AlertsDirectory
    /// The first instant of today, ms since 1970.
    @Binding var dayStart: Double

    var body: some View {
        let fresh = AlertsDirectory(store.devices)
        // The hub's heartbeat is what moves time on this screen (and in a demo on a clock of its own).
        let day = Calendar.current.startOfDay(for: Date(hubTime: store.lastStatusAt ?? store.clock.now)).hubTime
        Color.clear
            .onChange(of: fresh, initial: true) { _, fresh in directory = fresh }
            .onChange(of: day, initial: true) { _, day in dayStart = day }
            .accessibilityHidden(true)
    }
}

nonisolated enum AlertsLayout {
    /// The list of alerts stops growing at this width; wider screens centre it.
    static let listWidth: CGFloat = 680
    /// The editor's width, the same as the Settings tab's.
    static let formWidth: CGFloat = 560
    /// "iPhone" or "iPad", for wording about this device.
    @MainActor static var deviceName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }
}

/// The names of the hub's delivery channels, as the editor and the test result both write them.
nonisolated enum AlertsChannel {
    static let apps = "Device Monitor apps"
    static let ntfy = "ntfy"
    static let webhook = "Webhook"
}

nonisolated enum AlertsGlyph {
    /// An SF Symbol for what a rule watches.
    static func symbol(for kind: AlertRule.Kind?) -> String {
        switch kind {
        case .offline: "wifi.slash"
        case .cpuTemp, .gpuTemp: "thermometer.medium"
        case .cpu: "cpu"
        case .gpu: "cpu.fill"
        case .mem: "memorychip"
        case .disk: "internaldrive"
        case .power: "bolt.fill"
        case .dailyCost: "banknote"
        case .other, nil: "bell"
        }
    }
}

/// A glyph on a tinted rounded plate, heading an alert or a rule.
struct AlertsIconPlate: View {
    let symbol: String
    let tint: Color
    var side: CGFloat = 34

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        // Grows with the text beside it, but not so far that it crowds the text out.
        let factor = min(scale, 1.5)
        Image(systemName: symbol)
            .font(.system(size: side * 0.44 * factor, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: side * factor, height: side * factor)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A page-level section heading with an optional control at its trailing edge.
struct AlertsHeading<Accessory: View>: View {
    private let title: String
    private let accessory: Accessory

    init(_ title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            SectionLabel(title, size: .large)
            accessory
        }
        .padding(.horizontal, Theme.Spacing.xs)
        .frame(minHeight: 30)
    }
}

extension AlertsHeading where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

/// A row of a `SettingsSection` with content of its own: the same padding, height and hairline
/// as `SettingsRow`, for rows that hold more than a title and one control.
struct AlertsRow<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            content
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .overlay(alignment: .top) { Hairline() }
    }
}

/// The title and description of a row, in `SettingsRow`'s styles.
struct AlertsRowText: View {
    let title: String
    var description: String?

    var body: some View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Text on one side and a control on the other; at the accessibility text sizes the control
/// moves under the text instead of squeezing it.
struct AlertsSplitRow<Control: View>: View {
    private let title: String
    private let description: String?
    private let control: Control

    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ title: String, description: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.description = description
        self.control = control()
    }

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                AlertsRowText(title: title, description: description)
                control
            }
        } else if description == nil {
            // Side by side while both fit whole; otherwise the control goes underneath, where a
            // long device name has the full width before it is shortened.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Theme.Spacing.l) {
                    titleText
                        .fixedSize()
                    control
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    titleText
                    control
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            // A description wraps; the control keeps the width it needs.
            HStack(alignment: .center, spacing: Theme.Spacing.l) {
                AlertsRowText(title: title, description: description)
                control
                    .layoutPriority(1)
            }
        }
    }

    private var titleText: some View {
        Text(title)
            .dmFont(.rowTitle)
            .foregroundStyle(Theme.textPrimary)
    }
}

/// What the presentation layer has to say about a field: an error the hub would refuse, or a
/// warning about what it will do instead.
struct AlertsIssueLabel: View {
    private let message: String
    private let isError: Bool

    init(_ issue: AlertIssue) {
        message = issue.message
        isError = issue.severity == .error
    }

    init(_ message: String, isError: Bool) {
        self.message = message
        self.isError = isError
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dmFont(.caption)
        .foregroundStyle(isError ? Theme.dangerText : Theme.warning)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((isError ? "Error: " : "Warning: ") + message)
    }
}

/// A pop-up choice drawn as the dashboard draws a `select`: the current value on surface-2 with
/// a hairline border.
struct AlertsSelect<Value: Hashable & Sendable>: View {
    private let title: String
    @Binding private var selection: Value
    private let options: [DMSegment<Value>]
    private let identifier: String

    init(_ title: String, selection: Binding<Value>, options: [DMSegment<Value>], identifier: String) {
        self.title = title
        _selection = selection
        self.options = options
        self.identifier = identifier
    }

    var body: some View {
        let current = options.first { $0.value == selection }?.label ?? ""
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options) { option in
                    Text(option.label).tag(option.value)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(current)
                    .dmFont(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .dmSurface(Theme.surface2, radius: Theme.Radius.control)
            // Drawn 38 points high, touched over 44.
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .padding(.vertical, -3)
        }
        .accessibilityLabel(title)
        .accessibilityValue(current)
        .accessibilityIdentifier(identifier)
    }
}
