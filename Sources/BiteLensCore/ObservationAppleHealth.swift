import Foundation

public enum ObservationAppleHealthWriteAccess: Sendable {
    case notDetermined
    case denied
    case authorized
}

public protocol ObservationAppleHealthClient: Sendable {
    func isAvailable() async -> Bool
    func writeAccess(for category: Symptom) async -> ObservationAppleHealthWriteAccess
    func requestWriteAccess(for categories: Set<Symptom>) async throws
    func save(_ sample: ObservationAppleHealthSample) async throws
    func ownSampleRevision(observationID: UUID, category: Symptom) async throws -> Int?
    func hasOwnSampleDeletion(observationID: UUID, category: Symptom, revision: Int) async throws -> Bool
    func deleteOwnSamples(observationID: UUID, category: Symptom) async throws
}

public struct ObservationAppleHealthSample: Codable, Equatable, Sendable {
    public let observationID: UUID
    public let category: Symptom
    public let instant: Date
    public let value: Int
    public let revision: Int

    public var syncIdentifier: String { Self.syncIdentifier(observationID: observationID) }

    public static func syncIdentifier(observationID: UUID) -> String {
        "bitelens.observation.\(observationID.uuidString.lowercased())"
    }

    fileprivate init?(_ observation: LoggedObservation) {
        guard observation.appleHealthEligible else { return nil }
        observationID = observation.id
        instant = observation.record.time.instant
        revision = observation.revision
        switch observation.record.kind {
        case .urge:
            category = .appetiteChanges
            value = 3 // HKCategoryValueAppetiteChanges.increased
        case .symptom:
            guard let symptom = observation.record.symptom else { return nil }
            category = symptom
            switch symptom.valueFamily {
            case .presence: value = 0 // HKCategoryValuePresence.present
            case .appetite: value = 0 // HKCategoryValueAppetiteChanges.unspecified
            case .severity:
                // HKCategoryValueSeverity. Raw value 1 denotes Not Present.
                switch observation.record.severity {
                case nil: value = 0
                case .mild: value = 2
                case .moderate: value = 3
                case .severe: value = 4
                }
            }
        }
    }

    fileprivate func hasSameValue(as other: Self) -> Bool {
        instant == other.instant && value == other.value
    }
}

/// Eligibility and HealthKit acknowledgments are committed alongside local observations.
struct ObservationAppleHealthState: Codable {
    var entries: [UUID: Entry] = [:]
    var authorizationPending: Bool?

    struct Entry: Codable {
        let category: Symptom
        var outcome: Outcome = .pending

        enum Outcome: Codable {
            case pending
            case writing(ObservationAppleHealthSample, replacing: Bool)
            case written(ObservationAppleHealthSample)
            case suppressed
        }

        func needsSync(for sample: ObservationAppleHealthSample?) -> Bool {
            switch outcome {
            case .pending: true
            case .writing: true
            case .written(let previous): sample.map { !$0.hasSameValue(as: previous) } ?? true
            case .suppressed: sample == nil
            }
        }
    }

    mutating func register(_ observation: LoggedObservation) {
        guard let sample = ObservationAppleHealthSample(observation) else { return }
        entries[observation.id] = Entry(category: sample.category)
    }
}

extension MealWorkflow {
    public var appleHealthSymptomSharingEnabled: Bool {
        appleHealthConnectionStatus == .connected && localMeals.appleHealthSymptomSharingEnabled
    }

    public func setAppleHealthSymptomSharingEnabled(_ enabled: Bool) async {
        let wasReadyToConnect = appleHealthConnectionStatus == .readyToConnect
        guard enabled != appleHealthSymptomSharingEnabled,
              (!isBeta || observationAppleHealth != nil), prepareAppleHealthOptIn(enabled) else { return }
        var updated = localMeals
        updated.appleHealthSymptomSharingEnabled = enabled
        updated.observationAppleHealth.authorizationPending = enabled ? true : nil
        do { try saveLocalMeals(updated) }
        catch {
            issue = .storageUnavailable
            return
        }
        guard enabled else { return }
        if wasReadyToConnect { scheduleAppleHealthSync() }
        scheduleObservationAppleHealthSync()
        await observationAppleHealthTask?.value
    }

    public func syncPendingObservationAppleHealthChanges() async {
        if observationAppleHealthTask == nil { scheduleObservationAppleHealthSync() }
        await observationAppleHealthTask?.value
    }

    func scheduleObservationAppleHealthSync() {
        guard appleHealthSymptomSharingEnabled, let observationAppleHealth else { return }
        needsObservationAppleHealthPass = true
        guard observationAppleHealthTask == nil else { return }
        observationAppleHealthTask = Task {
            while needsObservationAppleHealthPass {
                needsObservationAppleHealthPass = false
                await exportPendingObservations(using: observationAppleHealth, activation: accountActivationID)
            }
            observationAppleHealthTask = nil
        }
    }

