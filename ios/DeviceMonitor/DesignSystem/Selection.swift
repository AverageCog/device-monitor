import SwiftUI

/// One option of a `DMSegmentedControl`.
nonisolated struct DMSegment<Value: Hashable & Sendable>: Identifiable, Sendable {
    let value: Value
    let label: String
    /// Suffix of the segment's accessibility identifier; defaults to the label.
    let identifier: String?

    var id: Value { value }

    init(_ value: Value, _ label: String, identifier: String? = nil) {
        self.value = value
        self.label = label
        self.identifier = identifier
    }
}

/// The dashboard's segmented control (`.seg`): a hairline-bordered row of quiet labels with the
/// selected one on surface-2.
///
/// Where the labels do not fit side by side, even a little smaller, the segments go one under the
/// other, the chosen one with a check mark, rather than a label being cut short. The control and
/// its segments keep their names for VoiceOver and UI tests in either form.
///
///     DMSegmentedControl("Time range", selection: $range, segments: [
///         DMSegment(.day, "24 h"), DMSegment(.week, "7 days"), DMSegment(.month, "30 days"),
///     ])
struct DMSegmentedControl<Value: Hashable & Sendable>: View {
    private let title: String
    @Binding private var selection: Value
    private let segments: [DMSegment<Value>]
    private let fillsWidth: Bool
    private let identifier: String?

    @ScaledMetric(relativeTo: .callout) private var minHeight: CGFloat = 32
    @ScaledMetric(relativeTo: .callout) private var checkSize: CGFloat = DMTextStyle.callout.size * 0.7

    /// Clear space on either side of a label.
    private static var labelPadding: CGFloat { 11 }
    /// How small a label may get to keep the segments side by side.
    private static var minimumScale: CGFloat { 0.85 }

    /// - Parameters:
    ///   - title: What the control chooses; read by VoiceOver.
    ///   - fillsWidth: Segments share the available width equally instead of hugging their labels.
    ///   - identifier: Prefix for accessibility identifiers: the control gets `<identifier>` and each
    ///     segment `<identifier>-<segment identifier>`.
    init(_ title: String, selection: Binding<Value>, segments: [DMSegment<Value>], fillsWidth: Bool = false, identifier: String? = nil) {
        self.title = title
        _selection = selection
        self.segments = segments
        self.fillsWidth = fillsWidth
        self.identifier = identifier
    }

    var body: some View {
        // At the largest text sizes "Time of use" was cut to "Time of…". The labels at their
        // size if they fit, else a little smaller, else a row each.
        ViewThatFits(in: .horizontal) {
            row(minimumScale: 1)
            row(minimumScale: Self.minimumScale)
            column
        }
        .animation(.easeOut(duration: 0.15), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier ?? "")
    }

    /// The segments side by side; the labels shrink to `minimumScale` at most.
    private func row(minimumScale: CGFloat) -> some View {
        // The plate is 32 points tall at the standard text size, the touch target 44. It is
        // widened on each segment: a larger shape around the whole row does not reach its buttons.
        // Across, the row itself keeps each segment 44 points wide at least.
        let reach = max(0, (44 - minHeight) / 2)
        return DMSegmentRow(fillsWidth: fillsWidth, minimumScale: minimumScale, padding: 2 * Self.labelPadding) {
            ForEach(segments) { segment in
                button(for: segment) { isOn in
                    Text(segment.label)
                        .dmFont(.callout)
                        .lineLimit(1)
                        .minimumScaleFactor(minimumScale)
                        .foregroundStyle(isOn ? Theme.textPrimary : Theme.textMuted)
                        .padding(.horizontal, Self.labelPadding)
                        // As wide as the row makes it.
                        .frame(maxWidth: .infinity, minHeight: minHeight)
                        .background(isOn ? Theme.surface2 : .clear)
                        .padding(.vertical, reach)
                        .contentShape(Rectangle())
                        .padding(.vertical, -reach)
                }
            }
        }
        .modifier(DMSegmentFrame())
    }

