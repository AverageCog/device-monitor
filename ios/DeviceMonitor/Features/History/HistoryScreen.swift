import DMCore
import SwiftUI

// INTERIM — replaced by the History feature.
// The device to show comes from `AppRouter.historyDeviceID` (nil: pick the first device).
struct HistoryScreen: View {
    @Environment(HubStore.self) private var store
    @Environment(AppRouter.self) private var router

    var body: some View {
        FeaturePlaceholder(systemImage: AppTab.history.systemImage, message: message, identifier: "screen-history")
            .navigationTitle("History")
    }

    private var message: String {
        guard let id = router.historyDeviceID else { return "History charts go here." }
        return "History charts for \(store.device(id)?.displayName ?? "an unknown device") (\(id)) go here."
    }
}

#Preview {
    NavigationStack { HistoryScreen().dmScreen() }
        .demoEnvironment()
}
