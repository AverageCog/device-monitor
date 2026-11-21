import Foundation

/// The heading of the history page (renderHvDevices in public/index.html).
public struct HistoryHeader: Sendable, Equatable {
    /// What the page is titled when the device it was opened for is not known to the hub.
    public static let unknownDeviceTitle = "Unknown device"

    /// The device's name.
    public let title: String
    /// "Windows 11 Pro 24H2 · online", or just "offline" for a device that never said what it runs.
    /// Empty for an unknown device.
    public let subtitle: String
    /// nil for an unknown device.
    public let isOnline: Bool?

    public init(device d: Device?) {
        guard let d else {
            title = HistoryHeader.unknownDeviceTitle
            subtitle = ""
            isOnline = nil
            return
        }
        // $('#hvTitle').textContent = d ? d.name : 'Unknown device';
        title = d.name ?? ""
        // $('#hvSub').textContent = d ? [d.os, d.online ? 'online' : 'offline'].filter(Boolean).join(' · ') : '';
        subtitle = [d.os, d.online ? "online" : "offline"].compactMap(DashJS.text).joined(separator: " \u{B7} ")
        isOnline = d.online
    }

    /// The header for the device with the given id among those the hub knows.
    public init(devices: [Device], selected id: String?) {
        self.init(device: devices.first { $0.id == id })
    }
}

/// A device button above the history page's charts.
public struct HistoryDeviceChip: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// Decides the colour of the chip's dot.
    public let isOnline: Bool
    public let isSelected: Bool

    /// One chip per device, in the order the user arranged the dashboard, devices without a place
    /// last. Unlike the grid, names do not break ties: devices with the same place keep the order
    /// they are given in (`[...devices.values()].sort((a, b) => (a.order ?? 1e9) - (b.order ?? 1e9))`).
    public static func chips(for devices: [Device], selected: String?) -> [HistoryDeviceChip] {
        DashboardOrder.sortedByOrderOnly(devices).map {
            // <button data-id="…" class="${d.id === hv.id ? 'on' : ''}"><i class="${d.online ? 'on' : ''}"></i>${esc(d.name)}</button>
            HistoryDeviceChip(id: $0.id, name: $0.name ?? "", isOnline: $0.online, isSelected: $0.id == selected)
        }
    }

    /// The device the History button opens: the one shown last if the hub still knows it, else the
    /// first chip. nil when there are no devices.
    public static func defaultDevice(among devices: [Device], last: String?) -> String? {
        // hv.id && devices.has(hv.id) ? hv.id : first ? first.id : ''
        if let last, devices.contains(where: { $0.id == last }) { return last }
        return DashboardOrder.sortedByOrderOnly(devices).first?.id
    }
}
