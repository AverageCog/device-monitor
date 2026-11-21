import DMCore
import Observation
import SwiftUI

/// Where the screen's inputs come from: the hub, through the store. DEBUG launch arguments and
/// previews replace parts of it to show states a healthy demo hub never gets into.
struct AdvancedInputs {
    /// `GET /api/energy` for these bucket edges.
    var energy: @MainActor (HubStore, [Double]) async throws -> EnergyResponse = { store, bounds in
        try await store.loadEnergy(bounds: bounds)
    }
    var devices: @MainActor (HubStore) -> [Device] = { $0.devices }
    /// function priceSettings: the saved price, or the guess for this device's time zone.
    var price: @MainActor (HubStore) -> EnergyPrice = { EnergyPrice(saved: $0.energySettings) }
}

/// The Advanced screen's state and its comings and goings with the hub: what `adv`, openAdvanced,
/// closeAdvanced, loadAdv and advLive are in public/index.html.
///
/// It asks the hub for the totals when the screen appears, when the range or the saved price
/// changes and every minute while the screen is showing; it drops answers to questions it no
/// longer asks; and it follows live reports at most once a second. Everything stops while the
/// screen is not showing.
///
/// What it publishes are the parts of `AdvancedModel`, each written only when it changed, so a
/// section of the screen is redrawn when its own figures move and not otherwise.
@Observable
final class AdvancedController {
    private(set) var range = AdvancedRange.default
    /// True until the hub's totals for `range` have arrived.
    private(set) var isLoading = true
    private(set) var tiles: [AdvancedModel.Tile]
    private(set) var price: AdvancedModel.PriceRow
    private(set) var chartTitle: String
    private(set) var legend: [AdvancedModel.LegendItem]
    private(set) var chart: AdvancedChartModel?
    private(set) var power: AdvancedModel.PowerTable
    private(set) var usage: AdvancedModel.UsageTable
    /// Why the last request for totals failed; nil once one succeeds.
    private(set) var failure: AdvancedLoadFailure?
    /// The user asked again and the answer is not in yet.
    private(set) var isRetrying = false

    @ObservationIgnored private var store: HubStore?
    @ObservationIgnored private var preferences: Preferences?
    @ObservationIgnored private var inputs = AdvancedInputs()
    /// `adv.data`: the hub's totals for `range`, nil while they are loading.
    @ObservationIgnored private var energy: EnergyResponse?
    /// `adv.seq`: names the newest question; an answer to an older one is dropped.
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var isSelected = true
    @ObservationIgnored private var isForeground = true
    /// `adv.timer`, and the request it makes.
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    /// `adv.live`.
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var throttle = AdvancedRefresh.LiveThrottle()
    /// Names the watch on the devices that is armed; one that fires under an older name is spent.
    @ObservationIgnored private var watch = 0

    /// Stands in until `attach`: the page with nothing loaded.
    private static let blank = AdvancedModel(
        devices: [], energy: nil, price: EnergyPrice(saved: nil), range: .default, unit: .celsius, now: 0)

    init() {
        let model = Self.blank
        tiles = model.tiles
        price = model.price
        chartTitle = model.chartTitle
        legend = model.legend
        chart = model.chart
        power = model.power
        usage = model.usage
    }

    /// Somebody is looking at the screen: `!$('#advView').hidden`.
    private var isActive: Bool { isVisible && isSelected && isForeground && store != nil }

    // MARK: Wiring

    /// Gives the controller its hub. Called each time the screen appears; only the first call for
    /// a store does anything.
    /// - Parameter range: opens on this range instead of the saved one, without saving it.
    func attach(store: HubStore, preferences: Preferences, inputs: AdvancedInputs = AdvancedInputs(), range: AdvancedRange? = nil) {
        guard self.store !== store else { return }
        self.store = store
        self.preferences = preferences
        self.inputs = inputs
        self.range = range ?? AdvancedRange(stored: preferences.advancedRange.rawValue)
        energy = nil
        failure = nil
        rebuild()
    }

    /// The screen appeared or disappeared.
    func setVisible(_ visible: Bool) {
        let was = isActive
        isVisible = visible
        activeChanged(from: was)
    }

    /// Another tab was chosen, or this one again. Said separately because a tab view may keep a
    /// tab it is not showing "appeared".
    func setSelected(_ selected: Bool) {
        let was = isActive
        isSelected = selected
        activeChanged(from: was)
    }

    /// The app came to the front or left it.
    func setForeground(_ foreground: Bool) {
        let was = isActive
        isForeground = foreground
        activeChanged(from: was)
    }

    // function openAdvanced / closeAdvanced
    private func activeChanged(from was: Bool) {
        guard isActive != was else { return }
        if isActive {
            rebuild()
            watchDevices()
            startLoading()
        } else {
            // Whatever is on its way would answer a screen nobody is looking at.
            sequence += 1
            watch += 1
            reloadTask?.cancel()
            reloadTask = nil
            liveTask?.cancel()
            liveTask = nil
            throttle.redrawn()
        }
    }

