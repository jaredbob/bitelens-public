import Foundation

public protocol AppleHealthClient: Sendable {
    func isAvailable() async -> Bool
    func authorizedNutrients() async -> Set<Nutrient>
    func requestAuthorization(for nutrients: Set<Nutrient>) async throws
    func save(_ sample: AppleHealthSample) async throws
    func ownSampleRevision(mealID: UUID, nutrient: Nutrient) async throws -> Int?
    func hasOwnSampleDeletion(mealID: UUID, nutrient: Nutrient, revision: Int) async throws -> Bool
    /// Returns true if HealthKit deleted at least one matching sample.
    func deleteOwnSamples(mealID: UUID, nutrient: Nutrient) async throws -> Bool
}

public struct AppleHealthSample: Equatable, Sendable {
    public static let supportedNutrients: Set<Nutrient> = [
        .calories, .protein, .carbohydrates, .fat, .fiber, .sodium, .caffeine, .alcohol,
    ]

    public let mealID: UUID
    public let nutrient: Nutrient
    public let amount: Double
    public let mealTime: Date
    public let revision: Int

    public var syncIdentifier: String { Self.syncIdentifier(mealID: mealID, nutrient: nutrient) }

    public static func syncIdentifier(mealID: UUID, nutrient: Nutrient) -> String {
        "bitelens.\(mealID.uuidString.lowercased()).\(nutrient.rawValue)"
    }

    public var unit: String { nutrient == .alcohol ? "count" : nutrient.unit }
}

public enum AppleHealthBackfillError: Error {
    case paused
    case unavailable
    case writeAccessRequired
}

public struct AppleHealthSyncStatus: Equatable, Sendable {
    public enum WriteAccess: Equatable, Sendable {
        case checking
        case unavailable
        case available(Set<Nutrient>)
    }

    public let writeAccess: WriteAccess
    public let hasPendingWork: Bool
    public let hasFailedWork: Bool
}

enum AppleHealthAuthorizationRequest: String, Codable {
    case pending
    case failed
    case completed
}

private struct AppleHealthNutrientChange {
    let nutrient: Nutrient
    let amount: Double?
    let previous: AppleHealthNutrientOutcome?
}

/// The presence of this local record marks eligibility from confirmation or backfill.
struct AppleHealthMealState: Codable {
    var outcomes: [Nutrient: AppleHealthNutrientOutcome] = [:]
    var failedNutrients: Set<Nutrient>?

    fileprivate func pendingChanges(for meal: LoggedMeal?) -> [AppleHealthNutrientChange] {
        let totals = meal?.record.nutrientTotals
        return AppleHealthSample.supportedNutrients.compactMap { nutrient in
            let previous = outcomes[nutrient]
            guard previous?.needsSync(for: meal?.revision) ?? (meal != nil) else { return nil }

            let total = totals?[nutrient]
            let amount = total.flatMap { total -> Double? in
                guard !total.isIncomplete, let amount = total.knownAmount, amount.isFinite else { return nil }
                if nutrient == .alcohol { return amount > 0 ? amount / 14 : nil }
                return amount
            }
            guard amount != nil || previous?.mayHaveSample == true else { return nil }
            return AppleHealthNutrientChange(nutrient: nutrient, amount: amount, previous: previous)
        }
    }
}

enum AppleHealthNutrientOutcome: Codable, Equatable {
    case skipped(revision: Int)
    case written(revision: Int)
    // A write or deletion can commit before the local acknowledgment.
    // Legacy in-flight writes did not record the attempted revision.
    case writing(replacingSample: Bool, revision: Int?)
    case removing
    case suppressed

    var mayHaveSample: Bool {
        switch self {
        case .written, .writing, .removing: true
        case .skipped, .suppressed: false
        }
    }

    var hasConfirmedSample: Bool {
        switch self {
        case .written: true
        case .writing(let replacingSample, _): replacingSample
        case .skipped, .removing, .suppressed: false
        }
    }

