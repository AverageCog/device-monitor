#if DEBUG
import SwiftUI

/// What the tab shell has announced to VoiceOver, as one accessibility element, because a UI
/// test cannot hear it: the reconnecting banner's "Reconnecting to hub…" and "Reconnected to
/// hub". Invisible, DEBUG builds only.
///
/// Identifier `debug-announcements`; the label is the announcements in the order they were made,
/// joined by "|", or "none".
struct AnnouncementProbe: View {
    @Observable
    final class Log {
        var spoken: [String] = []
    }

    static let log = Log()

    static func record(_ text: String) {
        log.spoken.append(text)
    }

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(Self.log.spoken.isEmpty ? "none" : Self.log.spoken.joined(separator: "|"))
            .accessibilityIdentifier("debug-announcements")
    }
}
#endif
