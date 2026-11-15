import Foundation

public protocol MealSyncClient: Sendable {
    func sync(_ change: PendingMealChange, accessToken: String) async throws -> MealSyncAcknowledgement
}

public enum PendingMealChange: Codable, Equatable, Sendable, Identifiable {
    case save(MealRecord, revision: Int)
    case delete(id: UUID, ownerID: UUID, revision: Int)

    public var id: UUID {
        switch self {
        case .save(let meal, _): meal.id
        case .delete(let id, _, _): id
        }
    }

    public var ownerID: UUID {
        switch self {
        case .save(let meal, _): meal.ownerID
        case .delete(_, let ownerID, _): ownerID
        }
    }

    public var revision: Int {
        switch self {
        case .save(_, let revision), .delete(_, _, let revision): revision
        }
    }
}

public struct MealSyncAcknowledgement: Decodable, Equatable, Sendable {
    public let id: UUID
    public let revision: Int

    public init(id: UUID, revision: Int) {
        self.id = id
        self.revision = revision
    }
}

public enum MealSyncFailure: Error {
    case authenticationRequired
    case rejected
    case unavailable
}

extension MealWorkflow {
    /// Sends the pending snapshots and deletions available when the foreground drain began.
    /// Each accepted change is acknowledged durably against the current library.
    public func syncPendingMealChanges() async {
        let generation = authenticationGeneration
        guard let mealSync, access == .owner, localMealsLoaded,
              mealSyncGeneration != generation else { return }
        mealSyncGeneration = generation
        defer { if mealSyncGeneration == generation { mealSyncGeneration = nil } }

        for change in pendingMealChanges {
            guard !Task.isCancelled, generation == authenticationGeneration else { return }
            let acknowledgement: MealSyncAcknowledgement
            do {
                guard let accepted = try await sendPendingChange(generation: generation, isCurrent: {
                    isCurrentPendingChange(change)
                }, send: { token in
                    try await mealSync.sync(change, accessToken: token)
                }) else { continue }
                acknowledgement = accepted
            } catch MealSyncFailure.rejected {
                // An invalid individual record remains pending while other meals can sync.
                continue
            } catch {
                return
            }

            guard !Task.isCancelled, generation == authenticationGeneration else { return }
            guard acknowledgement.id == change.id, acknowledgement.revision == change.revision,
                  let index = localMeals.pendingChanges.firstIndex(of: change) else { continue }

            var updated = localMeals
            updated.pendingChanges.remove(at: index)
            do { try saveLocalMeals(updated) }
            catch { return }
        }
    }

    func sendPendingChange(generation: Int, isCurrent: () -> Bool,
                           send: (String) async throws -> MealSyncAcknowledgement) async throws -> MealSyncAcknowledgement? {
        let token = try await accessToken()
        guard !Task.isCancelled, generation == authenticationGeneration, isCurrent() else { return nil }
        do {
            return try await send(token)
        } catch MealSyncFailure.authenticationRequired {
            guard !Task.isCancelled, generation == authenticationGeneration, isCurrent() else { return nil }
            let renewedToken = try await accessToken(rejecting: token)
            guard !Task.isCancelled, generation == authenticationGeneration, isCurrent() else { return nil }
            return try await send(renewedToken)
        }
    }

    private func isCurrentPendingChange(_ change: PendingMealChange) -> Bool {
        access == .owner && localMealsLoaded && localMeals.pendingChanges.contains(change)
    }
}
