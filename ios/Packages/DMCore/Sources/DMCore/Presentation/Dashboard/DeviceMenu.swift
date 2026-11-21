import Foundation

/// The "…" menu of a card or an offline row (openMenu in public/index.html).
public enum DeviceMenu {
    public enum Item: String, Sendable, Hashable, CaseIterable {
        case history, rename, remove

        public var title: String {
            switch self {
            case .history: "History"
            case .rename: "Rename"
            case .remove: "Remove from dashboard"
            }
        }

        /// The dashboard writes "Remove from dashboard" in its danger colour.
        public var isDestructive: Bool { self == .remove }
    }

    /// The items, top to bottom.
    public static let items: [Item] = [.history, .rename, .remove]
    /// Accessibility label of the button that opens the menu.
    public static let buttonLabel = "Device options"
    /// Title of the question Rename asks; its field starts out holding the device's name.
    public static let renamePrompt = "Device name"

    /// What Remove asks before anything is deleted.
    public static func removeConfirmation(name: String) -> String {
        "Remove \"\(name)\"? If its agent is still running it will re-appear. To stop it, run the uninstall command on that device."
    }

    public static func removeConfirmation(for device: Device) -> String {
        removeConfirmation(name: device.displayName)
    }
}

/// Texts of a card's other controls.
public enum DeviceCardText {
    /// The disclosure under the stats.
    public static let details = "Details"
    /// What tapping the chart does.
    public static let chartHint = "Open history"
    public static let rangePickerLabel = "Chart range"
    public static let reorderHandleLabel = "Drag to reorder"
}

/// What the hub keeps of a new device name (`sec.cleanText(body.name, 60)` behind
/// `PATCH /api/devices/<id>`), so a form can say beforehand what will be stored and whether
/// anything will be.
public enum DeviceRename {
    /// The hub cuts a name after this many UTF-16 units.
    public static let maxLength = 60

    /// The name the hub would store for `input`: control characters removed, trimmed, cut to 60
    /// UTF-16 units. nil when nothing is left, in which case the hub keeps the old name.
    ///
    /// The cut can leave a space at the end or split a character in two, exactly as on the hub; a
    /// split character comes back from the hub as U+FFFD and is the same here. Send
    /// `sendable(_:)` to avoid both.
    public static func stored(for input: String) -> String? {
        // const s = String(v).replace(/[\u0000-\u001f\u007f]/g, '').trim(); return s ? s.slice(0, max) : null;
        let cleaned = JS.trim(String(String.UnicodeScalarView(input.unicodeScalars.filter { !isControl($0) })))
        guard !cleaned.isEmpty else { return nil }
        return String(decoding: Array(cleaned.utf16.prefix(maxLength)), as: UTF16.self)
    }

    /// The name to send: `input` cleaned the way the hub would, but cut between characters and
    /// trimmed again, so the hub stores it unchanged. nil when there is nothing to send; the
    /// dashboard does not send an empty name either.
    public static func sendable(_ input: String) -> String? {
        var cleaned = JS.trim(String(String.UnicodeScalarView(input.unicodeScalars.filter { !isControl($0) })))
        // Whole characters only: dropping one from the end never leaves half a surrogate pair.
        while cleaned.utf16.count > maxLength {
            cleaned.removeLast()
            cleaned = JS.trim(cleaned)
        }
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Whether the hub would store something other than what was typed (longer than it keeps, or
    /// holding characters it removes).
    public static func isAltered(_ input: String) -> Bool {
        stored(for: input) != input
    }

    // [\u0000-\u001f\u007f]
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value <= 0x1F || scalar.value == 0x7F
    }
}
