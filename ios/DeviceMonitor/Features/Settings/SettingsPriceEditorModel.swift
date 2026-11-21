import DMCore
import Observation
import SwiftUI

/// Runs DMCore's `PriceEditor` against the hub for one editor on screen: every change is applied
/// and saved in the order it was made, one at a time, and the editor follows what the store
/// hears about the price from elsewhere.
///
/// The dashboard works a change out from the price it last heard of, and sends it at once
/// (saveEnergySettings in public/index.html). Two quick changes can therefore be worked out from
/// the same old price, and the second undoes the first. Here a change waits for the one before it
/// to be answered, so it always starts from what the hub has.
@Observable
final class SettingsPriceEditorModel {
    enum Phase: Equatable {
        /// The hub has not said yet whether a price is saved.
        case loading
        /// It could not be asked; the text says why.
        case failed(String)
        case ready
    }

    private(set) var editor: PriceEditor
    private(set) var phase = Phase.loading
    /// Moves whenever the editor may have refilled its fields, so the view can refill its own.
    private(set) var revision = 0
    private(set) var isSaving = false
    /// Why the last save did not reach the hub; nil once one has.
    private(set) var saveFailure: String?
    /// Counts failed saves, for the haptic.
    private(set) var failures = 0
    /// Where the keyboard is. The view keeps it current; the editor leaves that field alone.
    @ObservationIgnored var focus = PriceEditor.Focus.none

    @ObservationIgnored private weak var store: HubStore?
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var failedBody: EnergySettings?
    @ObservationIgnored private var script: SettingsLaunch.PriceScript?
    @ObservationIgnored private var isLoading = false

    /// - Parameter script: DEBUG builds only, a state to open with (see `SettingsLaunch`).
    init(script: SettingsLaunch.PriceScript? = nil) {
        // Until the hub has answered, the price is the guess for this device, as on the dashboard.
        editor = PriceEditor(saved: nil)
        self.script = script
    }

    /// Whether a DEBUG launch argument wants the region list open.
    var opensRegions: Bool { script?.showsRegions ?? false }

    // MARK: Loading

    /// Call when the editor comes on screen: shows what the hub has, asking first if the store
    /// has not heard yet.
    func start(store: HubStore) async {
        self.store = store
        if phase == .ready {
            hubChanged()
        } else {
            await load()
        }
    }

    /// Asks the hub for the saved price ("Try again").
    func load() async {
        guard let store, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        switch script?.loadAnswer {
        case .silence:
            phase = .loading
            return
        case .failure(let error):
            phase = .failed(PriceEditorNotes.loadFailed(error))
            return
        case nil:
            break
        }
        if !store.isEnergySettingsLoaded {
            phase = .loading
            do {
                try await store.refreshEnergySettings()
            } catch {
                let failure = HubError(error)
                // The screen went away while the hub was answering; it asks again when it is back.
                if failure == .cancelled { return }
                if !store.isEnergySettingsLoaded {
                    phase = .failed(PriceEditorNotes.loadFailed(failure))
                    return
                }
            }
        }
        adopt(from: store)
    }

    private func adopt(from store: HubStore) {
        editor.hubSaved(store.energySettings, focus: focus)
        phase = .ready
        revision += 1
        let steps = script?.steps ?? []
        script?.steps = []
        for step in steps {
            perform { editor, _ in step(&editor) }
        }
    }

    /// The store heard about the price: an `energySettings` event, another screen's save, or the
    /// first answer. A field the user is in is not refilled.
    func hubChanged() {
        guard let store else { return }
        switch phase {
        case .ready:
            // Behind whatever is still being saved: that answer is this news, or newer.
            enqueue { [self] in
                guard store.energySettings != editor.saved else { return }
                editor.hubSaved(store.energySettings, focus: focus)
                revision += 1
            }
        case .loading, .failed:
            if store.isEnergySettingsLoaded, script?.loadAnswer == nil { adopt(from: store) }
        }
    }

    // MARK: Changes

    /// Applies one change the user made and saves what comes of it. `action` gets the editor as
    /// the hub last left it and the field the keyboard is in, and returns the body to send, or
    /// nil when there is nothing to send.
    func perform(_ action: @escaping @MainActor (inout PriceEditor, PriceEditor.Focus) -> EnergySettings?) {
        guard phase == .ready else { return }
        enqueue { [self] in
            let body = action(&editor, focus)
            revision += 1
            if let body { await send(body) }
        }
    }

    /// The flat rate field was left without having been typed in. If it still shows what was in
    /// it when the keyboard arrived, it now shows the hub's rate again (the dashboard's next
    /// renderPriceRow does the same).
    func settle() {
        guard phase == .ready else { return }
        enqueue { [self] in
            guard editor.mode == .flat else { return }
            editor.hubSaved(editor.saved, focus: focus)
            revision += 1
        }
    }

    /// Sends the change that failed once more.
    func retry() {
        guard let body = failedBody else { return }
        enqueue { [self] in await send(body) }
    }

    /// One at a time, in order. The model stays alive until the last one has been answered, so a
    /// change made just before the editor is closed is still saved.
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await operation()
        }
    }

    private func send(_ body: EnergySettings) async {
        guard let store else { return }
        // Committing a field that says the same in other words ("0.3160") changes nothing: the
        // field is tidied, the hub is not asked. A browser fires no change event for it either.
        if let saved = editor.saved, EnergyPricing.hubStored(body) == saved {
            editor.hubSaved(saved, focus: focus)
            revision += 1
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await save(body, to: store)
            failedBody = nil
            saveFailure = nil
            // What the hub has now: this save, or a later one from elsewhere that overtook it.
            editor.hubSaved(store.energySettings, focus: focus)
        } catch {
            failedBody = body
            saveFailure = PriceEditorNotes.saveFailed(HubError(error))
            failures += 1
            editor.saveFailed(focus: focus)
        }
        revision += 1
    }

    private func save(_ body: EnergySettings, to store: HubStore) async throws(HubError) {
        switch script?.saveAnswer {
        case .failure(let error): throw error
        case .silence:
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)) }
            throw HubError.cancelled
        case nil: try await store.saveEnergySettings(body)
        }
    }
}
