import SwiftUI

/// A full-screen phase: content centred on the page background. When the content is taller than the
/// screen (a phone in landscape, large text) it scrolls instead of being clipped.
/// The phase screens themselves are in Features/Onboarding.
struct PhaseContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        // One copy of the content, in a scroll view at least as tall as the screen. Picking between
        // a centred and a scrolling copy (ViewThatFits) rebuilds the content each time the keyboard,
        // a rotation or the text size tips it over, and its state and keyboard focus go with it.
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Theme.page.ignoresSafeArea())
    }
}