    /// The same control on its side: a row for each segment, the chosen one on its plate.
    private var column: some View {
        VStack(spacing: 0) {
            ForEach(segments) { segment in
                button(for: segment) { isOn in
                    HStack(spacing: Theme.Spacing.s) {
                        Text(segment.label)
                            .dmFont(.callout)
                            .foregroundStyle(isOn ? Theme.textPrimary : Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        // Without the plates side by side, the plate alone is a weak cue.
                        Image(systemName: "checkmark")
                            .font(.system(size: checkSize, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .opacity(isOn ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, Self.labelPadding)
                    .padding(.vertical, Theme.Spacing.s)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(isOn ? Theme.surface2 : .clear)
                    .contentShape(Rectangle())
                }
            }
        }
        .modifier(DMSegmentFrame())
    }

    private func button<Label: View>(for segment: DMSegment<Value>, @ViewBuilder label: (Bool) -> Label) -> some View {
        let isOn = segment.value == selection
        let content = label(isOn)
        return Button {
            selection = segment.value
        } label: {
            content
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier.map { "\($0)-\(segment.identifier ?? segment.label)" } ?? "")
    }
}

/// The outline of a `DMSegmentedControl`, which also rounds the plates of the end segments.
private struct DMSegmentFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: Theme.Layout.hairline)
            }
    }
}

/// The segments of a `DMSegmentedControl` side by side: each as wide as its label, or with
/// `fillsWidth` all as wide as the widest, so none is cut short while another has room to spare.
/// Given less, the labels narrow alike, down to `minimumScale`. No segment is narrower than a
/// touch target.
///
/// Its ideal width is what the labels need at about the smallest scale it allows, so a
/// `ViewThatFits` takes it only where they fit whole.
private struct DMSegmentRow: Layout {
    let fillsWidth: Bool
    let minimumScale: CGFloat
    /// The part of each segment's width that does not shrink with its label.
    let padding: CGFloat

    /// "°C" with its padding is 38 points wide at the standard text size, "1 h" 43: short of
    /// the 44 a finger needs across as well as down.
    private static var minWidth: CGFloat { 44 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(in: proposal.width, subviews: subviews)
        let height = zip(subviews, widths).map { subview, width in
            subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }.max() ?? 0
        return CGSize(width: widths.reduce(0, +), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(in: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width
        }
    }

    /// Each segment's share of `available`, or of the row's ideal width when that is `nil`.
    private func widths(in available: CGFloat?, subviews: Subviews) -> [CGFloat] {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        let wanted = fillsWidth ? Array(repeating: ideal.max() ?? 0, count: ideal.count) : ideal
        guard let available else {
            // Claimed with a little to spare: text does not narrow exactly in proportion to its
            // size (tracking, and the system font's optical sizes), and must not be cut short.
            return widths(wanted, scale: minimumScale < 1 ? min(1, minimumScale + 0.05) : 1)
        }
        let width = fillsWidth ? available : min(available, widths(wanted, scale: 1).reduce(0, +))
        return widths(wanted, scale: scale(wanted, fitting: width))
    }

    /// The segments with their labels at `scale` of their size, none narrower than `minWidth`.
    private func widths(_ wanted: [CGFloat], scale: CGFloat) -> [CGFloat] {
        wanted.map { max(Self.minWidth, padding + max(0, $0 - padding) * scale) }
    }

    /// The scale at which the segments add up to `width`.
    private func scale(_ wanted: [CGFloat], fitting width: CGFloat) -> CGFloat {
        // A segment held at `minWidth` gives no width up as the labels narrow, so the others
        // narrow a little further, which may bring another down to it: hold those in turn.
        var held = Set<Int>()
        while true {
            let free = wanted.indices.filter { !held.contains($0) }
            let shrinking = free.reduce(0) { $0 + max(0, wanted[$1] - padding) }
            // Every segment held: the row is as narrow as it goes.
            guard shrinking > 0 else { return 0 }
            let fixed = Self.minWidth * CGFloat(held.count) + padding * CGFloat(free.count)
            let scale = max(0, (width - fixed) / shrinking)
            let under = free.filter { padding + max(0, wanted[$0] - padding) * scale < Self.minWidth }
            if under.isEmpty { return scale }
            held.formUnion(under)
        }
    }
}

/// A quiet inline picker (`.range-sel`): the current choice in muted text with a small chevron,
/// opening a menu. A card uses it for its chart range ("last 60 min").
struct DMInlinePicker<Value: Hashable & Sendable>: View {
    private let title: String
    @Binding private var selection: Value
    private let options: [DMSegment<Value>]

