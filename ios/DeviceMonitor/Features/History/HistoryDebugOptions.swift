#if DEBUG
import DMCore
import SwiftUI

/// Launch arguments of the History tab, for looking at states that need a finger or a failing hub
/// where nothing can tap, drag or scroll. DEBUG builds only; a release build has none of this.
/// Combine them with `-dm-demo -dm-tab history` or `-dm-demo -dm-history <device id>`.
///
///     -dm-history-range <1h|6h|24h|7d|30d>   open with that range
///     -dm-history-unit <C|F>                 show temperatures in that unit
///     -dm-history-scroll <tiles|utilization|temperature|gpuPower|network|diskIO|hint>
///                                            scroll that part of the page to the top once loaded
///     -dm-history-inspect <0…1>              a finger resting at that fraction of the plot's width:
///                                            crosshair and tooltip on every chart
///     -dm-history-select <a,b>               a drag in progress between those fractions
///     -dm-history-zoom <a,b>                 zoomed into that part of the window, as after that drag
///     -dm-history-state <loading|empty|error|no-devices|reloading|switching>
///                                            loading: the hub never answers;
///                                            empty: it answers with no points;
///                                            error: the first request fails, later ones work ("Try again");
///                                            no-devices: as if the hub knew no device;
///                                            reloading: the first answer arrives, a reload never does
///                                            (the charts stay, the header shows progress);
///                                            switching: the same, with the next device selected
///                                            (its name over the faded charts of the first)
///
/// Nothing here is stored: the range and the unit apply to this launch only, and the hub is not
/// told anything. `-dm-history-zoom` goes through the same code as a real drag.
nonisolated struct HistoryDebugOptions: Sendable, Equatable {
    enum Scenario: String, Sendable {
        case loading, empty, error, reloading, switching
        case noDevices = "no-devices"
    }

    struct Fractions: Sendable, Equatable {
        var a: Double
        var b: Double
    }

    var range: HistoryPageRange?
    var unit: TemperatureUnit?
    var scrollTarget: HistoryAnchor?
    var inspect: Double?
    var selection: Fractions?
    var zoom: Fractions?
    var scenario: Scenario?

    static let current = HistoryDebugOptions(arguments: ProcessInfo.processInfo.arguments)

    init(arguments: [String] = []) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        func fractions(after flag: String) -> Fractions? {
            guard let parts = value(after: flag)?.split(separator: ",").map({ Double($0) }), parts.count == 2,
                  let a = parts[0], let b = parts[1] else { return nil }
            return Fractions(a: a, b: b)
        }
        range = value(after: "-dm-history-range").flatMap(HistoryPageRange.init(rawValue:))
        unit = value(after: "-dm-history-unit").flatMap(TemperatureUnit.init(rawValue:))
        scrollTarget = value(after: "-dm-history-scroll").flatMap { name in
            switch name {
            case "tiles": .tiles
            case "hint": .hint
            default: HistoryChartModel.Kind(rawValue: name).map(HistoryAnchor.chart)
            }
        }
        inspect = value(after: "-dm-history-inspect").flatMap(Double.init)
        selection = fractions(after: "-dm-history-select")
        zoom = fractions(after: "-dm-history-zoom")
        scenario = value(after: "-dm-history-state").flatMap(Scenario.init(rawValue:))
    }

    /// A chart this wide stands in for the real ones: what is marked on it is turned into times
    /// before it is drawn, so the charts need not be this wide.
    static let chartWidth: Double = 1000

    static func x(_ fraction: Double) -> Double {
        HistoryChartLayout.padding.left + fraction * HistoryChartLayout(width: chartWidth, from: 0, to: 1).plotWidth
    }

    /// Sets a new controller up before it has loaded anything.
    @MainActor
    func prepare(_ controller: HistoryController) {
        controller.debug = self
        controller.debugOverride(range: range, unit: unit)
        guard let scenario, scenario != .noDevices else { return }
        let hub = controller.loader
        let requests = HistoryDebugCounter()
        controller.loader = { (id: String, request: HistoryRequest) async throws(HubError) -> HistoryResponse in
            requests.count += 1
            switch scenario {
            case .loading:
                try? await Task.sleep(for: .seconds(3600))
                throw HubError.cancelled
            case .empty:
                return HistoryResponse(from: request.from, to: request.to, resolution: 60_000, points: [])
            case .error:
                if requests.count == 1 { throw HubError.unreachable("The hub did not answer in time.") }
                return try await hub(id, request)
            case .reloading, .switching:
                if requests.count > 1 {
                    try? await Task.sleep(for: .seconds(3600))
                    throw HubError.cancelled
                }
                return try await hub(id, request)
            case .noDevices:
                return try await hub(id, request)
            }
        }
    }
}

/// Does, once the first answers are on screen, what the launch arguments ask for.
struct HistoryDebugDriver: View {
    let controller: HistoryController
    let proxy: ScrollViewProxy

    @Environment(HubStore.self) private var store
    @Environment(AppRouter.self) private var router

    var body: some View {
        Color.clear
            .onChange(of: controller.loadCount, initial: true) { _, count in
                apply(after: count)
            }
            .accessibilityHidden(true)
    }

    private func apply(after count: Int) {
        let options = controller.debug
        if count == 1 {
            if let target = options.scrollTarget {
                // Once the charts, which are being laid out for the first time, have their places.
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    proxy.scrollTo(target, anchor: .top)
                }
            }
            switch options.scenario {
            case .reloading:
                controller.retry()
            case .switching:
                if let next = store.devices.first(where: { $0.id != controller.deviceID }) { router.historyDeviceID = next.id }
            default:
                break
            }
            if let zoom = options.zoom {
                controller.beginSelection(from: HistoryDebugOptions.x(zoom.a), to: HistoryDebugOptions.x(zoom.a), chartWidth: HistoryDebugOptions.chartWidth)
                controller.moveSelection(to: HistoryDebugOptions.x(zoom.b))
                controller.endSelection(commit: true)
                return
            }
        }
        guard count == (options.zoom == nil ? 1 : 2) else { return }
        if let selection = options.selection {
            controller.beginSelection(from: HistoryDebugOptions.x(selection.a), to: HistoryDebugOptions.x(selection.b), chartWidth: HistoryDebugOptions.chartWidth)
        } else if let inspect = options.inspect {
            controller.point(at: HistoryDebugOptions.x(inspect), chartWidth: HistoryDebugOptions.chartWidth)
        }
    }
}

/// Counts the requests of a scripted hub.
private final class HistoryDebugCounter {
    var count = 0
}
#endif
