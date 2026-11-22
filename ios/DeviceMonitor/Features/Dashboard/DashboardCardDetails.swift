import DMCore
import SwiftUI

/// What a card shows under Details (`detailHtml` and `aiHtml` in public/index.html), section by
/// section as `DeviceDetailsModel` lists them: loaded AI models, a block per GPU, drives,
/// temperature sensors, fans, and the hints.
struct DashboardCardDetails: View {
    let model: DeviceDetailsModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// At accessibility text sizes a line of a card does not hold a label and its value side by
    /// side: the design system's rows would cut the label short ("CPU Packa…") and leave out what
    /// kind of model a file is. There a row is its label over its value, both in full.
    private var stacksRows: Bool { dynamicTypeSize.isAccessibilitySize }

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
                        header(of: app)
                        if let placeholder = app.placeholder {
                            hint(placeholder)
                        } else if stacksRows {
                            VStack(spacing: DashboardStackedRow.spacing) {
                                ForEach(app.models) { model in
                                    DashboardStackedRow(label: model.name, annotation: model.kind, value: model.size)
                                }
                            }
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
                VStack(spacing: stacksRows ? DashboardStackedRow.spacing : Theme.Spacing.xs) {
                    ForEach(rows) { row in
                        // The dashboard names a sensor's hardware when the pointer rests on it.
                        if stacksRows {
                            DashboardStackedRow(label: row.label, value: row.value, spokenDetail: row.detail)
                        } else {
                            KeyValueRows([KeyValueItem(row.label, row.value)])
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel([row.label, row.detail].compactMap { $0 }.joined(separator: ", "))
                                .accessibilityValue(row.value)
                        }
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

    /// An app's line (`.ai-app`): its name, and the memory it holds at the end of the line or,
    /// where rows are stacked, under the name.
    @ViewBuilder
    private func header(of app: DeviceDetailsModel.AIApp) -> some View {
        let memory = app.memory.isEmpty ? nil : app.memory
        if stacksRows {
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .dmFont(.panelTitle)
                    .foregroundStyle(Theme.textPrimary)
                if let memory {
                    Text(memory)
                        .dmFont(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        } else {
            SubsectionHeader(app.name, detail: memory)
        }
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

/// A row of Details as its label over its value (`.kv`, where a line cannot hold the two): each
/// takes the lines it needs. VoiceOver reads it as the design system's row: the label, then the value.
private struct DashboardStackedRow: View {
    let label: String
    /// A quiet word after the label: what a model is used as ("unet").
    var annotation: String?
    let value: String
    /// What VoiceOver adds to the label and the screen does not show: the hardware a sensor is on.
    var spokenDetail: String?

    @ScaledMetric(relativeTo: .caption2) private var annotationSize: CGFloat = DMTextStyle.micro.size

    /// Between two rows: more than between a label and its value, so each pair reads as one.
    static let spacing = Theme.Spacing.s

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .dmFont(.callout)
            Text(value)
                .dmFont(.callout)
                .foregroundStyle(Theme.textPrimary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([label, annotation, spokenDetail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(value)
    }

    /// The label, then its annotation smaller and quieter, as the design system's rows set them.
    private var title: AttributedString {
        var text = AttributedString(label)
        text.swiftUI.foregroundColor = Theme.textSecondary
        if let annotation {
            var small = AttributedString(" " + annotation)
            small.swiftUI.foregroundColor = Theme.textMuted
            small.swiftUI.font = .system(size: annotationSize)
            text.append(small)
        }
        return text
    }
}
