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
    /// Why the last save did not reach the hub; nil once one has, or once the hub is found to
    /// hold that price after all.
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

    /// Whether a DEBUG launch argument wants the region list open. True once.
    func takeOpensRegions() -> Bool {
        defer { script?.showsRegions = false }
        return script?.showsRegions ?? false
    }

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
        if let isTime = script?.startsWhen {
            // DEBUG launch argument only: the steps below wait their turn behind this.
            enqueue {
                var tries = 0
                while !isTime(store), tries < 100 {
                    tries += 1
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
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
                forgetFailureIfSaved()
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
            // What "One rate" replaced is remembered for the session, not by this editor: it may
            // have been chosen in the other one, or in this one before it was last closed.
            if let store { editor.remember(SettingsPriceMemory.periods(for: store)) }
            let body = action(&editor, focus)
            if let store { SettingsPriceMemory.remember(editor.rememberedPeriods, for: store) }
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
            forgetFailureIfSaved()
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
            if let held = store.energySettings, EnergyPricing.hubStored(body) == held {
                // Only the answer was lost: the hub's own news of this very price got here
                // while it was awaited. A request that timed out may still have been carried out.
                failedBody = nil
                saveFailure = nil
                editor.hubSaved(held, focus: focus)
            } else {
                failedBody = body
                saveFailure = PriceEditorNotes.saveFailed(HubError(error))
                failures += 1
                editor.saveFailed(focus: focus)
            }
        }
        revision += 1
    }

    /// The editor was just told what the hub holds. If that is the price whose save failed,
    /// nothing is left to report or to send again: the hub carried the change out although its
    /// answer never came, or the same change was made on another screen.
    private func forgetFailureIfSaved() {
        guard let failedBody, let saved = editor.saved, EnergyPricing.hubStored(failedBody) == saved else { return }
        self.failedBody = nil
        saveFailure = nil
    }

    private func save(_ body: EnergySettings, to store: HubStore) async throws(HubError) {
        switch script?.saveAnswer {
        case .failure(let error):
            // DEBUG launch argument only: the hub does as asked, and all the editor is told is
            // that it could not be reached.
            if let delay = script?.newsOfFailedSave {
                if delay == .zero {
                    try await store.saveEnergySettings(body)
                } else {
                    Task {
                        try? await Task.sleep(for: delay)
                        _ = try? await store.saveEnergySettings(body)
                    }
                }
            }
            throw error
        case .silence:
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)) }
            throw HubError.cancelled
        case nil: try await store.saveEnergySettings(body)
        }
    }
}

/// The time-of-use periods that "One rate" last replaced, for as long as the app stays with a
/// hub, so that "Time of use" brings them back. The dashboard keeps them in `lastTou`, a
/// variable of its page ("Switching back and forth keeps the periods you had, for this session",
/// public/index.html), where they outlast its settings dialog. Here the editor under "Advanced
/// settings" and the one in `ElectricityPriceSheet` are made anew whenever they are shown, each
/// with a model of its own, so what they remember is kept here for both.
enum SettingsPriceMemory {
    /// The session the periods belong to: the session controller makes a store for every hub
    /// it follows, and lets go of it on disconnecting.
    private static weak var store: HubStore?
    private static var periods: [TouPeriod]?

    static func periods(for store: HubStore) -> [TouPeriod]? {
        self.store === store ? periods : nil
    }

    static func remember(_ periods: [TouPeriod]?, for store: HubStore) {
        self.store = store
        self.periods = periods
    }
}
