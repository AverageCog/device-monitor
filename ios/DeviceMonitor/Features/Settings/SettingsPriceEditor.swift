import DMCore
import SwiftUI

/// The electricity price editor (the "Electricity price" row of the dashboard's settings dialog:
/// renderPriceRow, renderTou, saveTou and setPriceMode in public/index.html). The Settings tab
/// shows it under "Advanced settings" and `ElectricityPriceSheet` shows it on its own; both are
/// this view over DMCore's `PriceEditor`.
///
/// Every accepted change is saved on the hub at once, as on the dashboard. A rate field is
/// committed when the keyboard leaves it.
struct SettingsPriceEditor: View {
    nonisolated enum Placement: Sendable {
        /// Inside the Settings tab: the title is part of the editor.
        case settings
        /// In `ElectricityPriceSheet`: the navigation bar carries the title.
        case sheet

        /// Prefix of the accessibility identifiers, so the two never share one.
        var identifier: String {
            switch self {
            case .settings: "settings-price"
            case .sheet: "price"
            }
        }
    }

    let placement: Placement

    @Environment(HubStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = SettingsPriceEditorModel(script: SettingsLaunch.price)
    /// What the rate fields show while they are being typed in; the editor hears of a field when
    /// the keyboard leaves it.
    @State private var drafts: [SettingsPriceField: String] = [:]
    /// The fields typed in since the editor last heard of them.
    @State private var edited: Set<SettingsPriceField> = []
    @State private var showsRegions = false
    @State private var width: CGFloat = 0
    @FocusState private var focused: SettingsPriceField?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            header
            switch model.phase {
            case .loading:
                loading
            case .failed(let text):
                BannerView(text, kind: .critical, actionTitle: PriceEditorNotes.retry) {
                    Task { await model.load() }
                }
                .accessibilityIdentifier("\(placement.identifier)-load-error")
            case .ready:
                controls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task { await model.start(store: store) }
        .onChange(of: store.energySettings) { model.hubChanged() }
        .onChange(of: store.isEnergySettingsLoaded) { model.hubChanged() }
        .onChange(of: model.revision, initial: true) { refillDrafts() }
        .onChange(of: focused) { old, new in
            model.focus = Self.editorFocus(new)
            // The dashboard saves on `change`: when the field is left.
            if let old { commit(old) }
        }
        // Closing the sheet or leaving the tab leaves the field too.
        .onDisappear {
            for field in Array(edited) { commit(field) }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.editor.mode)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.editor.periods.count)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.saveFailure)
        .onChange(of: invalidCount) { old, new in
            if new > old { AccessibilityNotification.Announcement(PriceEditorNotes.invalidPeriods).post() }
        }
        .sensoryFeedback(.error, trigger: model.failures)
        .navigationDestination(isPresented: $showsRegions) {
            SettingsPriceRegionList(selection: model.editor.regionCode, isGuess: model.editor.price.guessed) { code in
                model.perform { editor, _ in editor.chooseRegion(code) }
            }
        }
        .toolbar {
            // Only the editor that has the keyboard adds to its bar: Settings and the sheet can
            // both be alive, and a decimal pad has no key of its own to put it away.
            if focused != nil {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(PriceEditorNotes.done) { focused = nil }
                        .accessibilityIdentifier("\(placement.identifier)-keyboard-done")
                }
            }
        }
        .task {
            // DEBUG launch argument only, and only the first time the editor appears.
            if model.takeOpensRegions() { showsRegions = true }
        }
    }

    // MARK: Title and hint

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                if placement == .settings {
                    Text(PriceEditor.Labels.title)
                        .dmFont(.rowTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                }
                Text(model.phase == .ready ? model.editor.hint : PriceEditorNotes.shared)
                    .dmFont(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(placement.identifier)-hint")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Always laid out, so the hint does not rewrap when a save starts or ends; shown only
            // for a save that takes long enough to wonder about.
            ProgressView()
                .controlSize(.small)
                .tint(Theme.textSecondary)
                .opacity(model.isSaving ? 1 : 0)
                .animation(model.isSaving ? .easeIn(duration: 0.15).delay(0.4) : nil, value: model.isSaving)
                .accessibilityHidden(true)
        }
    }

    private var loading: some View {
        HStack(spacing: Theme.Spacing.m) {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.textSecondary)
            Text(PriceEditorNotes.loading)
                .dmFont(.callout)
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: SettingsPriceMetrics.controlHeight)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(placement.identifier)-loading")
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        let editor = model.editor
        modeAndCurrency(editor)
        if editor.mode == .flat {
            flat(editor)
        } else {
            timeOfUse(editor)
        }
        if let failure = model.saveFailure {
            BannerView(failure, kind: .critical, actionTitle: PriceEditorNotes.retry) { model.retry() }
                .accessibilityIdentifier("\(placement.identifier)-save-error")
        }
    }

    // <div class="price-ctl">: the mode buttons and the currency picker.
    private func modeAndCurrency(_ editor: PriceEditor) -> some View {
        let mode = Binding<PriceEditor.Mode>(
            get: { model.editor.mode },
            set: { mode in act { editor, _ in editor.setMode(mode) } }
        )
        let currency = Binding<String>(
            get: { model.editor.currency },
            set: { code in
                // Choosing what is already chosen changes nothing, as in a browser's picker.
                guard code != model.editor.currency else { return }
                act { editor, _ in editor.chooseCurrency(code) }
            }
        )
        let segments = DMSegmentedControl(
            PriceEditor.Labels.title, selection: mode,
            segments: [
                DMSegment(.flat, PriceEditor.Mode.flat.label, identifier: "flat"),
                DMSegment(.timeOfUse, PriceEditor.Mode.timeOfUse.label, identifier: "time-of-use"),
            ],
            identifier: "\(placement.identifier)-mode"
        )
        let picker = Menu {
            Picker(PriceEditor.Labels.currency, selection: currency) {
                ForEach(editor.currencyOptions, id: \.self) { code in
                    Text(code).tag(code)
                }
            }
        } label: {
            SettingsPricePickerLabel(editor.currency, systemImage: "chevron.up.chevron.down", size: .compact)
                .fixedSize()
        }
        .accessibilityLabel(PriceEditor.Labels.currency)
        .accessibilityValue(editor.currency)
        .accessibilityIdentifier("\(placement.identifier)-currency")
        // Neither holds a text field, so picking the arrangement that fits is safe here.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.s) {
                segments
                Spacer(minLength: 0)
                picker
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                segments
                picker
            }
        }
        .sensoryFeedback(.selection, trigger: editor.mode)
    }

    // <div id="setFlat">: where you live, and the price per kWh.
    @ViewBuilder
    private func flat(_ editor: PriceEditor) -> some View {
        Button {
            commitFocused()
            showsRegions = true
        } label: {
            SettingsPricePickerLabel(PriceEditorNotes.regionLabel(for: editor.regionCode), systemImage: "chevron.right")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PriceEditor.Labels.region)
        .accessibilityValue(PriceEditorNotes.regionLabel(for: editor.regionCode))
        .accessibilityIdentifier("\(placement.identifier)-region")
        rateField(.flatRate, label: PriceEditor.Labels.rate, isInvalid: false, identifier: "\(placement.identifier)-rate-field")
    }

    // <div id="setTouBox">: a row per period, the rate of every other hour, and the add button.
    @ViewBuilder
    private func timeOfUse(_ editor: PriceEditor) -> some View {
        let layout = SettingsPriceMetrics.Arrangement(width: width, metrics: metrics)
        VStack(alignment: .leading, spacing: 0) {
            // By position: the editor gives rows new ids whenever it rebuilds them from the hub's
            // answer, and a row that only got a new id should not blink.
            ForEach(Array(editor.periods.enumerated()), id: \.offset) { index, period in
                periodRow(period, at: index, in: editor, layout: layout)
                    .padding(.vertical, Theme.Spacing.s)
                Hairline()
            }
            baseRow(editor, layout: layout)
                .padding(.vertical, Theme.Spacing.s)
        }
        if invalidCount > 0 {
            Text(PriceEditorNotes.invalidPeriods)
                .dmFont(.caption)
                .foregroundStyle(Theme.dangerText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(placement.identifier)-invalid")
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.m) {
                addButton(editor)
                if !editor.canAddPeriod { limitNote }
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                addButton(editor)
                if !editor.canAddPeriod { limitNote }
            }
        }
    }

    private func addButton(_ editor: PriceEditor) -> some View {
        Button(PriceEditor.Labels.addPeriod) {
            act { editor, _ in editor.addPeriod() }
        }
        .buttonStyle(.dm())
        .disabled(!editor.canAddPeriod)
        .accessibilityIdentifier("\(placement.identifier)-add-period-button")
    }

    private var limitNote: some View {
        Text(PriceEditorNotes.periodLimit)
            .dmFont(.caption)
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func periodRow(_ period: PriceEditor.Period, at index: Int, in editor: PriceEditor, layout: SettingsPriceMetrics.Arrangement) -> some View {
        let span = PriceEditorNotes.span(of: period)
        let prefix = "\(placement.identifier)-period-\(index)"
        let from = hourMenu(
            PriceEditor.Labels.from, hour: period.from, options: editor.startHourOptions(for: period), isInvalid: period.isInvalid,
            fills: layout == .stacked, identifier: "\(prefix)-from"
        ) { hour in
            change(period) { editor, index in editor.setPeriodStart(at: index, hour: hour) }
        }
        let to = hourMenu(
            PriceEditor.Labels.until, hour: period.to, options: editor.endHourOptions(for: period), isInvalid: period.isInvalid,
            fills: layout == .stacked, identifier: "\(prefix)-to"
        ) { hour in
            change(period) { editor, index in editor.setPeriodEnd(at: index, hour: hour) }
        }
        let word = Text(PriceEditor.Labels.to)
            .dmFont(.caption)
            .foregroundStyle(Theme.textMuted)
            .frame(width: metrics.word)
            .accessibilityHidden(true)
        let rate = rateField(
            .period(period.id), label: "\(PriceEditor.Labels.rate), \(span)", isInvalid: period.isInvalid, identifier: "\(prefix)-rate-field")
        let remove = Button {
            change(period) { editor, index in editor.removePeriod(at: index) }
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.dmIcon)
        .accessibilityLabel(PriceEditorNotes.removeLabel(for: period))
        .accessibilityIdentifier("\(prefix)-remove")

        switch layout {
        case .wide:
            // .tou { grid-template-columns: repeat(3, max-content) 84px repeat(2, max-content) }
            HStack(spacing: SettingsPriceMetrics.gap) {
                from
                word
                to
                rate
                Spacer(minLength: 0)
                remove
            }
        case .compact:
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(spacing: SettingsPriceMetrics.gap) {
                    from
                    word
                    to
                    Spacer(minLength: 0)
                    remove
                }
                rate
            }
        case .stacked:
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(spacing: SettingsPriceMetrics.gap) {
                    from
                    remove
                }
                HStack(spacing: SettingsPriceMetrics.gap) {
                    word
                    to
                }
                rate
            }
        }
    }

    // <span class="tou-other">All other hours</span> and its rate.
    @ViewBuilder
    private func baseRow(_ editor: PriceEditor, layout: SettingsPriceMetrics.Arrangement) -> some View {
        let label = Text(PriceEditor.Labels.otherHours)
            .dmFont(.callout)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
        let rate = rateField(
            .baseRate, label: PriceEditor.Labels.baseRate, isInvalid: editor.baseRateIsInvalid, identifier: "\(placement.identifier)-base-rate-field")
        switch layout {
        case .wide:
            HStack(spacing: SettingsPriceMetrics.gap) {
                // As wide as a period's two hours, so the rates line up in a column.
                label.frame(width: metrics.hours, alignment: .leading)
                rate
                Spacer(minLength: 0)
            }
        case .compact, .stacked:
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                label
                rate
            }
        }
    }

    // MARK: Fields

    private func rateField(_ field: SettingsPriceField, label: String, isInvalid: Bool, identifier: String) -> some View {
        HStack(spacing: SettingsPriceMetrics.gap) {
            TextField("0", text: draft(field))
                .textFieldStyle(.plain)
                .keyboardType(.decimalPad)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .focused($focused, equals: field)
                .onSubmit { focused = nil }
                .frame(minHeight: SettingsPriceMetrics.controlHeight)
                .dmField(isInvalid: isInvalid)
                .monospacedDigit()
                // Its full width while there is room; at the very largest text sizes it gives way
                // to "per kWh" rather than push the editor past the card's edge.
                .frame(maxWidth: metrics.field)
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
            Text(PriceEditor.Labels.perKwh)
                .dmFont(.caption)
                .foregroundStyle(Theme.textMuted)
                .fixedSize()
                .accessibilityHidden(true)
        }
    }

    private func hourMenu(
        _ title: String, hour: Double, options: [PriceEditor.HourOption], isInvalid: Bool, fills: Bool, identifier: String,
        choose: @escaping (Double) -> Void
    ) -> some View {
        let selection = Binding<Double>(get: { hour }, set: { if $0 != hour { choose($0) } })
        return Menu {
            Picker(title, selection: selection) {
                ForEach(options) { option in
                    Text(option.label).tag(option.hour)
                }
            }
        } label: {
            SettingsPricePickerLabel(PriceEditor.hourLabel(hour), systemImage: "chevron.up.chevron.down", isInvalid: isInvalid)
                // Narrower on a small phone rather than pushing the row past the card's edge.
                .frame(minWidth: metrics.hour * 0.8, idealWidth: metrics.hour, maxWidth: fills ? .infinity : metrics.hour)
        }
        .accessibilityLabel(title)
        .accessibilityValue(PriceEditor.hourLabel(hour))
        .accessibilityIdentifier(identifier)
    }

    private func draft(_ field: SettingsPriceField) -> Binding<String> {
        Binding(
            get: { drafts[field] ?? field.text(in: model.editor) ?? "" },
            set: { text in
                guard text != drafts[field] else { return }
                drafts[field] = text
                edited.insert(field)
            }
        )
    }

    // MARK: Changes

    @ScaledMetric(relativeTo: .body) private var fieldWidth: CGFloat = 96
    @ScaledMetric(relativeTo: .body) private var hourWidth: CGFloat = 118
    @ScaledMetric(relativeTo: .footnote) private var wordWidth: CGFloat = 18
    @ScaledMetric(relativeTo: .footnote) private var unitWidth: CGFloat = 50

    private var metrics: SettingsPriceMetrics {
        SettingsPriceMetrics(field: fieldWidth, hour: hourWidth, word: wordWidth, unit: unitWidth)
    }

    private var invalidCount: Int {
        model.editor.periods.filter(\.isInvalid).count + (model.editor.baseRateIsInvalid ? 1 : 0)
    }

    private static func editorFocus(_ field: SettingsPriceField?) -> PriceEditor.Focus {
        switch field {
        case nil: .none
        case .flatRate: .flatRate
        case .baseRate, .period: .timeOfUse
        }
    }

    /// A change made with a control that is not a text field. In a browser the click takes the
    /// focus, so a field being typed in is committed first; the same here.
    private func act(_ action: @escaping @MainActor (inout PriceEditor, PriceEditor.Focus) -> EnergySettings?) {
        commitFocused()
        model.perform(action)
    }

    /// A change to one period. It is found again when its turn comes: by its id, or, if the
    /// rows were rebuilt from the hub's answer meanwhile, by its hours.
    private func change(_ period: PriceEditor.Period, _ action: @escaping @MainActor (inout PriceEditor, Int) -> EnergySettings?) {
        act { editor, _ in
            guard let index = Self.index(of: period, in: editor) else { return nil }
            return action(&editor, index)
        }
    }

    private static func index(of period: PriceEditor.Period, in editor: PriceEditor) -> Int? {
        editor.periods.firstIndex { $0.id == period.id } ?? editor.periods.firstIndex { $0.from == period.from && $0.to == period.to }
    }

    private func commitFocused() {
        if let focused { commit(focused) }
    }

    /// Hands a field's text to the editor if it was typed in. A browser fires `change` only then:
    /// a field that was merely visited sends nothing, even when the hub's price moved meanwhile.
    private func commit(_ field: SettingsPriceField) {
        guard edited.remove(field) != nil, let text = drafts[field] else {
            // Left alone while the keyboard was in it; now it shows the hub's rate again.
            if field == .flatRate, focused != .flatRate { model.settle() }
            return
        }
        switch field {
        case .flatRate:
            model.perform { editor, focus in editor.setRate(text, focus: focus) }
        case .baseRate:
            model.perform { editor, _ in editor.setBaseRate(text) }
        case .period(let id):
            guard let period = model.editor.periods.first(where: { $0.id == id }) else { return }
            model.perform { editor, _ in
                guard let index = Self.index(of: period, in: editor) else { return nil }
                return editor.setPeriodRate(at: index, text: text)
            }
        }
    }

    /// Fields show what the editor has, except the one being typed in.
    private func refillDrafts() {
        let editor = model.editor
        var texts: [SettingsPriceField: String] = [.flatRate: editor.rateText, .baseRate: editor.baseRateText]
        for period in editor.periods { texts[.period(period.id)] = period.rateText }
        if let focused, edited.contains(focused), texts[focused] != nil, let typed = drafts[focused] { texts[focused] = typed }
        if texts != drafts { drafts = texts }
        edited.formIntersection(texts.keys)
    }
}

