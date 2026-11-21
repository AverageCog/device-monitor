import DMCore
import Observation
import SwiftUI

/// A stretch being marked on a chart (`hv.drag` in public/index.html): where the drag started,
/// where the finger is, and the width of the chart it is on, all in the dashboard's chart
/// coordinates (see `HistoryChartGeometry`).
nonisolated struct HistoryChartSelection: Equatable, Sendable {
    var x1: Double
    var x2: Double
    var chartWidth: Double

    /// The two ends as times on a chart showing `from`…`to`, so that every chart can mark the
    /// same stretch whatever its own width.
    func times(from: Double, to: Double) -> (start: Double, end: Double) {
        let layout = HistoryChartLayout(width: chartWidth, from: from, to: to)
        return (layout.time(atX: min(x1, x2)), layout.time(atX: max(x1, x2)))
    }
}

/// The state of the History tab: the `hv` object of public/index.html and the functions around it
/// (`openHistory`, `setHvWindow`, `loadHistory`, `attachHvEvents`).
///
/// Views read the properties they show and nothing else, so that a finger moving over a chart
/// only redraws the crosshairs, and a report arriving every two seconds redraws nothing here.
@Observable
final class HistoryController {
    typealias Loader = @MainActor (_ deviceID: String, _ request: HistoryRequest) async throws(HubError) -> HistoryResponse

    /// What the page has below its header.
    enum Content: Equatable {
        /// The hub knows no device to show.
        case noDevice
        /// The first answer for this device has not arrived.
        case loading
        case failed(String)
        /// The answer has no reading in the window (`HistoryModel.emptyText`).
        case empty(String)
        case charts
    }

    /// A request that takes longer than this is shown as in progress; a quick one changes nothing
    /// on screen until its answer is there.
    static let progressDelay: Duration = .milliseconds(350)
    /// How long the width must stand still before the hub is asked for that many points.
    static let widthSettleDelay: Duration = .milliseconds(120)
    /// Shown when a failure has no text of its own.
    static let failureFallback = "The hub could not be reached."

    // MARK: What the page is asked to show

    private(set) var deviceID: String?
    private(set) var window: HistoryWindow
    private(set) var unit: TemperatureUnit

    // MARK: What it shows

    /// The charts on screen. They stay while the next answer is on its way.
    private(set) var model: HistoryModel?
    /// The device `model` belongs to; while another one is being loaded it differs from `deviceID`.
    private(set) var shownDeviceID: String?
    private(set) var failure: String?
    private(set) var isLoading = false
    /// A request has been out for longer than `progressDelay`.
    private(set) var showsProgress = false
    /// Answers shown so far.
    private(set) var loadCount = 0

    // MARK: Pointing and selecting

    /// What every chart marks for the moment under the finger (`hv.hoverT`).
    private(set) var tooltip: HistoryTooltipModel?
    private(set) var selection: HistoryChartSelection?

    @ObservationIgnored private let store: HubStore
    @ObservationIgnored private let preferences: Preferences
    /// Asks the hub. A DEBUG launch argument can put something else here (`HistoryDebugOptions`).
    @ObservationIgnored var loader: Loader
    /// The answer `model` was made from, kept to draw it again in another unit.
    @ObservationIgnored private var response: HistoryResponse?
    /// The window `model` shows. Gestures on the charts are measured against it.
    @ObservationIgnored private var shownWindow: HistoryWindow?
    /// `hv.seq`: the newest request; an answer to an older one is dropped.
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var columnWidth: Double = 0
    @ObservationIgnored private var isWidthSettled = false
    @ObservationIgnored private var widthTask: Task<Void, Never>?
    /// A request held back until the width is known; true when it was only a refresh.
    @ObservationIgnored private var waitingReload: Bool?
    /// The points the newest request asked for.
    @ObservationIgnored private var requestedPoints: Int?
    @ObservationIgnored private var pointerTime: Double?
    @ObservationIgnored private var pinch: Pinch?
    /// A finger is resting on a chart; a pointer hovering over one does not count.
    @ObservationIgnored private var isHolding = false
    /// A refresh came due while a finger was on a chart; it runs when the finger lifts.
    @ObservationIgnored private var missedTick = false
    #if DEBUG
    /// The launch arguments this page was started with.
    @ObservationIgnored var debug = HistoryDebugOptions()
    #endif