    init(_ title: String, selection: Binding<Value>, options: [DMSegment<Value>]) {
        self.title = title
        _selection = selection
        self.options = options
    }

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options) { option in
                    Text(option.label).tag(option.value)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(options.first { $0.value == selection }?.label ?? "")
                    .dmFont(.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .fixedSize()
            .foregroundStyle(Theme.textMuted)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .padding(.vertical, -6)
        .accessibilityLabel(title)
        .accessibilityValue(options.first { $0.value == selection }?.label ?? "")
    }
}

/// The pill look of a device chip (`.hv-devices button`): surface-1 with a hairline border; the
/// selected chip has an accent border and primary text.
struct DMChipStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .dmFont(.callout)
            .lineLimit(1)
            .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(minHeight: 32)
            .background(configuration.isPressed ? Theme.surface2 : Theme.surface1, in: Capsule())
            .overlay {
                Capsule().strokeBorder(isSelected ? Theme.accent : Theme.border, lineWidth: Theme.Layout.hairline)
            }
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == DMChipStyle {
    static func dmChip(isSelected: Bool = false) -> DMChipStyle {
        DMChipStyle(isSelected: isSelected)
    }
}

/// A device chip of the History view: online dot, name, accent border when selected.
struct DeviceChip: View {
    private let name: String
    private let isOnline: Bool
    private let isSelected: Bool
    private let action: () -> Void

    init(_ name: String, isOnline: Bool, isSelected: Bool, action: @escaping () -> Void) {
        self.name = name
        self.isOnline = isOnline
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle()
                    .fill(isOnline ? Theme.good : Theme.textMuted)
                    .frame(width: 7, height: 7)
                Text(name)
            }
        }
        .buttonStyle(.dmChip(isSelected: isSelected))
        .accessibilityLabel(name)
        .accessibilityValue(isOnline ? "Online" : "Offline")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Lays children out in rows, wrapping when a row is full (`flex-wrap: wrap`). For chips and tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    private func rows(for width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (frames, CGSize(width: widest, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? .greatestFiniteMagnitude
        return rows(for: width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = rows(for: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }
}

#Preview("Selection") {
    @Previewable @State var range = "24h"
    @Previewable @State var device = "DGX Spark"
    VStack(alignment: .leading, spacing: 20) {
        DMSegmentedControl("Time range", selection: $range, segments: [
            DMSegment("1h", "1 h"), DMSegment("6h", "6 h"), DMSegment("24h", "24 h"),
            DMSegment("7d", "7 days"), DMSegment("30d", "30 days"),
        ])
        DMSegmentedControl("Temperature unit", selection: $range, segments: [
            DMSegment("24h", "°C"), DMSegment("7d", "°F"),
        ], fillsWidth: true)
        FlowLayout {
            ForEach(["Gaming PC", "DGX Spark", "MacBook Pro", "Home Server"], id: \.self) { name in
                DeviceChip(name, isOnline: name != "Home Server", isSelected: name == device) { device = name }
            }
        }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.page)
    .preferredColorScheme(.dark)
}
