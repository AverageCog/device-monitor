import SwiftUI

/// A small uppercase, letter-spaced, muted heading.
struct SectionLabel: View {
    nonisolated enum Size: Sendable {
        /// Inside a card (`.section h4`).
        case small
        /// Above a group of panels on a page (`.adv-h`).
        case large
    }

    private let text: String
    private let size: Size

    init(_ text: String, size: Size = .small) {
        self.text = text
        self.size = size
    }

    var body: some View {
        Text(text)
            .dmFont(size == .small ? .sectionLabel : .sectionHeader)
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One entry of a chart legend: a short coloured line and a label (`.legend span`).
struct LegendItem: View {
    private let label: String
    private let color: Color

    init(_ label: String, color: Color) {
        self.label = label
        self.color = color
    }

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 2)
            Text(label)
                .dmFont(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// A row of legend entries with an optional trailing accessory, such as a card's range menu.
struct LegendRow<Accessory: View>: View {
    private let items: [(label: String, color: Color)]
    private let accessory: Accessory

    init(_ items: [(label: String, color: Color)], @ViewBuilder accessory: () -> Accessory) {
        self.items = items
        self.accessory = accessory()
    }

    var body: some View {
        // One line when it fits; at large text sizes the accessory moves under the entries.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.m) {
                entries
                Spacer(minLength: Theme.Spacing.s)
                accessory
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                FlowLayout(spacing: Theme.Spacing.m, lineSpacing: Theme.Spacing.xs) {
                    entries
                }
                accessory
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var entries: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            LegendItem(item.label, color: item.color)
                .fixedSize()
        }
    }
}

extension LegendRow where Accessory == EmptyView {
    init(_ items: [(label: String, color: Color)]) {
        self.init(items) { EmptyView() }
    }
}

/// One row of `KeyValueRows`. Labels may repeat (two sensors can share a name).
nonisolated struct KeyValueItem: Hashable, Sendable {
    var label: String
    /// A quiet annotation after the label, e.g. a model's kind ("unet").
    var detail: String?
    var value: String

    init(_ label: String, _ value: String, detail: String? = nil) {
        self.label = label
        self.detail = detail
        self.value = value
    }
}

/// Label on the left, right-aligned tabular value on the right (`.kv`).
struct KeyValueRows: View {
    nonisolated enum Style: Sendable {
        /// The label keeps its width and a long value wraps (`.kv`).
        case standard
        /// The value keeps its width and a long label is truncated (`.kv.ai-list`).
        case valueFirst
    }

    private let items: [KeyValueItem]
    private let style: Style

    @ScaledMetric(relativeTo: .caption2) private var detailSize: CGFloat = DMTextStyle.micro.size

    init(_ items: [KeyValueItem], style: Style = .standard) {
        self.items = items
        self.style = style
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
                    label(for: item)
                    Spacer(minLength: 0)
                    Text(item.value)
                        .dmFont(.callout)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(style == .valueFirst ? 1 : 3)
                        .fixedSize(horizontal: style == .valueFirst, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([item.label, item.detail].compactMap { $0 }.joined(separator: ", "))
                .accessibilityValue(item.value)
            }
        }
    }

    private func label(for item: KeyValueItem) -> some View {
        // One Text, so the label and its annotation truncate as a unit.
        var text = AttributedString(item.label)
        text.swiftUI.foregroundColor = Theme.textSecondary
        if let detail = item.detail {
            var small = AttributedString(" " + detail)
            small.swiftUI.foregroundColor = Theme.textMuted
            small.swiftUI.font = .system(size: detailSize)
            text.append(small)
        }
        return Text(text)
            .dmFont(.callout)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// The head of a device card (`.card-head`): status dot, name, sub line and, when menu items are
/// given, the "…" options menu.
///
///     CardHeader(title: device.name, subtitle: line, isOnline: true) {
///         Button("History") { … }
///         Button("Rename") { … }
///         Button("Remove from dashboard", role: .destructive) { … }
///     }
struct CardHeader<MenuItems: View>: View {
    private let title: String
    private let subtitle: String
    private let isOnline: Bool
    private let menuItems: MenuItems

    init(title: String, subtitle: String, isOnline: Bool, @ViewBuilder menu: () -> MenuItems) {
        self.title = title
        self.subtitle = subtitle
        self.isOnline = isOnline
        self.menuItems = menu()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            DeviceTitle(title: title, subtitle: subtitle, isOnline: isOnline)
            if MenuItems.self != EmptyView.self {
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Device options")
                // The glyph, not its 34-point plate, lines up with the card's content edge.
                .padding(.top, -6)
                .padding(.trailing, -6)
            }
        }
    }
}

extension CardHeader where MenuItems == EmptyView {
    init(title: String, subtitle: String, isOnline: Bool) {
        self.init(title: title, subtitle: subtitle, isOnline: isOnline) { EmptyView() }
    }
}

/// Status dot, device name and sub line (`.dot` + `.titles`). Also fits a row of the offline list.
struct DeviceTitle: View {
    private let title: String
    private let subtitle: String
    private let isOnline: Bool

    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = DMTextStyle.cardTitle.size

    init(title: String, subtitle: String, isOnline: Bool) {
        self.title = title
        self.subtitle = subtitle
        self.isOnline = isOnline
    }

    var body: some View {
        // Half the height of the name's capitals, measured up from the baseline.
        let capitalsMiddle = 0.35 * titleSize
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            StatusDot(isOnline: isOnline)
                // Centre the dot on the capitals of the name, whatever the text size.
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + capitalsMiddle - $0.height / 2 }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .dmFont(.cardTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .dmFont(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(isOnline ? "Online" : "Offline"), \(subtitle)")
        .accessibilityAddTraits(.isHeader)
    }
}

/// A semibold name with a quiet trailing note, heading a list inside a section (`.ai-app`):
/// "ComfyUI" … "57.7 GB GPU memory".
struct SubsectionHeader: View {
    private let title: String
    private let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            Text(title)
                .dmFont(.panelTitle)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let detail {
                Text(detail)
                    .dmFont(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A headed block inside a card's details (`.section`): 14 pt above, heading, content.
struct DMSection<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionLabel(title)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14)
    }
}

/// The collapsible "Details" part of a card (`details` / `summary`): a hairline, a toggle row with a
/// small triangle, and the content when open.
struct DetailsDisclosure<Content: View>: View {
    private let title: String
    @Binding private var isExpanded: Bool
    private let content: Content

    init(_ title: String = "Details", isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        _isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hairline()
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: 7))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title)
                        .dmFont(.caption)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 10)
                .padding(.bottom, isExpanded ? 0 : 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                content
            }
        }
    }
}

#Preview("Labels and rows") {
    ScrollView {
        DMCard {
            CardHeader(title: "DGX Spark", subtitle: "Ubuntu 24.04 LTS · up 12d 0h · v1.2.27", isOnline: true)
            LegendRow([("CPU", Theme.cpu), ("GPU", Theme.gpu), ("Memory", Theme.mem)])
            DetailsDisclosure(isExpanded: .constant(true)) {
                DMSection("Loaded models") {
                    KeyValueRows([
                        KeyValueItem("flux2_dev_fp8.safetensors", "22.2 GB", detail: "unet"),
                        KeyValueItem("qwen3_vl_8b.safetensors", "15.3 GB", detail: "clip"),
                    ], style: .valueFirst)
                }
                DMSection("GPU") {
                    KeyValueRows([
                        KeyValueItem("Model", "NVIDIA GB10"),
                        KeyValueItem("Load", "95%"),
                        KeyValueItem("Power", "130 W / 140 W"),
                    ])
                }
            }
        }
        .padding()
    }
    .background(Theme.page)
    .preferredColorScheme(.dark)
}