    func needsSync(for revision: Int?) -> Bool {
        guard let revision else { return mayHaveSample }
        return switch self {
        case .skipped(let settled), .written(let settled): settled < revision
        case .writing, .removing: true
        case .suppressed: false
        }
    }
}

extension MealWorkflow {
    public var appleHealthSyncEnabled: Bool {
        !isBeta && access == .owner && localMealsLoaded && localMeals.appleHealthSyncEnabled
    }

    public var appleHealthSyncStatus: AppleHealthSyncStatus {
        guard access == .owner, localMealsLoaded else {
            return AppleHealthSyncStatus(writeAccess: .checking, hasPendingWork: false, hasFailedWork: false)
        }
        let mealsByID = appleHealthLoggedMealsByID
        var hasPendingWork = needsAppleHealthAuthorization
        var hasFailedWork = needsAppleHealthAuthorization && localMeals.appleHealthAuthorizationRequest == .failed
        for (mealID, state) in localMeals.appleHealthMeals {
            let changes = state.pendingChanges(for: mealsByID[mealID])
            if !changes.isEmpty { hasPendingWork = true }
            if changes.contains(where: { state.failedNutrients?.contains($0.nutrient) == true }) {
                hasFailedWork = true
                break
            }
        }
        return AppleHealthSyncStatus(writeAccess: appleHealthWriteAccess, hasPendingWork: hasPendingWork,
                                     hasFailedWork: hasFailedWork)
    }

    public func setAppleHealthSyncEnabled(_ enabled: Bool) async {
        guard access == .owner, localMealsLoaded, appleHealth != nil, enabled != appleHealthSyncEnabled else { return }
        var updated = localMeals
        updated.appleHealthSyncEnabled = enabled
        do { try saveLocalMeals(updated) }
        catch {
            issue = .storageUnavailable
            return
        }

        guard enabled else { return }
        scheduleAppleHealthSync(requestAuthorization: true)
        await appleHealthSyncTask?.value
    }

    public func syncPendingAppleHealthChanges() async {
        if appleHealthSyncTask == nil { scheduleAppleHealthSync() }
        await appleHealthSyncTask?.value
    }

    public func retryAppleHealthSync() async {
        scheduleAppleHealthSync(requestAuthorization: true)
        await appleHealthSyncTask?.value
    }

