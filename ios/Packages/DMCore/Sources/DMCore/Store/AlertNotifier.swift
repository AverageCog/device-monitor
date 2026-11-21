import Foundation

/// Where `HubStore` hands the alert events the hub wants apps to announce: those of an `alert`
/// stream event whose `notify` is true. That flag is the hub's verdict (the "apps" channel is on,
/// and the event is a firing one or resolved ones are wanted too); whether this device shows
/// anything is for the notifier to decide, for example from `Preferences.notificationsEnabled`.
///
/// Only events that arrive while the stream is connected come through here. Nothing is replayed
/// after a reconnect; `HubStore.alerts.events` has the log.
public protocol AlertNotifier: Sendable {
    @MainActor func notify(_ event: AlertEvent)
}

/// An `AlertNotifier` made from a closure.
public struct ClosureAlertNotifier: AlertNotifier {
    private let handler: @MainActor @Sendable (AlertEvent) -> Void

    public init(_ handler: @escaping @MainActor @Sendable (AlertEvent) -> Void) {
        self.handler = handler
    }

    @MainActor public func notify(_ event: AlertEvent) {
        handler(event)
    }
}