    private func exportPendingObservations(using client: any ObservationAppleHealthClient, activation: UUID) async {
        guard appleHealthSymptomSharingEnabled, await client.isAvailable() else { return }
        guard isAppleHealthActivationCurrent(activation), appleHealthSymptomSharingEnabled else { return }
        if localMeals.observationAppleHealth.authorizationPending == true {
            do {
                try await client.requestWriteAccess(for: Set(Symptom.allCases))
                guard isAppleHealthActivationCurrent(activation), appleHealthSymptomSharingEnabled else { return }
                var updated = localMeals
                updated.observationAppleHealth.authorizationPending = nil
                try saveLocalMeals(updated)
            } catch {
                // Keep the request pending. Existing write grants can still be used.
            }
        }
        guard isAppleHealthActivationCurrent(activation), appleHealthSymptomSharingEnabled else { return }
        let observations = localMeals.loggedObservations.filter { $0.record.ownerID == activeAccountID }
        let byID = Dictionary(uniqueKeysWithValues: observations.map { ($0.id, $0) })
        for (id, entry) in localMeals.observationAppleHealth.entries {
            let observation = byID[id]
            let sample = observation.flatMap(ObservationAppleHealthSample.init)
            guard isAppleHealthActivationCurrent(activation) else { return }
            guard entry.needsSync(for: sample),
                  isCurrentHealthObservation(id, revision: observation?.revision, activation: activation) else { continue }
            do {
                if sample == nil {
                    switch entry.outcome {
                    case .pending, .suppressed:
                        try saveObservationHealthOutcome(nil, id: id)
                        continue
                    case .writing, .written: break
                    }
                }

                let access = await client.writeAccess(for: entry.category)
                guard isAppleHealthActivationCurrent(activation) else { return }
                guard access == .authorized,
                      isCurrentHealthObservation(id, revision: observation?.revision, activation: activation) else { continue }
                try await reconcileObservationHealthSample(sample, id: id, entry: entry,
                                                           using: client, activation: activation)
            } catch {
                // The durable outcome stays pending for the next pass. Work on other
                // categories can continue when this category is unavailable.
                continue
            }
        }
    }

    private func isCurrentHealthObservation(_ id: UUID, revision: Int?, activation: UUID) -> Bool {
        isAppleHealthActivationCurrent(activation) && appleHealthSymptomSharingEnabled &&
            localMeals.loggedObservations.first { $0.id == id && $0.record.ownerID == activeAccountID }?.revision == revision
    }

    private func reconcileObservationHealthSample(_ sample: ObservationAppleHealthSample?, id: UUID,
                                                  entry: ObservationAppleHealthState.Entry,
                                                  using client: any ObservationAppleHealthClient,
                                                  activation: UUID) async throws {
        let storedRevision: Int?
        switch entry.outcome {
        case .writing, .written:
            storedRevision = try await client.ownSampleRevision(observationID: id, category: entry.category)
            guard isCurrentHealthObservation(id, revision: sample?.revision, activation: activation) else { return }
        case .pending, .suppressed:
            storedRevision = nil
        }

        guard let sample else {
            if storedRevision != nil {
                try await client.deleteOwnSamples(observationID: id, category: entry.category)
            }
            guard isAppleHealthActivationCurrent(activation) else { return }
            try saveObservationHealthOutcome(nil, id: id)
            return
        }

        switch entry.outcome {
        case .written where storedRevision == nil, .writing(_, replacing: true) where storedRevision == nil:
            try saveObservationHealthOutcome(.suppressed, id: id)
            return
        case .writing(let attempted, replacing: false) where storedRevision == nil:
            // A first write can commit before its acknowledgment reaches the app.
            let wasDeleted = try await client.hasOwnSampleDeletion(observationID: id, category: entry.category,
                                                                   revision: attempted.revision)
            guard isCurrentHealthObservation(id, revision: sample.revision, activation: activation) else { return }
            if wasDeleted {
                try saveObservationHealthOutcome(.suppressed, id: id)
                return
            }
        case .writing(let attempted, _) where storedRevision == attempted.revision && attempted.hasSameValue(as: sample):
            try saveObservationHealthOutcome(.written(attempted), id: id)
            return
        default: break
        }

        try saveObservationHealthOutcome(.writing(sample, replacing: storedRevision != nil), id: id)
        try await client.save(sample)
        // An edit or deletion during the write is reconciled against this acknowledgment
        // in the next pass, even when sharing was turned off during the write.
        guard isAppleHealthActivationCurrent(activation) else { return }
        try saveObservationHealthOutcome(.written(sample), id: id)
    }

    private func saveObservationHealthOutcome(_ outcome: ObservationAppleHealthState.Entry.Outcome?, id: UUID) throws {
        guard localMeals.observationAppleHealth.entries[id] != nil else { return }
        var updated = localMeals
        if let outcome { updated.observationAppleHealth.entries[id]?.outcome = outcome }
        else { updated.observationAppleHealth.entries.removeValue(forKey: id) }
        try saveLocalMeals(updated)
    }
}
