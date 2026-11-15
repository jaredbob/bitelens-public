import BiteLensCore
import Foundation
import Testing
#if canImport(HealthKit)
import HealthKit

@Test func catalogContainsExactlyTheIOS18HealthKitSymptomIdentifiers() {
    let expected: Set<HKCategoryTypeIdentifier> = [
        .abdominalCramps, .acne, .appetiteChanges, .bladderIncontinence, .bloating, .breastPain,
        .chestTightnessOrPain, .chills, .constipation, .coughing, .diarrhea, .dizziness, .drySkin,
        .fainting, .fatigue, .fever, .generalizedBodyAche, .hairLoss, .headache, .heartburn, .hotFlashes,
        .lossOfSmell, .lossOfTaste, .lowerBackPain, .memoryLapse, .moodChanges, .nausea, .nightSweats,
        .pelvicPain, .rapidPoundingOrFlutteringHeartbeat, .runnyNose, .shortnessOfBreath, .sinusCongestion,
        .skippedHeartbeat, .sleepChanges, .soreThroat, .vaginalDryness, .vomiting, .wheezing,
    ]
    #expect(Symptom.allCases.count == expected.count)
    #expect(Set(Symptom.allCases.map(\.healthKitIdentifier)) == Set(expected.map(\.rawValue)))
}
#endif

@MainActor @Test func onlyAnObservationFirstSavedWithSharingOnExportsEvenWhenBackdated() async throws {
    let fixture = ObservationHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    #expect(!workflow.appleHealthSymptomSharingEnabled)

    let privateEntry = try workflow.logSymptom(.headache, severity: .mild, notes: "Private")
    #expect(await fixture.health.writeAccessRequests.isEmpty)
    await workflow.setAppleHealthSymptomSharingEnabled(true)
    let expectedRequest = Set(Symptom.allCases)
    #expect(await fixture.health.writeAccessRequests == [expectedRequest])

    let yesterday = fixture.time(ago: 86_400)
    let eligible = try workflow.logSymptom(.headache, time: yesterday, severity: .severe, notes: "After lunch")
    await workflow.syncPendingObservationAppleHealthChanges()

    let sample = try #require(await fixture.health.samples.first)
    #expect(await fixture.health.samples.count == 1)
    #expect(await fixture.health.writeAccessRequests == [expectedRequest])
    #expect(sample.observationID == eligible.id)
    #expect(sample.category == .headache)
    #expect(sample.instant == yesterday.instant)
    #expect(sample.value == 4)
    #expect(sample.revision == 1)
    #expect(sample.syncIdentifier == "bitelens.observation.\(eligible.id.uuidString.lowercased())")
    #expect(workflow.loggedObservations.contains(privateEntry))
}

@MainActor @Test func denialForOneCategoryKeepsOtherExportsAndResumesWhenAccessReturns() async throws {
    let fixture = ObservationHealthFixture()
    defer { fixture.remove() }
    await fixture.health.denyRequests(for: .headache)
    let workflow = fixture.open()
    await workflow.setAppleHealthSymptomSharingEnabled(true)

    let headache = try workflow.logSymptom(.headache)
    await workflow.syncPendingObservationAppleHealthChanges()
    let nausea = try workflow.logSymptom(.nausea, severity: .mild)
    await workflow.syncPendingObservationAppleHealthChanges()
    #expect(await fixture.health.samples.map(\.observationID) == [nausea.id])
    #expect(await fixture.health.writeAccessRequests == [Set(Symptom.allCases)])

    let reopened = fixture.open()
    await reopened.syncPendingObservationAppleHealthChanges()
    #expect(Set(reopened.loggedObservations.map(\.id)) == [headache.id, nausea.id])
    #expect(await fixture.health.writeAccessRequests == [Set(Symptom.allCases)])
    await fixture.health.setWriteAccess(.authorized, for: .headache)
    reopened.resumeLocalWork()
    await reopened.syncPendingObservationAppleHealthChanges()
    #expect(Set(await fixture.health.samples.map(\.observationID)) == [headache.id, nausea.id])
}

