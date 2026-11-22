#if DEBUG
import DMCore
import SwiftUI

/// What the session and its store are doing, as one accessibility element. UI tests read it to
/// follow the app (phase, devices, the hub's heartbeat) without depending on how any screen
/// happens to draw those. Invisible, DEBUG builds only.
///
/// Identifier `debug-session`; the label is `key=value` pairs joined by ";":
/// `phase` (onboarding, connecting, live, unreachable, revoked), `demo` (0, 1), `connection`
/// (none, idle, connecting, live, reconnecting, unauthorized), `devices`, `online`, `heartbeat`
/// (ms of the last status event, 0 before the first), `readings` (changes with every report) and
/// `hub` (the origin).
struct SessionProbe: View {
    @Environment(SessionController.self) private var session

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(Self.text(for: session))
            .accessibilityIdentifier("debug-session")
    }

    static func text(for session: SessionController) -> String {
        let store = session.store
        let phase = switch session.phase {
        case .onboarding: "onboarding"
        case .connecting: "connecting"
        case .live: "live"
        case .unreachable: "unreachable"
        case .revoked: "revoked"
        }
        let connection = switch store?.connection {
        case nil: "none"
        case .idle: "idle"
        case .connecting: "connecting"
        case .live: "live"
        case .reconnecting: "reconnecting"
        case .unauthorized: "unauthorized"
        }
        // Tenths of a percent of every CPU, added up: any new report moves it.
        let readings = (store?.devices ?? []).reduce(0) { $0 + Int(Theme.clampedPercent($1.latest?.cpu.usage ?? 0) * 10) }
        let fields: [(String, String)] = [
            ("phase", phase),
            ("demo", session.isDemo ? "1" : "0"),
            ("connection", connection),
            ("devices", String(store?.devices.count ?? 0)),
            ("online", String(store?.onlineDevices.count ?? 0)),
            ("heartbeat", String(Int64(store?.lastStatusAt ?? 0))),
            ("readings", String(readings)),
            ("hub", session.hubOriginText ?? ""),
        ]
        return fields.map { "\($0.0)=\($0.1)" }.joined(separator: ";")
    }
}
#endif
