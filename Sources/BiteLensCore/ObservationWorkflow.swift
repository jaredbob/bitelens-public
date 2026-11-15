import Foundation

public enum ObservationKind: String, Codable, Sendable {
    case symptom
    case urge = "bingeEatingUrge"
}

/// A choice in the Log symptom picker.
public enum ObservationType: Hashable, Sendable {
    case symptom(Symptom)
    case bingeEatingUrge

    public var displayName: String {
        switch self {
        case .symptom(let symptom): symptom.displayName
        case .bingeEatingUrge: "Binge Eating Urge"
        }
    }

    public var symbol: String {
        switch self {
        case .symptom(let symptom): symptom.symbol
        case .bingeEatingUrge: "waveform.path"
        }
    }
}

public enum ObservationSeverity: String, CaseIterable, Codable, Sendable {
    case mild, moderate, severe
}

public struct ObservationRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let ownerID: UUID
    public let kind: ObservationKind
    public let symptom: Symptom?
    public internal(set) var time: MealTime
    public internal(set) var severity: ObservationSeverity?
    public internal(set) var notes: String?
    public internal(set) var mealID: UUID?
    public var type: ObservationType { symptom.map(ObservationType.symptom) ?? .bingeEatingUrge }
}

public struct LoggedObservation: Codable, Equatable, Sendable, Identifiable {
    public let record: ObservationRecord
    public let revision: Int
    public let appleHealthEligible: Bool
    public var id: UUID { record.id }
}

public enum ObservationIssue: Error, Equatable, Sendable {
    case futureTime
    case notFound
    case mealNotFound
    case urgeRequired
    case storageUnavailable
}

public protocol ObservationSyncClient: Sendable {
    func sync(_ change: PendingObservationChange, accessToken: String) async throws -> MealSyncAcknowledgement
}

public enum PendingObservationChange: Codable, Equatable, Sendable, Identifiable {
    case save(ObservationRecord, revision: Int)
    case delete(id: UUID, ownerID: UUID, revision: Int)

    public var id: UUID {
        switch self {
        case .save(let record, _): record.id
        case .delete(let id, _, _): id
        }
    }

    public var ownerID: UUID {
        switch self {
        case .save(let record, _): record.ownerID
        case .delete(_, let ownerID, _): ownerID
        }
    }

    public var revision: Int {
        switch self {
        case .save(_, let revision), .delete(_, _, let revision): revision
        }
    }
}

extension MealWorkflow {
    public var loggedObservations: [LoggedObservation] {
        guard access == .owner else { return [] }
        return localMeals.loggedObservations.filter { $0.record.ownerID == activeAccountID }.sorted {
            if $0.record.time.instant == $1.record.time.instant {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.record.time.instant > $1.record.time.instant
        }
    }

    public var pendingObservationChanges: [PendingObservationChange] {
        guard access == .owner else { return [] }
        return localMeals.pendingObservationChanges.filter { $0.ownerID == activeAccountID }
    }

    public func searchObservationTypes(_ query: String) -> [ObservationType] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let recent: [ObservationType]
        if access == .owner {
            recent = localMeals.loggedObservations.reversed()
                .filter { $0.record.ownerID == activeAccountID }
                .map(\.record.type)
        } else {
            recent = []
        }
        let catalog = (Symptom.allCases.map(ObservationType.symptom) + [.bingeEatingUrge]).sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        var seen = Set<ObservationType>()
        return (recent + catalog).filter {
            (term.isEmpty || $0.displayName.localizedStandardContains(term)) && seen.insert($0).inserted
        }
    }

    @discardableResult public func logSymptom(_ symptom: Symptom, time: MealTime? = nil,
                                              severity: ObservationSeverity? = nil, notes: String? = nil) throws -> LoggedObservation {
        try logObservation(kind: .symptom, symptom: symptom, time: time, severity: severity, notes: notes, mealID: nil)
    }

    @discardableResult public func logUrge(time: MealTime? = nil, intensity: ObservationSeverity? = nil,
                                           notes: String? = nil, mealID: UUID? = nil) throws -> LoggedObservation {
        try logObservation(kind: .urge, symptom: nil, time: time, severity: intensity, notes: notes, mealID: mealID)
    }