@MainActor @Test func valueFamiliesExportWithoutPrivateObservationDetails() async throws {
    let fixture = ObservationHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    await workflow.setAppleHealthSymptomSharingEnabled(true)
    #expect(!workflow.appleHealthSyncEnabled)

    let headache = try workflow.logSymptom(.headache, severity: .moderate)
    let mood = try workflow.logSymptom(.moodChanges, severity: .severe)
    let sleep = try workflow.logSymptom(.sleepChanges, severity: .moderate)
    let appetite = try workflow.logSymptom(.appetiteChanges, severity: .severe)
    let draft = try workflow.captureMeal(photoData: Data([1]))
    try workflow.updateDraftItems(draft.id, items: [MealItem(name: "Soup")])
    let meal = try workflow.confirmMeal(draft.id)
    let urgeTime = fixture.time(ago: 600)
    let urge = try workflow.logUrge(time: urgeTime, intensity: .severe, notes: "Private details", mealID: meal.id)
    await workflow.syncPendingObservationAppleHealthChanges()

    let samples = await fixture.health.samples
    #expect(samples.count == 5)
    let byID = Dictionary(uniqueKeysWithValues: samples.map { ($0.observationID, $0) })
    #expect(byID[headache.id]?.value == 3)
    #expect(byID[mood.id]?.value == 0)
    #expect(byID[sleep.id]?.value == 0)
    #expect(byID[appetite.id]?.value == 0)
    let urgeSample = try #require(byID[urge.id])
    #expect(urgeSample.category == .appetiteChanges)
    #expect(urgeSample.value == 3)
    #expect(urgeSample.instant == urgeTime.instant)
    let payload = try JSONEncoder().encode(urgeSample)
    let fields = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    #expect(Set(fields.keys) == ["observationID", "category", "value", "instant", "revision"])

    try workflow.updateObservation(urge.id, time: urgeTime, severity: .mild, notes: "Updated private details")
    try workflow.deleteLoggedMeal(meal.id)
    await workflow.syncPendingObservationAppleHealthChanges()
    #expect(workflow.loggedObservations.first { $0.id == urge.id }?.record.mealID == nil)
    #expect(await fixture.health.samples.first { $0.observationID == urge.id } == urgeSample)
}

@MainActor @Test(arguments: [true, false])
func changingALinkWhileAppleHealthChecksAccessStillExportsTheUrge(deletingMeal: Bool) async throws {
    let fixture = ObservationHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    await workflow.setAppleHealthSymptomSharingEnabled(true)
    await fixture.health.pauseNextWriteAccess()
    let urge: LoggedObservation
    let mealID: UUID
    if deletingMeal {
        let draft = try workflow.startManualDraft()
        try workflow.updateDraftItems(draft.id, items: [MealItem(name: "Soup")])
        mealID = try workflow.confirmMeal(draft.id).id
        urge = try workflow.logUrge(mealID: mealID)
    } else {
        urge = try workflow.logUrge()
        let draft = try workflow.startManualDraft(linkingUrgeID: urge.id)
        try workflow.updateDraftItems(draft.id, items: [MealItem(name: "Soup")])
        mealID = draft.id
    }
    await fixture.health.waitForPausedWriteAccess()

    // Join the in-flight pass before allowing it to continue, without scheduling a manual retry.
    do {
        defer { Task { await fixture.health.resumeWriteAccess() } }
        if deletingMeal { try workflow.deleteLoggedMeal(mealID) }
        else { try workflow.confirmMeal(mealID) }
    }
    await workflow.syncPendingObservationAppleHealthChanges()

    #expect(workflow.loggedObservations.first?.record.mealID == (deletingMeal ? nil : mealID))
    #expect(await fixture.health.samples.map(\.observationID) == [urge.id])
}