    private struct Pinch {
        var center: Double
        var window: HistoryWindow
        var chartWidth: Double
    }

    init(store: HubStore, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
        unit = preferences.temperatureUnit
        // const hv = { range: store.get('hvRange') || '6h', … }
        window = HistoryWindow(range: HistoryPageRange.resolve(stored: preferences.historyRange.rawValue), now: store.clock.now)
        loader = { [store] (id: String, request: HistoryRequest) async throws(HubError) -> HistoryResponse in
            try await store.loadHistory(device: id, from: request.from, to: request.to, points: request.points)
        }
    }

    var content: Content {
        guard deviceID != nil else { return .noDevice }
        if let model { return model.emptyText.map(Content.empty) ?? .charts }
        if let failure { return .failed(failure) }
        return .loading
    }

    /// The charts on screen belong to another device than the heading, and its answer is slow.
    var isStale: Bool { showsProgress && model != nil && shownDeviceID != deviceID }

    /// A slow answer is on its way while older charts are still on screen. Without charts the
    /// page says that it is loading where they would be.
    var isReplacingCharts: Bool { showsProgress && model != nil }

    /// Whether a touch on the charts means anything: they show the selected device.
    private var acceptsGestures: Bool { model != nil && shownDeviceID == deviceID }

    /// A touch is in progress. The page is not refreshed under a finger.
    private var isInteracting: Bool { isHolding || selection != nil || pinch != nil }

    // MARK: - Choosing what to show

    /// `openHistory(id)`: another device starts with the whole range again.
    func select(device id: String?) {
        guard id != deviceID else { return }
        deviceID = id
        cancelInteraction()
        // if (changed || !hv.points.length) { hv.zoomed = false; setHvWindow(); }
        window.reset(now: store.clock.now)
        guard id != nil else {
            sequence += 1
            waitingReload = nil
            loadTask?.cancel()
            progressTask?.cancel()
            model = nil
            response = nil
            shownWindow = nil
            shownDeviceID = nil
            failure = nil
            isLoading = false
            showsProgress = false
            return
        }
        reload()
    }

    /// A range button: `hv.range = …; store.set('hvRange', hv.range); hv.zoomed = false; setHvWindow(); loadHistory()`.
    func select(range: HistoryPageRange) {
        cancelInteraction()
        window.select(range, now: store.clock.now)
        if let stored = HistoryRange(rawValue: range.rawValue) { preferences.historyRange = stored }
        reload()
    }

    /// The "Reset zoom" button.
    func resetZoom() {
        cancelInteraction()
        window.reset(now: store.clock.now)
        reload()
    }

    /// A double tap on a chart. True when it left a zoom.
    @discardableResult
    func resetZoomIfZoomed() -> Bool {
        guard window.resetIfZoomed(now: store.clock.now) else { return false }
        cancelInteraction()
        reload()
        return true
    }

    /// The unit toggle only draws again (`renderTiles(); drawHv();`): the readings are the same.
    func setUnit(_ unit: TemperatureUnit) {
        guard unit != self.unit else { return }
        self.unit = unit
        guard let response, let shownWindow else { return }
        model = HistoryModel(response: response, window: shownWindow, unit: unit)
        updateTooltip()
    }