    // MARK: What the user does

    /// The #advRange buttons: `adv.data = null; renderAdv(); loadAdv();`
    func select(_ range: AdvancedRange) {
        guard range != self.range else { return }
        self.range = range
        if let stored = HistoryRange(rawValue: range.rawValue) { preferences?.advancedRange = stored }
        energy = nil
        failure = nil
        isRetrying = false
        sequence += 1
        rebuild()
        startLoading()
    }

    /// "Try again" on the failure banner.
    func retry() {
        guard isActive else { return }
        isRetrying = true
        startLoading()
    }

    /// Pull to refresh: asks now, and returns when the hub has answered.
    func refresh() async {
        await startLoading()?.value
    }

    // MARK: What changes around it

    /// The saved price changed: the hub works the costs out, so they have to be asked for again
    /// (`if (!$('#advView').hidden) loadAdv()`), unless the totals on show already carry this price.
    func priceChanged() {
        guard isActive, let store else { return }
        if energy == nil || energy?.settings != store.energySettings { startLoading() }
    }

    /// The temperature unit changed (`renderAdv()` in the unit toggle).
    func unitChanged() {
        guard isActive else { return }
        rebuild()
    }

    /// The live stream is back: what could not be loaded while it was away is asked for at once
    /// rather than at the next minute.
    func connectionRestored() {
        guard isActive, failure != nil || energy == nil else { return }
        startLoading()
    }

    // MARK: Loading

    /// `loadAdv(); adv.timer = setInterval(loadAdv, 60e3)`: asks now and every minute from now,
    /// in place of whatever was being asked. Returns the request it makes now.
    @discardableResult
    private func startLoading() -> Task<Void, Never>? {
        reloadTask?.cancel()
        reloadTask = nil
        guard isActive, let clock = store?.clock else { return nil }
        // A task of its own, so that whoever waits for the answer (pull to refresh) is not
        // waiting for the minutes after it.
        let first = Task { [weak self] in
            _ = await self?.load()
        }
        reloadTask = Task { [weak self] in
            await withTaskCancellationHandler {
                await first.value
            } onCancel: {
                first.cancel()
            }
            while !Task.isCancelled {
                do { try await clock.sleep(milliseconds: AdvancedRefresh.reloadInterval * 1000) } catch { return }
                guard let controller = self else { return }
                await controller.load()
            }
        }
        return first
    }

    // function loadAdv
    private func load() async {
        guard isActive, let store else { return }
        sequence += 1
        let ticket = sequence
        let bounds = range.requestBounds(now: store.clock.now)
        var answer: EnergyResponse?
        var problem: HubError?
        do {
            answer = try await inputs.energy(store, bounds)
        } catch {
            problem = HubError(error)
        }
        guard ticket == sequence else { return }
        if let answer {
            energy = answer
            failure = nil
        } else if let problem {
            // Cancelled with nothing newer asked: the task was, not the question. Ask again later.
            if problem.kind == .cancelled { return }
            failure = AdvancedLoadFailure(reason: problem.errorDescription ?? "", hasTotals: energy != nil)
        }
        isRetrying = false
        rebuild()
    }

    // MARK: Live figures

    /// Notices the next change to the devices without the screen having to read them.
    private func watchDevices() {
        guard isActive, let store else { return }
        watch += 1
        let armed = watch
        let devices = inputs.devices
        withObservationTracking {
            _ = devices(store)
        } onChange: { [weak self] in
            Task { @MainActor in self?.devicesChanged(armed) }
        }
    }

    // function advLive: 'now' figures follow reports, at most once a second.
    private func devicesChanged(_ armed: Int) {
        guard armed == watch, isActive, let store else { return }
        watchDevices()
        let now = store.clock.now
        guard let due = throttle.reportArrived(now: now) else { return }
        let clock = store.clock
        liveTask = Task { [weak self] in
            do { try await clock.sleep(milliseconds: due - now) } catch { return }
            self?.liveRedraw()
        }
    }

    private func liveRedraw() {
        throttle.redrawn()
        liveTask = nil
        guard isActive else { return }
        rebuild()
    }

    // MARK: The page

    // function renderAdv, minus the drawing: works the page out and publishes what changed.
    private func rebuild() {
        guard let store, let preferences else { return }
        let model = AdvancedModel(
            devices: inputs.devices(store), energy: energy, price: inputs.price(store), range: range,
            unit: preferences.temperatureUnit, now: store.clock.now)
        if isLoading != model.isLoading { isLoading = model.isLoading }
        if tiles != model.tiles { tiles = model.tiles }
        if price != model.price { price = model.price }
        if chartTitle != model.chartTitle { chartTitle = model.chartTitle }
        if legend != model.legend { legend = model.legend }
        if chart != model.chart { chart = model.chart }
        if power != model.power { power = model.power }
        if usage != model.usage { usage = model.usage }
    }
}