@MainActor @Test func pausedEditsAndDeletionsReconcileAfterRestartAndOptingBackIn() async throws {
    let fixture = ObservationHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    await workflow.setAppleHealthSymptomSharingEnabled(true)
    let edited = try workflow.logSymptom(.headache)
    let deleted = try workflow.logUrge()
    await workflow.syncPendingObservationAppleHealthChanges()
    let before = await fixture.health.samples
    #expect(before.count == 2)

    await workflow.setAppleHealthSymptomSharingEnabled(false)
    let newTime = fixture.time(ago: 600)
    try workflow.updateObservation(edited.id, time: newTime, severity: .mild, notes: nil)
    try workflow.deleteObservation(deleted.id)
    await workflow.syncPendingObservationAppleHealthChanges()
    let reopened = fixture.open()
    #expect(!reopened.appleHealthSymptomSharingEnabled)
    #expect(await fixture.health.samples == before)

    await reopened.setAppleHealthSymptomSharingEnabled(true)
    let samples = await fixture.health.samples
    #expect(samples.count == 1)
    let remaining = try #require(samples.first)
    #expect(remaining.observationID == edited.id)
    #expect(remaining.instant == newTime.instant)
    #expect(remaining.revision == 2)
    #expect(remaining.value == 2)
}

@MainActor @Test(arguments: [true, false])
func deletingFromHealthSuppressesRecreationEvenAfterAnEdit(losesFirstAcknowledgment: Bool) async throws {
    let fixture = ObservationHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    await workflow.setAppleHealthSymptomSharingEnabled(true)
    if losesFirstAcknowledgment { await fixture.health.loseNextSaveResponse() }
    let observation = try workflow.logSymptom(.headache)
    await workflow.syncPendingObservationAppleHealthChanges()
    #expect(await fixture.health.samples.count == 1)

    await fixture.health.removeFromHealth(observation.id)
    let reopened = fixture.open()
    try reopened.updateObservation(observation.id, time: fixture.time(ago: 300), severity: .severe, notes: nil)
    await reopened.syncPendingObservationAppleHealthChanges()
    #expect(await fixture.health.samples.isEmpty)
    #expect(reopened.loggedObservations.first?.record.severity == .severe)
    let reopenedAgain = fixture.open()
    try reopenedAgain.updateObservation(observation.id, time: fixture.time(ago: 120), severity: .mild, notes: nil)
    await reopenedAgain.syncPendingObservationAppleHealthChanges()
    #expect(await fixture.health.samples.isEmpty)
}

@MainActor @Test func interruptedWritesConvergeOnOneSampleAndInterruptedDeletionStaysDeleted() async throws {
    let fixture = ObservationHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    await workflow.setAppleHealthSymptomSharingEnabled(true)
    await fixture.health.loseNextSaveResponse()
    let observation = try workflow.logUrge()
    await workflow.syncPendingObservationAppleHealthChanges()
    let first = try #require(await fixture.health.samples.first)

    let reopened = fixture.open()
    await reopened.syncPendingObservationAppleHealthChanges()
    #expect(await fixture.health.samples == [first])
    #expect(await fixture.health.saveAttempts == [first])

    await fixture.health.loseNextDeleteResponse()
    try reopened.deleteObservation(observation.id)
    await reopened.syncPendingObservationAppleHealthChanges()
    let reopenedAgain = fixture.open()
    await reopenedAgain.syncPendingObservationAppleHealthChanges()
    #expect(await fixture.health.samples.isEmpty)
    #expect(reopenedAgain.loggedObservations.isEmpty)
}