    /// The width of the column the charts are in, which decides how many points to ask for.
    ///
    /// The first layout passes and a rotation report several widths in a row. Nothing is asked
    /// for until the width has stood still for a moment, so the hub is asked once, for the right one.
    func setColumnWidth(_ width: Double) {
        guard width != columnWidth else { return }
        columnWidth = width
        isWidthSettled = false
        widthTask?.cancel()
        guard width > 0 else { return }
        widthTask = Task { [weak self] in
            try? await Task.sleep(for: Self.widthSettleDelay)
            guard !Task.isCancelled, let self else { return }
            self.widthSettled()
        }
    }

    private func widthSettled() {
        isWidthSettled = true
        if let isRefresh = waitingReload {
            reload(isRefresh: isRefresh)
        } else if deviceID != nil, model == nil, failure == nil, !isLoading {
            reload()
        } else if model != nil, !window.isZoomed, let requestedPoints {
            // A page that became much wider or narrower (a rotation) deserves as many points as it
            // now has room for; the dashboard gets them with its next refresh.
            let points = HistoryWindow.points(forWidth: columnWidth)
            if abs(points - requestedPoints) * 5 > requestedPoints, window.refresh(now: store.clock.now) { reload(isRefresh: true) }
        }
    }

    func retry() {
        reload()
    }

    /// Pull to refresh: the window ends now again (a zoom stays where it is), and this returns
    /// when the hub has answered.
    func refresh() async {
        guard deviceID != nil else { return }
        cancelInteraction()
        window.refresh(now: store.clock.now)
        reload()
        await loadTask?.value
    }

    // MARK: - Keeping it current

    /// For as long as the page is on screen: loads, then moves the window to now every thirty
    /// seconds (`hv.timer`).
    func run() async {
        missedTick = false
        // The unit may have been changed in Settings while this tab was not on screen.
        #if DEBUG
        if debug.unit == nil { setUnit(preferences.temperatureUnit) }
        #else
        setUnit(preferences.temperatureUnit)
        #endif
        tick()
        while !Task.isCancelled {
            do {
                try await store.clock.sleep(milliseconds: HistoryWindow.refreshInterval)
            } catch {
                return
            }
            tick()
        }
    }

    /// `if (!hv.zoomed) { setHvWindow(); loadHistory(); }`, and a second try after a failure.
    func tick() {
        guard deviceID != nil else { return }
        if isInteracting {
            missedTick = true
            return
        }
        if failure != nil || (model == nil && !isLoading) {
            reload()
        } else if !isLoading, window.refresh(now: store.clock.now) {
            // A request that is still out is not asked again; it fails or answers by itself.
            reload(isRefresh: true)
        }
    }

    /// The page left the screen.
    func leave() {
        cancelInteraction()
        missedTick = false
    }

    private func reload(isRefresh: Bool = false) {
        guard let id = deviceID else { return }
        guard isWidthSettled else {
            // Asked once the width is known. A refresh does not weaken what the user asked for.
            waitingReload = (waitingReload ?? true) && isRefresh
            return
        }
        waitingReload = nil
        sequence += 1
        let token = sequence, window = window, loader = loader
        // const w = Math.min(1200, Math.max(200, Math.round(($('#hvCharts').clientWidth || 900))));
        let request = window.request(forWidth: columnWidth)
        requestedPoints = request.points
        loadTask?.cancel()
        progressTask?.cancel()
        isLoading = true
        if !isRefresh { failure = nil }
        progressTask = Task { [weak self] in
            try? await Task.sleep(for: Self.progressDelay)
            guard !Task.isCancelled, let self, token == self.sequence, self.isLoading else { return }
            self.showsProgress = true
        }
        loadTask = Task { [weak self] in
            let result: Result<HistoryResponse, HubError>
            do {
                result = .success(try await loader(id, request))
            } catch {
                result = .failure(HubError(error))
            }
            // if (seq !== hv.seq) return;
            guard let self, token == self.sequence else { return }
            self.finish(result, deviceID: id, window: window, isRefresh: isRefresh)
        }
    }

