import Foundation

public struct SupabaseObservationSyncClient: ObservationSyncClient {
    private let configuration: SupabaseConfiguration
    private let session: URLSession

    public init(configuration: SupabaseConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session ?? SupabaseConfiguration.makeEphemeralSession(requestTimeout: 20, resourceTimeout: 30)
    }

    public func sync(_ change: PendingObservationChange, accessToken: String) async throws -> MealSyncAcknowledgement {
        try await configuration.syncChange(ObservationChangeBody(change), rpc: "bitelens_sync_observation",
                                           accessToken: accessToken, session: session)
    }
}

private struct ObservationChangeBody: Encodable {
    let pObservationId: UUID
    let pUserId: UUID
    let pRevision: Int
    let pObservation: CloudObservation?

    init(_ change: PendingObservationChange) {
        pObservationId = change.id
        pUserId = change.ownerID
        pRevision = change.revision
        switch change {
        case .save(let record, _): pObservation = CloudObservation(record)
        case .delete: pObservation = nil
        }
    }

    private enum CodingKeys: String, CodingKey { case pObservationId, pUserId, pRevision, pObservation }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(pObservationId, forKey: .pObservationId)
        try fields.encode(pUserId, forKey: .pUserId)
        try fields.encode(pRevision, forKey: .pRevision)
        try fields.encode(pObservation, forKey: .pObservation)
    }
}

private struct CloudObservation: Encodable {
    let id: UUID
    let userId: UUID
    let kind: ObservationKind
    let symptomId: Symptom?
    let observedAtEpochSeconds: Double
    let localDate: String
    let timeZone: String
    let level: ObservationSeverity?
    let notes: String?
    let mealId: UUID?

    init(_ record: ObservationRecord) {
        id = record.id
        userId = record.ownerID
        kind = record.kind
        symptomId = record.symptom
        observedAtEpochSeconds = record.time.instant.timeIntervalSince1970
        localDate = record.time.localDate
        timeZone = record.time.timeZoneIdentifier
        level = record.severity
        notes = record.notes
        mealId = record.mealID
    }
}