/// A rate field of the editor.
nonisolated enum SettingsPriceField: Hashable, Sendable {
    case flatRate
    case baseRate
    /// `PriceEditor.Period.id`.
    case period(Int)

    /// What the editor holds for the field; nil for a period that is gone.
    func text(in editor: PriceEditor) -> String? {
        switch self {
        case .flatRate: editor.rateText
        case .baseRate: editor.baseRateText
        case .period(let id): editor.periods.first { $0.id == id }?.rateText
        }
    }
}

/// The sizes the time-of-use rows are built from. They grow with the text size, and the rows are
/// arranged by what fits the width the editor has: one arrangement for all rows, decided from
/// numbers rather than by trying (a row holds a text field, which must not exist twice).
nonisolated struct SettingsPriceMetrics: Equatable, Sendable {
    /// Height of every control of the editor: a comfortable touch target.
    static let controlHeight: CGFloat = 44
    static let gap: CGFloat = 6
    /// Width of the remove button's plate.
    static let remove: CGFloat = 34

    /// Width of a rate field (the dashboard's 84 px).
    var field: CGFloat
    /// Width of an hour picker: fits "midnight".
    var hour: CGFloat
    /// Width of the word "to".
    var word: CGFloat
    /// About the width of "per kWh".
    var unit: CGFloat

    /// From, "to" and until, side by side.
    var hours: CGFloat { hour * 2 + word + Self.gap * 2 }

    enum Arrangement: Equatable, Sendable {
        /// Everything on one line, as on the dashboard.
        case wide
        /// The hours on one line, the rate under them.
        case compact
        /// One control per line, for the largest text sizes.
        case stacked

        init(width: CGFloat, metrics: SettingsPriceMetrics) {
            let rate = metrics.field + SettingsPriceMetrics.gap + metrics.unit
            if width <= 0 {
                // Not measured yet.
                self = .compact
            } else if width >= metrics.hours + SettingsPriceMetrics.gap + rate + SettingsPriceMetrics.gap + SettingsPriceMetrics.remove {
                self = .wide
            // The pickers may give up a fifth of their width before the row is taken apart.
            } else if width >= metrics.hour * 1.6 + metrics.word + SettingsPriceMetrics.gap * 3 + SettingsPriceMetrics.remove {
                self = .compact
            } else {
                self = .stacked
            }
        }
    }
}