    private func finish(_ result: Result<HistoryResponse, HubError>, deviceID id: String, window: HistoryWindow, isRefresh: Bool) {
        progressTask?.cancel()
        isLoading = false
        showsProgress = false
        switch result {
        case .success(let response):
            self.response = response
            shownWindow = window
            shownDeviceID = id
            failure = nil
            model = HistoryModel(response: response, window: window, unit: unit)
            loadCount += 1
        case .failure(let error):
            if error.kind == .cancelled { return }
            // A refresh that fails leaves the charts alone; the next one tries again. Anything the
            // user asked for must not be answered with the charts of something else.
            if isRefresh, model != nil, shownDeviceID == id { return }
            response = nil
            shownWindow = nil
            shownDeviceID = nil
            model = nil
            failure = error.errorDescription ?? Self.failureFallback
        }
        updateTooltip()
    }

    // MARK: - Pointing at a moment

    /// A finger rests at `x` on a chart `chartWidth` wide, or a pointer hovers there (`holding`
    /// false): every chart marks that moment.
    func point(at x: Double, chartWidth: Double, holding: Bool = true) {
        guard acceptsGestures, let layout = layout(chartWidth) else { return }
        // hv.hoverT = hvT(x, c.clientWidth);
        pointerTime = layout.time(atX: x)
        if holding { isHolding = true }
        updateTooltip()
    }

    func endPointing() {
        guard pointerTime != nil || isHolding else { return }
        pointerTime = nil
        isHolding = false
        updateTooltip()
        interactionEnded()
    }

    private func layout(_ chartWidth: Double) -> HistoryChartLayout? {
        guard let model, chartWidth > HistoryChartLayout.padding.left + HistoryChartLayout.padding.right else { return nil }
        return HistoryChartLayout(width: chartWidth, from: model.from, to: model.to)
    }

    private func updateTooltip() {
        let next = pointerTime.flatMap { model?.tooltip(at: $0) }
        if next != tooltip { tooltip = next }
    }

    // MARK: - Dragging across a chart

    /// A sideways drag began at `start` and has reached `x` (`pointerdown`, then `pointermove`).
    func beginSelection(from start: Double, to x: Double, chartWidth: Double) {
        guard acceptsGestures else { return }
        selection = HistoryChartSelection(x1: start, x2: x, chartWidth: chartWidth)
        point(at: x, chartWidth: chartWidth)
    }

    func moveSelection(to x: Double) {
        guard var current = selection else { return }
        current.x2 = x
        selection = current
        point(at: x, chartWidth: current.chartWidth)
    }

    /// The finger lifted (`pointerup`). True when the page zoomed into the stretch.
    @discardableResult
    func endSelection(commit: Bool) -> Bool {
        let ended = selection
        selection = nil
        pointerTime = nil
        isHolding = false
        updateTooltip()
        defer { interactionEnded() }
        // A range chosen meanwhile wins over a drag across the charts it is about to replace.
        guard commit, let ended, let shownWindow, shownWindow.range == window.range,
              let zoomed = shownWindow.zoomed(byDragFrom: ended.x1, to: ended.x2, chartWidth: ended.chartWidth) else { return false }
        window = zoomed
        reload()
        return true
    }

    // MARK: - Pinching

    /// Two fingers came down around `x`. Spreading them marks the stretch that will fill the
    /// charts; the hub is asked for it when they lift.
    func beginPinch(at x: Double, chartWidth: Double) {
        guard acceptsGestures, let shownWindow, let layout = layout(chartWidth) else { return }
        cancelInteraction()
        let center = min(shownWindow.to, max(shownWindow.from, layout.time(atX: x)))
        pinch = Pinch(center: center, window: shownWindow, chartWidth: chartWidth)
    }

    func movePinch(scale: Double) {
        guard let pinch, let layout = layout(pinch.chartWidth), let stretch = Self.stretch(of: pinch, scale: scale) else {
            if selection != nil { selection = nil }
            return
        }
        selection = HistoryChartSelection(x1: layout.x(stretch.from), x2: layout.x(stretch.to), chartWidth: pinch.chartWidth)
    }

