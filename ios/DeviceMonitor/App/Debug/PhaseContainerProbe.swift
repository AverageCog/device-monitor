#if DEBUG
import SwiftUI

/// A `PhaseContainer` whose content can be made taller than the screen, to check that the content
/// keeps its state and keyboard focus when the container goes from centred to scrolling and back.
/// Debug → Phase container, or `-dm-probe phase-container`.
struct PhaseContainerProbe: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isTall = false

    var body: some View {
        PhaseContainer {
            VStack(spacing: Theme.Spacing.l) {
                ProbeState()
                Button(isTall ? "Shrink" : "Grow") { isTall.toggle() }
                    .buttonStyle(.dm())
                    .accessibilityIdentifier("probe-grow-button")
                Button("Close") { dismiss() }
                    .buttonStyle(.dm())
                    .accessibilityIdentifier("probe-close-button")
                if isTall {
                    // Taller than any screen, so the container has to scroll.
                    Color.clear
                        .frame(height: 2000)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: 420)
            .padding(Theme.Spacing.xl)
        }
    }
}

/// State that lives inside the container's content: what a rebuilt copy of the content would lose.
private struct ProbeState: View {
    @State private var count = 0
    @State private var text = ""

    var body: some View {
        Button("Count: \(count)") { count += 1 }
            .buttonStyle(.dm(.primary))
            .accessibilityIdentifier("probe-counter")
        TextField("Type here", text: $text)
            .textFieldStyle(.plain)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .dmField()
            .accessibilityIdentifier("probe-field")
    }
}

#Preview {
    PhaseContainerProbe()
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
}
#endif
