import Foundation

extension MealWorkflow {
    public func syncPendingObservationChanges() async {
        let generation = authenticationGeneration
        guard let observationSync, access == .owner, localMealsLoaded,
              observationSyncGeneration != generation else { return }
        observationSyncGeneration = generation
        defer { if observationSyncGeneration == generation { observationSyncGeneration = nil } }

        for change in pendingObservationChanges {
            guard !Task.isCancelled, generation == authenticationGeneration else { return }
            let acknowledgement: MealSyncAcknowledgement
            do {
                guard let accepted = try await sendPendingChange(generation: generation, isCurrent: {
                    canSendObservationChange(change)
                }, send: { token in
                    try await observationSync.sync(change, accessToken: token)
                }) else { continue }
                acknowledgement = accepted
            } catch MealSyncFailure.rejected {
                continue
            } catch {
                return
            }

            guard !Task.isCancelled, generation == authenticationGeneration else { return }
            guard acknowledgement.id == change.id, acknowledgement.revision == change.revision,
                  let index = localMeals.pendingObservationChanges.firstIndex(of: change) else { continue }
            var updated = localMeals
            updated.pendingObservationChanges.remove(at: index)
            do { try saveLocalMeals(updated) }
            catch { return }
        }
    }

    private func canSendObservationChange(_ change: PendingObservationChange) -> Bool {
        guard access == .owner, localMealsLoaded, pendingObservationChanges.contains(change) else { return false }
        if case .save(let record, _) = change, let mealID = record.mealID {
            return loggedMeals.contains { $0.id == mealID } && !pendingMealChanges.contains { $0.id == mealID }
        }
        return true
    }
}
