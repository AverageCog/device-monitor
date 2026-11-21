import DMCore
import SwiftUI

/// What a card shows under Details (`detailHtml` and `aiHtml` in public/index.html), section by
/// section as `DeviceDetailsModel` lists them: loaded AI models, a block per GPU, drives,
/// temperature sensors, fans, and the hints.
struct DashboardCardDetails: View {
    let model: DeviceDetailsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.sections) { section in
                self.section(section)
            }
        }
    }

    @ViewBuilder
    private func section(_ section: DeviceDetailsModel.Section) -> some View {
        switch section.content {
        case .models(let apps, let emptyText):
            DMSection(section.title ?? "") {
                if let emptyText { hint(emptyText) }
                ForEach(apps) { app in
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        SubsectionHeader(app.name, detail: app.memory.isEmpty ? nil : app.memory)
                        if let placeholder = app.placeholder {
                            hint(placeholder)
                        } else {
                            KeyValueRows(app.models.map { KeyValueItem($0.name, $0.size, detail: $0.kind) }, style: .valueFirst)
                        }
                    }
                    // .ai-app { margin: 10px 0 4px }, less the section's own spacing.
                    .padding(.top, app.id == apps.first?.id ? 0 : 2)
                }
            }
        case .rows(let rows):
            DMSection(section.title ?? "") {
                VStack(spacing: Theme.Spacing.xs) {
                    ForEach(rows) { row in
                        KeyValueRows([KeyValueItem(row.label, row.value)])
                            // The dashboard names a sensor's hardware when the pointer rests on it.
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel([row.label, row.detail].compactMap { $0 }.joined(separator: ", "))
                            .accessibilityValue(row.value)
                    }
                }
            }
            // .gpu-block + .gpu-block { margin-top: 10px }
            .padding(.top, isFollowingGPU(section.kind) ? -4 : 0)
        case .drives(let drives):
            DMSection(section.title ?? "") {
                DashboardStats(stats: drives, columns: 1)
            }
        case .hint(let text, let emphasis):
            hint(text, emphasis: emphasis)
                .padding(.top, 14)
        }
    }

    private func isFollowingGPU(_ kind: DeviceDetailsModel.Kind) -> Bool {
        if case .gpu(let index) = kind { index > 0 } else { false }
    }

    /// A sentence in the muted hint style (`.hint`), with the part the dashboard sets in bold.
    private func hint(_ text: String, emphasis: String? = nil) -> some View {
        var styled = AttributedString(text)
        if let emphasis, let range = styled.range(of: emphasis) {
            styled[range].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(styled)
            .dmFont(.caption)
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