    @discardableResult public func backfillAppleHealth(timeZone: TimeZone = .current) async throws -> Int {
        guard appleHealthSyncEnabled else { throw AppleHealthBackfillError.paused }
        let today = now()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: today))!
        let firstDay = MealTime(instant: start, timeZone: timeZone).localDate
        let lastDay = MealTime(instant: today, timeZone: timeZone).localDate
        let selected = Set(loggedMeals.filter { (firstDay...lastDay).contains($0.record.mealTime.localDate) }.map(\.id))

        await retryAppleHealthSync()
        guard appleHealthSyncEnabled else { throw AppleHealthBackfillError.paused }
        guard case .available(let authorized) = appleHealthWriteAccess else { throw AppleHealthBackfillError.unavailable }
        guard !authorized.isEmpty else { throw AppleHealthBackfillError.writeAccessRequired }

        let meals = loggedMeals.filter { selected.contains($0.id) }
        var updated = localMeals
        for meal in meals where updated.appleHealthMeals[meal.id] == nil {
            updated.appleHealthMeals[meal.id] = AppleHealthMealState()
        }
        if updated.appleHealthMeals.count != localMeals.appleHealthMeals.count {
            try saveLocalMeals(updated)
            scheduleAppleHealthSync()
        }
        return meals.count
    }

    func scheduleAppleHealthSync(requestAuthorization: Bool = false) {
        guard access == .owner, localMealsLoaded, appleHealth != nil else { return }
        if requestAuthorization, needsAppleHealthAuthorization, !isRequestingAppleHealthAuthorization {
            shouldRequestAppleHealthAuthorization = true
        }
        needsAppleHealthSyncPass = true
        guard appleHealthSyncTask == nil else { return }
        appleHealthSyncTask = Task {
            while needsAppleHealthSyncPass {
                needsAppleHealthSyncPass = false
                let requestAuthorization = shouldRequestAppleHealthAuthorization
                shouldRequestAppleHealthAuthorization = false
                await exportPendingAppleHealthSamples(requestAuthorization: requestAuthorization)
            }
            appleHealthSyncTask = nil
        }
    }

    private var needsAppleHealthAuthorization: Bool {
        appleHealthSyncEnabled &&
            (localMeals.appleHealthAuthorizationRequest != .completed || !localMeals.appleHealthAuthorizationIncludesAlcohol)
    }

    private var appleHealthLoggedMealsByID: [UUID: LoggedMeal] {
        let meals = localMeals.loggedMeals.lazy.filter { $0.record.ownerID == self.activeAccountID }
        return Dictionary(uniqueKeysWithValues: meals.map { ($0.id, $0) })
    }

    private func requestAppleHealthAuthorization(using appleHealth: any AppleHealthClient) async {
        isRequestingAppleHealthAuthorization = true
        defer { isRequestingAppleHealthAuthorization = false }
        let result: AppleHealthAuthorizationRequest
        do {
            // A completed request can still leave write access denied.
            try await appleHealth.requestAuthorization(for: AppleHealthSample.supportedNutrients)
            result = .completed
        } catch { result = .failed }
        guard access == .owner, localMealsLoaded else { return }
        var updated = localMeals
        updated.appleHealthAuthorizationRequest = result
        if result == .completed { updated.appleHealthAuthorizationIncludesAlcohol = true }
        guard updated.appleHealthAuthorizationRequest != localMeals.appleHealthAuthorizationRequest ||
                updated.appleHealthAuthorizationIncludesAlcohol != localMeals.appleHealthAuthorizationIncludesAlcohol else { return }
        do { try saveLocalMeals(updated) }
        catch { issue = .storageUnavailable }
    }

    private func exportPendingAppleHealthSamples(requestAuthorization: Bool) async {
        guard access == .owner, localMealsLoaded, let appleHealth else { return }
        guard await appleHealth.isAvailable() else {
            appleHealthWriteAccess = .unavailable
            return
        }
        if requestAuthorization, needsAppleHealthAuthorization {
            await requestAppleHealthAuthorization(using: appleHealth)
        }
        let authorized = await appleHealth.authorizedNutrients()
        appleHealthWriteAccess = .available(authorized)
        guard appleHealthSyncEnabled else { return }
        let mealsByID = appleHealthLoggedMealsByID
        // An eligibility record without a Logged Meal is a pending deletion.
        for (mealID, state) in localMeals.appleHealthMeals {
            let meal = mealsByID[mealID]
            for change in state.pendingChanges(for: meal) {
                guard appleHealthSyncEnabled else { return }
                guard isCurrentAppleHealthMeal(mealID, revision: meal?.revision) else { break }
                guard authorized.contains(change.nutrient) else { continue }

                do {
                    try await reconcileAppleHealthSample(mealID: mealID, meal: meal, change: change,
                                                         using: appleHealth)
                } catch {
                    recordAppleHealthFailure(mealID: mealID, nutrient: change.nutrient)
                }
            }

            if meal == nil, let state = localMeals.appleHealthMeals[mealID],
               !state.outcomes.values.contains(where: \.mayHaveSample) {
                var updated = localMeals
                updated.appleHealthMeals.removeValue(forKey: mealID)
                try? saveLocalMeals(updated)
            }
        }
    }

    private func isCurrentAppleHealthMeal(_ id: UUID, revision: Int?) -> Bool {
        localMeals.loggedMeals.first { $0.id == id }?.revision == revision
    }

    private func reconcileAppleHealthSample(mealID: UUID, meal: LoggedMeal?, change: AppleHealthNutrientChange,
                                            using appleHealth: any AppleHealthClient) async throws {
        let nutrient = change.nutrient
        let sampleRevision: Int?
        if change.previous?.mayHaveSample == true {
            sampleRevision = try await appleHealth.ownSampleRevision(mealID: mealID, nutrient: nutrient)
            guard appleHealthSyncEnabled, isCurrentAppleHealthMeal(mealID, revision: meal?.revision) else { return }
        } else {
            sampleRevision = nil
        }

        var wasRemovedInHealth = sampleRevision == nil && change.previous?.hasConfirmedSample == true
        if sampleRevision == nil, meal != nil, case let .writing(false, attemptedRevision?) = change.previous {
            // The first write may have committed before HealthKit acknowledged it.
            wasRemovedInHealth = try await appleHealth.hasOwnSampleDeletion(mealID: mealID, nutrient: nutrient,
                                                                            revision: attemptedRevision)
            guard appleHealthSyncEnabled, isCurrentAppleHealthMeal(mealID, revision: meal?.revision) else { return }
        }

        let outcome: AppleHealthNutrientOutcome?
        if wasRemovedInHealth {
            outcome = meal == nil ? nil : .suppressed
        } else if let meal, let amount = change.amount {
            if let sampleRevision, sampleRevision >= meal.revision {
                outcome = .written(revision: sampleRevision)
            } else {
                let sample = AppleHealthSample(mealID: meal.id, nutrient: nutrient, amount: amount,
                                               mealTime: meal.record.mealTime.instant, revision: meal.revision)
                try saveAppleHealthOutcome(.writing(replacingSample: sampleRevision != nil, revision: sample.revision),
                                           mealID: mealID, nutrient: nutrient)
                try await appleHealth.save(sample)
                outcome = .written(revision: meal.revision)
            }
        } else {
            var wasAlreadyAbsent = false
            if sampleRevision != nil {
                try saveAppleHealthOutcome(.removing, mealID: mealID, nutrient: nutrient)
                // The sample can be removed in Health between lookup and deletion.
                let deleted = try await appleHealth.deleteOwnSamples(mealID: mealID, nutrient: nutrient)
                wasAlreadyAbsent = !deleted
            }
            outcome = meal.map { wasAlreadyAbsent ? .suppressed : .skipped(revision: $0.revision) }
        }
        // Keep the Health outcome even if the meal changed while the request was in flight.
        // A later pass uses the current meal revision and this outcome together.
        try saveAppleHealthOutcome(outcome, mealID: mealID, nutrient: nutrient)
    }

    private func recordAppleHealthFailure(mealID: UUID, nutrient: Nutrient) {
        guard access == .owner, localMealsLoaded,
              var state = localMeals.appleHealthMeals[mealID],
              state.failedNutrients?.contains(nutrient) != true else { return }
        state.failedNutrients = (state.failedNutrients ?? []).union([nutrient])
        var updated = localMeals
        updated.appleHealthMeals[mealID] = state
        do { try saveLocalMeals(updated) }
        catch {
            // A local storage failure can also prevent recording the failure on disk.
            localMeals.appleHealthMeals[mealID]?.failedNutrients = state.failedNutrients
        }
    }

    private func saveAppleHealthOutcome(_ outcome: AppleHealthNutrientOutcome?, mealID: UUID,
                                        nutrient: Nutrient) throws {
        guard localMeals.appleHealthMeals[mealID] != nil else { return }
        var updated = localMeals
        updated.appleHealthMeals[mealID]?.outcomes[nutrient] = outcome
        switch outcome {
        case .writing, .removing: break
        default: updated.appleHealthMeals[mealID]?.failedNutrients?.remove(nutrient)
        }
        try saveLocalMeals(updated)
    }
}
