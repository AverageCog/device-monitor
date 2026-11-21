import SwiftUI

// PLACEHOLDER — the History feature replaces this file wholesale.
// The device to show comes from `AppRouter.historyDeviceID` (nil: pick the first device).
struct HistoryScreen: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        FeaturePlaceholder(
            systemImage: AppTab.history.systemImage,
            message: router.historyDeviceID.map { "History charts for device \($0) go here." } ?? "History charts go here.",
            identifier: "screen-history"
        )
        .navigationTitle("History")
    }
}

#Preview {
    NavigationStack { HistoryScreen().dmScreen() }
        .environment(AppRouter())
        .preferredColorScheme(.dark)
}
