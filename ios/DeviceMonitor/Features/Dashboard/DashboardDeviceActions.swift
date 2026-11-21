import DMCore
import Observation
import SwiftUI

/// The "…" menu of a card or an offline row and the questions it asks (`openMenu` in
/// public/index.html): History, Rename (the dashboard's `prompt`) and Remove from dashboard (its
/// `confirm`). One model per place that presents them: the Devices tab, and the offline list.
@Observable
final class DashboardDeviceActionModel {
    struct Subject: Equatable {
        var id: String
        /// What the device is called on screen, for messages.
        var name: String
    }

    struct Failure: Equatable {
        var title: String
        var message: String
    }

    /// The device being renamed while the question is up.
    var renaming: Subject?
    var renameText = ""
    /// The device whose removal is being confirmed.
    var removing: Subject?
    /// What last went wrong. Kept once its alert has gone, so the text does not blank on the way out.
    private(set) var failure: Failure?
    var hasFailure = false
    /// Bumped when the hub has done what was asked, and when it has not, for the haptics.
    private(set) var successes = 0
    private(set) var failures = 0

    var isRenaming: Bool {
        get { renaming != nil }
        set { if !newValue { renaming = nil } }
    }

    var isRemoving: Bool {
        get { removing != nil }
        set { if !newValue { removing = nil } }
    }

    /// False when the hub would keep the old name: nothing is left of the text once cleaned.
    var canRename: Bool { DeviceRename.stored(for: renameText) != nil }

    /// A menu item was chosen. `openHistory` leaves whatever is in the way first.
    func perform(_ item: DeviceMenuItem, on device: Device, openHistory: () -> Void) {
        switch item {
        case .history:
            openHistory()
        case .rename:
            // prompt('Device name', d.name)
            renameText = device.name ?? ""
            renaming = Subject(id: device.id, name: device.displayName)
        case .remove:
            removing = Subject(id: device.id, name: device.displayName)
        }
    }

    /// Sends the name as the hub would store it. The new name shows when the hub announces it.
    ///
    /// The device comes from the question that was answered and not from `renaming`: by the time
    /// a button's action runs, the alert may already have put its state away.
    func commitRename(_ subject: Subject, store: HubStore) {
        renaming = nil
        guard let name = DeviceRename.sendable(renameText) else { return }
        Task {
            do {
                try await store.rename(device: subject.id, name: name)
                successes += 1
            } catch {
                report(DashboardStrings.renameFailed(subject.name), HubError(error))
            }
        }
    }

    /// The card goes when the hub announces the removal.
    func commitRemove(_ subject: Subject, store: HubStore) {
        removing = nil
        Task {
            do {
                try await store.remove(device: subject.id)
                successes += 1
            } catch {
                report(DashboardStrings.removeFailed(subject.name), HubError(error))
            }
        }
    }

    /// Shows why something the user asked for did not happen. A hub that no longer knows this app
    /// is the session's to explain, and a cancelled request is nobody's.
    func report(_ title: String, _ error: HubError) {
        switch error.kind {
        case .unauthorized, .cancelled:
            break
        case .unreachable, .rejected, .other:
            failure = Failure(title: title, message: error.errorDescription ?? "")
            hasFailure = true
            failures += 1
        }
    }
}

/// The items of a device's menu, in the dashboard's order, for a `Menu` or a context menu.
struct DashboardDeviceMenuItems: View {
    let perform: (DeviceMenuItem) -> Void

    var body: some View {
        ForEach(DeviceMenuItem.allCases, id: \.self) { item in
            Button(role: item.isDestructive ? .destructive : nil) {
                perform(item)
            } label: {
                Label(item.title, systemImage: Self.symbol(for: item))
            }
        }
    }

    private static func symbol(for item: DeviceMenuItem) -> String {
        switch item {
        case .history: AppTab.history.systemImage
        case .rename: "pencil"
        case .remove: "trash"
        }
    }
}

/// The "…" button that opens a device's menu (`.menu-btn`), with a 44-point target around the
/// glyph. Lays out as `size` points wide so it can sit flush with a card's content edge.
struct DashboardDeviceMenuButton: View {
    let identifier: String
    let perform: (DeviceMenuItem) -> Void

    private static let reach: CGFloat = 44
    /// What the glyph's plate takes up in layout (the design system's icon button).
    private static let plate: CGFloat = 34

    var body: some View {
        let inset = (Self.plate - Self.reach) / 2
        Menu {
            DashboardDeviceMenuItems(perform: perform)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.textMuted)
                .frame(width: Self.reach, height: Self.reach)
                .contentShape(Rectangle())
        }
        .padding(inset)
        .accessibilityLabel(DeviceMenuItem.buttonLabel)
        .accessibilityIdentifier(identifier)
    }
}

extension View {
    /// Presents the rename question, the remove confirmation and the failure alert of `model`.
    /// Apply it to the root of whatever is on screen: an alert cannot come up from under a sheet.
    func dashboardDeviceActions(_ model: DashboardDeviceActionModel) -> some View {
        modifier(DashboardDeviceActionAlerts(model: model))
    }
}

private struct DashboardDeviceActionAlerts: ViewModifier {
    @Bindable var model: DashboardDeviceActionModel
    @Environment(HubStore.self) private var store

    func body(content: Content) -> some View {
        content
            .alert(DeviceMenuItem.renamePrompt, isPresented: $model.isRenaming, presenting: model.renaming) { subject in
                TextField(DeviceMenuItem.renamePrompt, text: $model.renameText)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                Button(DashboardStrings.cancel, role: .cancel) {}
                Button(DeviceMenuItem.rename.title) { model.commitRename(subject, store: store) }
                    .disabled(!model.canRename)
            } message: { _ in
                Text(DashboardStrings.renameMessage)
            }
            .alert(DeviceMenuItem.remove.title, isPresented: $model.isRemoving, presenting: model.removing) { subject in
                Button(DashboardStrings.remove, role: .destructive) { model.commitRemove(subject, store: store) }
                Button(DashboardStrings.cancel, role: .cancel) {}
            } message: { subject in
                Text(DeviceMenuItem.removeConfirmation(name: subject.name))
            }
            .alert(model.failure?.title ?? "", isPresented: $model.hasFailure, presenting: model.failure) { _ in
                Button(DashboardStrings.ok, role: .cancel) {}
            } message: { failure in
                Text(failure.message)
            }
            .sensoryFeedback(.success, trigger: model.successes)
            .sensoryFeedback(.error, trigger: model.failures)
    }
}
