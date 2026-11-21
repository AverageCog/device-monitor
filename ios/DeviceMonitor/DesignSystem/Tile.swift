import SwiftUI

/// A summary tile of the History and Advanced views (`.tile`): uppercase label, big value, sub line.
struct Tile: View {
    private let label: String
    private let value: String
    private let sub: String?
    private let tickColor: Color?

    /// - Parameters:
    ///   - sub: The quieter line under the value, e.g. "peak · avg 18%".
    ///   - tickColor: History tiles carry a short line in their series colour before the label;
    ///     Advanced tiles have none.
    init(label: String, value: String, sub: String? = nil, tickColor: Color? = nil) {
        self.label = label
        self.value = value
        self.sub = sub
        self.tickColor = tickColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let tickColor {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tickColor)
                        .frame(width: 10, height: 2)
                }
                Text(label)
                    .dmFont(.statKey)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            Text(value)
                .dmFont(.tileValue)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let sub {
                Text(sub)
                    .dmFont(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Fill the grid cell so tiles in a row end up the same height.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Theme.Layout.tilePadding)
        .dmSurface(Theme.surface1, radius: Theme.Radius.tile)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue([value, sub].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Tiles in as many equal columns as fit (`.tiles`).
struct TileGrid<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Theme.Layout.tileMinWidth), spacing: Theme.Layout.tileSpacing, alignment: .top)],
            alignment: .leading,
            spacing: Theme.Layout.tileSpacing
        ) {
            content
        }
    }
}

#Preview("Tiles") {
    ScrollView {
        TileGrid {
            Tile(label: "CPU", value: "44%", sub: "peak · avg 18%", tickColor: Theme.cpu)
            Tile(label: "GPU", value: "98%", sub: "peak · avg 88%", tickColor: Theme.gpu)
            Tile(label: "Drawing now", value: "896 W", sub: "$6.80 a day at this rate")
            Tile(label: "Per month", value: "$186", sub: "≈ 588 kWh at the recent average")
        }
        .padding()
    }
    .background(Theme.page)
    .preferredColorScheme(.dark)
}
