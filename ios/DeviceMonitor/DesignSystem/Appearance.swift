import DMCore
import SwiftUI

extension Appearance {
    /// The colour scheme the app asks for: none for `.system`, so that it follows the system's.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension EnvironmentValues {
    /// The colour scheme chosen in Settings, or nil to follow the system. Set at the root by
    /// `appEnvironment`; a sheet or popover applies it to itself with `dmAppearance()`.
    @Entry var dmColorScheme: ColorScheme? = nil
}

extension View {
    /// Asks for the chosen colour scheme on the presentation this view is in. Apply it to the
    /// content of every sheet and popover, so they never show a different scheme from the screen
    /// under them.
    func dmAppearance() -> some View {
        modifier(PresentationAppearance())
    }
}

/// What the root applies: the user's appearance, for the window and for whatever reads
/// `dmColorScheme`. It holds `Preferences` itself, because the modifier wraps the view that
/// puts them into the environment, so they are not in its own environment yet.
struct AppAppearance: ViewModifier {
    let preferences: Preferences

    func body(content: Content) -> some View {
        let scheme = preferences.appearance.colorScheme
        content
            .environment(\.dmColorScheme, scheme)
            .preferredColorScheme(scheme)
    }
}

private struct PresentationAppearance: ViewModifier {
    @Environment(\.dmColorScheme) private var scheme

    func body(content: Content) -> some View {
        content.preferredColorScheme(scheme)
    }
}