private struct ObservationHealthFixture {
    let health = TestObservationHealthClient()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let identity = ObservationHealthTestIdentity()

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    func time(ago seconds: TimeInterval) -> MealTime {
        MealTime(instant: Self.now.addingTimeInterval(-seconds), timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    @MainActor func open() -> MealWorkflow {
        let workflow = MealWorkflow(auth: identity, sessionStore: identity, preferences: identity,
                                    approvedOwnerID: identity.ownerID, now: { Self.now },
                                    draftStorage: LocalMealDraftStorage(directory: directory),
                                    observationAppleHealth: health)
        workflow.restoreSession()
        return workflow
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private actor TestObservationHealthClient: ObservationAppleHealthClient {
    private(set) var writeAccessRequests: [Set<Symptom>] = []
    private(set) var samples: [ObservationAppleHealthSample] = []
    private var access: [Symptom: ObservationAppleHealthWriteAccess] = [:]
    private var deniedRequests = Set<Symptom>()
    private var deletedSamples: [ObservationAppleHealthSample] = []
    private var losesSaveResponse = false
    private var losesDeleteResponse = false
    private(set) var saveAttempts: [ObservationAppleHealthSample] = []
    private var pausesWriteAccess = false
    private var pausedWriteAccess: CheckedContinuation<Void, Never>?
    private var writeAccessWaiter: CheckedContinuation<Void, Never>?

    private struct LostResponse: Error {}

    func denyRequests(for category: Symptom) { deniedRequests.insert(category) }
    func setWriteAccess(_ status: ObservationAppleHealthWriteAccess, for category: Symptom) { access[category] = status }
    func loseNextSaveResponse() { losesSaveResponse = true }
    func loseNextDeleteResponse() { losesDeleteResponse = true }

    func pauseNextWriteAccess() { pausesWriteAccess = true }

    func waitForPausedWriteAccess() async {
        if pausedWriteAccess != nil { return }
        await withCheckedContinuation { writeAccessWaiter = $0 }
    }

    func resumeWriteAccess() {
        let paused = pausedWriteAccess
        pausedWriteAccess = nil
        paused?.resume()
    }

    func removeFromHealth(_ id: UUID) {
        deletedSamples.append(contentsOf: samples.filter { $0.observationID == id })
        samples.removeAll { $0.observationID == id }
    }

    func isAvailable() async -> Bool { true }

    func writeAccess(for category: Symptom) async -> ObservationAppleHealthWriteAccess {
        if pausesWriteAccess {
            pausesWriteAccess = false
            await withCheckedContinuation { continuation in
                pausedWriteAccess = continuation
                writeAccessWaiter?.resume()
                writeAccessWaiter = nil
            }
        }
        return access[category] ?? .notDetermined
    }

    func requestWriteAccess(for categories: Set<Symptom>) async throws {
        writeAccessRequests.append(categories)
        for category in categories where access[category] == nil || access[category] == .notDetermined {
            access[category] = deniedRequests.contains(category) ? .denied : .authorized
        }
    }

    func save(_ sample: ObservationAppleHealthSample) async throws {
        saveAttempts.append(sample)
        if samples.contains(where: { $0.syncIdentifier == sample.syncIdentifier && $0.revision >= sample.revision }) { return }
        samples.removeAll { $0.syncIdentifier == sample.syncIdentifier }
        samples.append(sample)
        if losesSaveResponse {
            losesSaveResponse = false
            throw LostResponse()
        }
    }

    func ownSampleRevision(observationID: UUID, category: Symptom) async throws -> Int? {
        samples.first { $0.observationID == observationID && $0.category == category }?.revision
    }

    func hasOwnSampleDeletion(observationID: UUID, category: Symptom, revision: Int) async throws -> Bool {
        deletedSamples.contains { $0.observationID == observationID && $0.category == category && $0.revision == revision }
    }

    func deleteOwnSamples(observationID: UUID, category: Symptom) async throws {
        removeFromHealth(observationID)
        if losesDeleteResponse {
            losesDeleteResponse = false
            throw LostResponse()
        }
    }
}

private struct ObservationHealthTestIdentity: AuthenticationClient, SessionStore, ProviderPreferences {
    let ownerID = UUID()

    func signIn(email: String, password: String) async throws -> AuthSession { throw AuthenticationFailure.unavailable }
    func refresh(refreshToken: String) async throws -> AuthSession { throw AuthenticationFailure.unavailable }
    func signOut(accessToken: String) async throws {}
    func load() throws -> AuthSession? {
        AuthSession(userID: ownerID, accessToken: "offline", refreshToken: "offline", expiresAt: .distantPast)
    }
    func save(_ session: AuthSession) throws {}
    func clear() throws {}
    func loadProvider() -> AIProvider? { nil }
    func saveProvider(_ provider: AIProvider) {}
}