    private func logObservation(kind: ObservationKind, symptom: Symptom?, time: MealTime?, severity: ObservationSeverity?,
                                notes: String?, mealID: UUID?) throws -> LoggedObservation {
        guard let ownerID = activeAccountID else { throw WorkflowIssue.accessDenied }
        try validateObservationMealLink(mealID)
        let currentTime = now()
        let time = time ?? MealTime(instant: currentTime, timeZone: .current)
        guard time.instant <= currentTime else { throw ObservationIssue.futureTime }
        let record = ObservationRecord(id: UUID(), ownerID: ownerID, kind: kind, symptom: symptom,
                                       time: time, severity: severity, notes: notes, mealID: mealID)
        let observation = LoggedObservation(record: record, revision: 1,
                                            appleHealthEligible: appleHealthSymptomSharingEnabled)
        var updated = localMeals
        updated.loggedObservations.append(observation)
        updated.observationAppleHealth.register(observation)
        updated.enqueueObservationChange(.save(record, revision: observation.revision))
        try saveObservationLibrary(updated)
        return observation
    }

    @discardableResult public func updateObservation(_ id: UUID, time: MealTime, severity: ObservationSeverity?,
                                                     notes: String?) throws -> LoggedObservation {
        let index = try observationIndex(for: id)
        guard time.instant <= now() else { throw ObservationIssue.futureTime }
        var record = localMeals.loggedObservations[index].record
        record.time = time
        record.severity = severity
        record.notes = notes
        guard record != localMeals.loggedObservations[index].record else { return localMeals.loggedObservations[index] }
        var updated = localMeals
        let observation = updated.replaceObservation(at: index, with: record)
        try saveObservationLibrary(updated)
        return observation
    }

    @discardableResult public func linkUrge(_ id: UUID, to mealID: UUID?) throws -> LoggedObservation {
        let index = try urgeIndex(for: id)
        try validateObservationMealLink(mealID)
        let previous = localMeals.loggedObservations[index]
        guard previous.record.mealID != mealID else { return previous }
        var updated = localMeals
        let observation = updated.setUrgeMealLink(at: index, to: mealID)
        try saveObservationLibrary(updated)
        return observation
    }

    func urgeIndex(for id: UUID) throws -> Int {
        let index = try observationIndex(for: id)
        guard localMeals.loggedObservations[index].record.kind == .urge else { throw ObservationIssue.urgeRequired }
        return index
    }

    public func deleteObservation(_ id: UUID) throws {
        let index = try observationIndex(for: id)
        var updated = localMeals
        let observation = updated.loggedObservations.remove(at: index)
        for index in updated.drafts.indices where updated.drafts[index].linkingUrgeID == id {
            updated.drafts[index].linkingUrgeID = nil
        }
        // A previous revision may already have committed even if it was never acknowledged.
        updated.enqueueObservationChange(.delete(id: id, ownerID: observation.record.ownerID, revision: observation.revision + 1))
        try saveObservationLibrary(updated)
    }

    private func observationIndex(for id: UUID) throws -> Int {
        guard access == .owner else { throw WorkflowIssue.accessDenied }
        guard let index = localMeals.loggedObservations.firstIndex(where: { $0.id == id && $0.record.ownerID == activeAccountID })
        else { throw ObservationIssue.notFound }
        return index
    }

    private func validateObservationMealLink(_ mealID: UUID?) throws {
        if let mealID, !localMeals.loggedMeals.contains(where: { $0.id == mealID && $0.record.ownerID == activeAccountID }) {
            throw ObservationIssue.mealNotFound
        }
    }

    private func saveObservationLibrary(_ updated: LocalMealLibrary) throws {
        do { try saveLocalMeals(updated) }
        catch DraftIssue.storageUnavailable { throw ObservationIssue.storageUnavailable }
        scheduleObservationAppleHealthSync()
    }
}

extension LocalMealLibrary {
    @discardableResult mutating func setUrgeMealLink(at index: Int, to mealID: UUID?) -> LoggedObservation {
        var record = loggedObservations[index].record
        record.mealID = mealID
        return replaceObservation(at: index, with: record)
    }

    @discardableResult mutating func replaceObservation(at index: Int, with record: ObservationRecord) -> LoggedObservation {
        let previous = loggedObservations[index]
        let updated = LoggedObservation(record: record, revision: previous.revision + 1,
                                        appleHealthEligible: previous.appleHealthEligible)
        loggedObservations[index] = updated
        enqueueObservationChange(.save(record, revision: updated.revision))
        return updated
    }

    mutating func enqueueObservationChange(_ change: PendingObservationChange) {
        pendingObservationChanges.removeAll { $0.id == change.id }
        pendingObservationChanges.append(change)
    }
}
