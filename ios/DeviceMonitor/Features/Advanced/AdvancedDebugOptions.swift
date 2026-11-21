import DMCore
import SwiftUI

/// States of the Advanced tab chosen by launch argument in DEBUG builds, for screenshots and UI
/// tests where nothing can tap, drag or scroll its way there. Combine with `-dm-demo -dm-tab advanced`.
///
///     -dm-advanced-range <24h|7d|30d>     open on this range; the saved choice is left alone
///     -dm-advanced-state <loading|failed|stale|empty|no-devices>
///                                         loading:    the hub never answers
///                                         failed:     every request for totals fails
///                                         stale:      the first request is answered, the next fails
///                                         empty:      the hub has no totals for the range
///                                         no-devices: no totals and no devices either
///     -dm-advanced-price <guessed|tou>    work the page out as if no price were saved, or as if
///                                         time-of-use rates were; nothing is sent to the hub
///     -dm-advanced-section <electricity|chart|power|usage|note>
///                                         scroll there once the totals are in
///     -dm-advanced-bucket <index|last>    select that bar of the chart, as a touch would
///     -dm-advanced-expand <device id|all> open that device's power breakdown
///     -dm-advanced-width <points>         lay the page out this wide and let it scroll sideways,
///                                         to look at the iPad layouts on a phone
///     -dm-advanced-pan <0…1>              with -dm-advanced-width: how far along to start
///
/// A release build reads none of them: there `current` is the value with nothing set, and the
/// code that would replace the hub's answers is not compiled.
nonisolated struct AdvancedDebugOptions: Sendable, Equatable {
    enum State: String, Sendable {
        case loading, failed, stale, empty
        case noDevices = "no-devices"
    }

    enum Price: String, Sendable {
        case guessed, tou
    }

    enum Bucket: Sendable, Equatable {
        case index(Int)
        case last
    }

    var range: AdvancedRange?
    var state: State?
    var price: Price?
    var section: AdvancedSection?
    var bucket: Bucket?
    /// A device id, or "all".
    var expanded: String?
    var width: CGFloat?
    var pan: CGFloat = 0

    init() {}

    /// Whether `deviceID`'s power breakdown starts open.
    func expands(_ deviceID: String) -> Bool {
        expanded == deviceID || expanded == "all"
    }

    #if DEBUG
    static let current = AdvancedDebugOptions(arguments: ProcessInfo.processInfo.arguments)

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            let next = arguments[index + 1]
            return next.hasPrefix("-") ? nil : next
        }
        range = value(after: "-dm-advanced-range").flatMap(AdvancedRange.init(rawValue:))
        state = value(after: "-dm-advanced-state").flatMap(State.init(rawValue:))
        price = value(after: "-dm-advanced-price").flatMap(Price.init(rawValue:))
        section = value(after: "-dm-advanced-section").flatMap(AdvancedSection.init(rawValue:))
        if let text = value(after: "-dm-advanced-bucket") {
            bucket = text == "last" ? .last : Int(text).map(Bucket.index)
        }
        expanded = value(after: "-dm-advanced-expand")
        width = value(after: "-dm-advanced-width").flatMap(Double.init).flatMap { $0 >= 200 ? CGFloat($0) : nil }
        pan = value(after: "-dm-advanced-pan").flatMap(Double.init).map { CGFloat(min(1, max(0, $0))) } ?? 0
    }

    /// For previews: the page in one of its states.
    static func showing(_ state: State?, range: AdvancedRange? = nil, price: Price? = nil, bucket: Bucket? = nil, expanded: String? = nil) -> AdvancedDebugOptions {
        var options = AdvancedDebugOptions()
        options.state = state
        options.range = range
        options.price = price
        options.bucket = bucket
        options.expanded = expanded
        return options
    }
    #else
    static let current = AdvancedDebugOptions()
    #endif
}

#if DEBUG
extension AdvancedDebugOptions {
    /// The hub's answers, with the parts the options ask for replaced.
    @MainActor
    var inputs: AdvancedInputs {
        var inputs = AdvancedInputs()
        switch state {
        case .loading:
            inputs.energy = { _, _ in
                try await Task.sleep(for: .seconds(86_400))
                throw HubError.cancelled
            }
        case .failed:
            inputs.energy = { _, _ in throw HubError.http(status: 503, message: "The hub is still reading its history.") }
        case .stale:
            let asked = AdvancedDebugCounter()
            inputs.energy = { store, bounds in
                asked.count += 1
                guard asked.count == 1 else { throw HubError.http(status: 503, message: "The hub is still reading its history.") }
                return try await store.loadEnergy(bounds: bounds)
            }
        case .empty, .noDevices:
            inputs.energy = { store, bounds in EnergyResponse(bounds: bounds, settings: store.energySettings, devices: []) }
        case nil:
            break
        }
        if state == .noDevices { inputs.devices = { _ in [] } }
        switch price {
        case .guessed:
            inputs.price = { _ in EnergyPrice(saved: nil) }
        case .tou:
            inputs.price = { _ in
                EnergyPrice(region: PriceRegions.customCode, currency: "USD", rate: 0.3, tou: [TouPeriod(from: 16, to: 21, rate: 0.52)])
            }
        case nil:
            break
        }
        return inputs
    }
}

/// How often a scripted hub has been asked.
@MainActor
private final class AdvancedDebugCounter {
    var count = 0
}
#endif
