import DMCore
import SwiftUI

/// "Where you live": the dashboard's region picker (`#setRegion`, its three groups and "Somewhere
/// else") as a searchable list, each place with the typical rate that choosing it brings.
struct SettingsPriceRegionList: View {
    /// A `PriceRegion.code` or `PriceRegions.customCode`.
    let selection: String
    /// Nothing is saved on the hub yet: `selection` is what the app assumes.
    var isGuess = false
    let choose: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        let groups = PriceEditorNotes.regionGroups(matching: query)
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.regions) { region in
                        row(region.name, detail: PriceEditorNotes.typicalRate(of: region), code: region.code)
                    }
                } header: {
                    Text(group.title)
                }
            }
            Section {
                row(PriceRegions.customName, detail: nil, code: PriceRegions.customCode)
            } footer: {
                if groups.isEmpty {
                    Text(PriceEditorNotes.noRegionFound)
                        .accessibilityIdentifier("price-region-none")
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: PriceEditorNotes.searchRegions)
        .navigationTitle(PriceEditor.Labels.region)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen-price-regions")
        .dmScreen()
    }

    private func row(_ name: String, detail: String?, code: String) -> some View {
        let isSelected = code == selection
        return Button {
            // The place already saved stays as it is, with the rate it has. One that is only
            // the app's guess is saved by choosing it.
            if !isSelected || isGuess { choose(code) }
            dismiss()
        } label: {
            HStack(spacing: Theme.Spacing.m) {
                Text(name)
                    .dmFont(.body)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: Theme.Spacing.s)
                if let detail {
                    Text(detail)
                        .dmFont(.callout)
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.surface1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("price-region-\(code)")
    }
}

#Preview("Regions") {
    NavigationStack {
        SettingsPriceRegionList(selection: "US-CA") { _ in }
    }
}
