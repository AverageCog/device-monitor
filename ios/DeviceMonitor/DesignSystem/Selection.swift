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
        HStack(spacing: 0) {
            ForEach(segments) { segment in
                let isOn = segment.value == selection
                Button {
                    selection = segment.value
                } label: {
                    Text(segment.label)
                        .dmFont(.callout)
                        .lineLimit(1)
                        .foregroundStyle(isOn ? Theme.textPrimary : Theme.textMuted)
                        .padding(.horizontal, 11)
                        .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: minHeight)
                        .background(isOn ? Theme.surface2 : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityIdentifier(identifier.map { "\($0)-\(segment.identifier ?? segment.label)" } ?? "")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: Theme.Layout.hairline)
        }
        .animation(.easeOut(duration: 0.15), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier ?? "")
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