/// The face of a picker in the editor, in the look of the dashboard's `select`: the choice and a
/// small glyph on a surface-2 field.
struct SettingsPricePickerLabel: View {
    nonisolated enum Size: Sendable {
        /// As tall as a rate field.
        case field
        /// A plate as tall as the mode buttons it sits beside, in a full-height touch target.
        case compact
    }

    private let text: String
    private let systemImage: String
    private let isInvalid: Bool
    private let size: Size

    /// The height of `DMSegmentedControl`.
    @ScaledMetric(relativeTo: .callout) private var compactHeight: CGFloat = 32

    init(_ text: String, systemImage: String, isInvalid: Bool = false, size: Size = .field) {
        self.text = text
        self.systemImage = systemImage
        self.isInvalid = isInvalid
        self.size = size
    }

    var body: some View {
        let label = HStack(spacing: Theme.Spacing.s) {
            Text(text)
                .lineLimit(1)
                // "midnight" on a narrow phone shrinks a little before it is cut short.
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .accessibilityHidden(true)
        }
        switch size {
        case .field:
            label
                .frame(minHeight: SettingsPriceMetrics.controlHeight)
                .dmField(isInvalid: isInvalid)
                .monospacedDigit()
                .contentShape(Rectangle())
        case .compact:
            label
                .dmFont(.callout)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 11)
                .frame(minHeight: compactHeight)
                .dmSurface(Theme.surface2, radius: Theme.Radius.control, border: isInvalid ? Theme.critical : Theme.border)
                .frame(minHeight: SettingsPriceMetrics.controlHeight)
                .contentShape(Rectangle())
        }
    }
}

#Preview("Price editor") {
    NavigationStack {
        ScrollView {
            SettingsPriceEditor(placement: .settings)
                .padding(Theme.Spacing.l)
                .dmSurface()
                .padding()
        }
        .dmScreen()
    }
    .demoEnvironment()
}