    /// True when the page zoomed in, or back out to the whole range.
    @discardableResult
    func endPinch(scale: Double, commit: Bool) -> Bool {
        let ended = pinch
        pinch = nil
        selection = nil
        defer { interactionEnded() }
        guard commit, let ended, ended.window.range == window.range else { return false }
        if let stretch = Self.stretch(of: ended, scale: scale), let zoomed = ended.window.zoomed(to: stretch.from, stretch.to) {
            window = zoomed
            reload()
            return true
        }
        // Pinching in cannot show more than the range, so it goes back to all of it.
        if scale.isFinite, scale < 0.8, window.isZoomed {
            window.reset(now: store.clock.now)
            reload()
            return true
        }
        return false
    }

    /// The part of the window that fills it after spreading the fingers by `scale`, keeping the
    /// moment between them where it is. nil unless the fingers moved apart.
    private static func stretch(of pinch: Pinch, scale: Double) -> (from: Double, to: Double)? {
        guard scale.isFinite, scale > 1.05 else { return nil }
        return (pinch.center - (pinch.center - pinch.window.from) / scale, pinch.center + (pinch.window.to - pinch.center) / scale)
    }

    private func cancelInteraction() {
        pinch = nil
        isHolding = false
        if selection != nil { selection = nil }
        if pointerTime != nil {
            pointerTime = nil
            updateTooltip()
        }
    }

    private func interactionEnded() {
        guard missedTick, !isInteracting else { return }
        missedTick = false
        tick()
    }

    // MARK: - VoiceOver

    /// Moves the marked moment a step later or earlier, for a chart that is adjusted rather than
    /// touched. It starts at the newest reading, and stays at its moment through a refresh.
    func step(_ direction: AccessibilityAdjustmentDirection) {
        guard acceptsGestures, let points = model?.points, !points.isEmpty else { return }
        let stride = max(1, points.count / 60)
        let last = points.count - 1
        let current = pointerTime.flatMap { time in
            points.indices.min { abs(points[$0].t - time) < abs(points[$1].t - time) }
        } ?? last
        let next: Int
        switch direction {
        case .increment: next = min(last, current + stride)
        case .decrement: next = max(0, current - stride)
        @unknown default: next = current
        }
        pointerTime = points[next].t
        updateTooltip()
    }

    /// What a chart says about itself: the readings at the marked moment, or the newest ones.
    func spokenValue(for chart: HistoryChartModel) -> String {
        guard let model else { return "" }
        let shown = tooltip ?? model.points.last.flatMap { model.tooltip(at: $0.t) }
        guard let shown else { return chart.series.map(\.label).joined(separator: ", ") }
        let rows = shown.rows(for: chart.kind).map(\.text)
        return ([shown.title] + (rows.isEmpty ? ["no reading"] : rows)).joined(separator: ", ")
    }

    /// Halves the window around the marked moment, or around its middle.
    func zoomInForAccessibility() {
        guard acceptsGestures, let shownWindow else { return }
        let center = min(shownWindow.to, max(shownWindow.from, tooltip?.t ?? (shownWindow.from + shownWindow.to) / 2))
        let half = shownWindow.span / 4
        let from = min(max(shownWindow.from, center - half), shownWindow.to - 2 * half)
        guard let zoomed = shownWindow.zoomed(to: from, from + 2 * half) else { return }
        cancelInteraction()
        window = zoomed
        reload()
    }
}

#if DEBUG
extension HistoryController {
    /// `-dm-history-range` and `-dm-history-unit`: for this launch only, nothing is stored.
    func debugOverride(range: HistoryPageRange?, unit: TemperatureUnit?) {
        if let range { window = HistoryWindow(range: range, now: store.clock.now) }
        if let unit { setUnit(unit) }
    }
}
#endif
