import BiteLensCore
import Foundation
import Testing

@MainActor @Test func optingInExportsOnlyConfirmedCaloriesAtTheRecordedMealTime() async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    #expect(!workflow.appleHealthSyncEnabled)

    let olderMeal = try fixture.draft(in: workflow)
    try workflow.confirmMeal(olderMeal.id)
    await workflow.setAppleHealthSyncEnabled(true)
    #expect(workflow.appleHealthSyncEnabled)

    let yesterday = fixture.now.addingTimeInterval(-86_400)
    let draft = try fixture.draft(in: workflow, capturedAt: yesterday)
    await workflow.syncPendingAppleHealthChanges()
    #expect(await fixture.health.samples.isEmpty)

    let logged = try workflow.confirmMeal(draft.id)
    let sample = try #require(await fixture.health.waitForFirstSample())
    await workflow.syncPendingAppleHealthChanges()
    #expect(await fixture.health.samples.count == 1)
    #expect(sample.mealID == logged.id)
    #expect(sample.nutrient == .calories)
    #expect(sample.amount == 275)
    #expect(sample.unit == "kcal")
    #expect(sample.mealTime == yesterday)
    #expect(sample.revision == 1)
    #expect(Set(workflow.pendingMealChanges.map(\.id)) == [olderMeal.id, logged.id])
}

@MainActor @Test func confirmingExportsEightCompleteTotalsAtTheRecordedMealTime() async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    await workflow.setAppleHealthSyncEnabled(true)
    #expect(await fixture.health.requestedNutrients == [
        .calories, .protein, .carbohydrates, .fat, .fiber, .sodium, .caffeine, .alcohol,
    ])

    let draft = try fixture.draft(in: workflow, items: [
        MealItem(name: "Soup", nutrients: NutrientAmounts(
            caloriesKcal: 225, proteinGrams: 16, carbohydratesGrams: 20, fatGrams: 9,
            fiberGrams: 3, sodiumMilligrams: 410, alcoholGrams: 21, caffeineMilligrams: 0, addedSugarGrams: 2
        )),
        MealItem(name: "Iced tea", nutrients: NutrientAmounts(
            caloriesKcal: 50, proteinGrams: 0, carbohydratesGrams: 12, fatGrams: 0,
            fiberGrams: 0, sodiumMilligrams: 10, alcoholGrams: 0, caffeineMilligrams: 35, addedSugarGrams: 12
        )),
    ])
    let yesterday = fixture.now.addingTimeInterval(-86_400)
    try workflow.setMealTime(draft.id, instant: yesterday, timeZone: TimeZone(secondsFromGMT: 0)!)
    try workflow.updateDraftNotes(draft.id, notes: "Lunch with a friend")
    await fixture.health.loseNextSaveResponse()
    try workflow.confirmMeal(draft.id)
    await workflow.syncPendingAppleHealthChanges()

    let samples = await fixture.health.samples
    let byNutrient = Dictionary(grouping: samples, by: \.nutrient)
    #expect(byNutrient.mapValues { $0.map(\.amount) } == [
        .calories: [275], .protein: [16], .carbohydrates: [32], .fat: [9], .fiber: [3],
        .sodium: [420], .caffeine: [35], .alcohol: [1.5],
    ])
    #expect(byNutrient.mapValues { $0.map(\.unit) } == [
        .calories: ["kcal"], .protein: ["g"], .carbohydrates: ["g"], .fat: ["g"], .fiber: ["g"],
        .sodium: ["mg"], .caffeine: ["mg"], .alcohol: ["count"],
    ])
    #expect(samples.allSatisfy { $0.mealID == draft.id && $0.mealTime == yesterday && $0.revision == 1 })
    #expect(Set(samples.map(\.syncIdentifier)).count == 8)

    let reopened = fixture.open()
    reopened.restoreSession()
    await reopened.syncPendingAppleHealthChanges()
    #expect(await fixture.health.samples == samples)
}

@MainActor @Test func confirmingExportsOnlyAuthorizedCompleteTotalsIncludingZero() async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    await fixture.health.setWriteAccess([.calories, .protein, .sodium])
    let workflow = fixture.open()
    workflow.restoreSession()
    await workflow.setAppleHealthSyncEnabled(true)

    let draft = try fixture.draft(in: workflow, items: [
        MealItem(name: "Oatmeal", nutrients: NutrientAmounts(
            caloriesKcal: 150, proteinGrams: 5, sodiumMilligrams: 0, caffeineMilligrams: 0
        )),
        MealItem(name: "Tea", nutrients: NutrientAmounts(
            caloriesKcal: 5, sodiumMilligrams: 0, caffeineMilligrams: 40
        )),
    ])
    try workflow.confirmMeal(draft.id)
    await workflow.syncPendingAppleHealthChanges()

    let samples = await fixture.health.samples
    #expect(Dictionary(grouping: samples, by: \.nutrient).mapValues { $0.map(\.amount) } == [
        .calories: [155], .sodium: [0],
    ])
}

@MainActor @Test func anIncompleteCalorieTotalDoesNotHideTheDifferenceBetweenUnknownAndZero() async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    await workflow.setAppleHealthSyncEnabled(true)

    let incomplete = try fixture.draft(in: workflow, items: [
        MealItem(name: "Soup", nutrients: NutrientAmounts(caloriesKcal: 225)),
        MealItem(name: "Bread"),
    ])
    try workflow.confirmMeal(incomplete.id)
    await workflow.syncPendingAppleHealthChanges()
    #expect(await fixture.health.samples.isEmpty)

    let zero = try fixture.draft(in: workflow, items: [
        MealItem(name: "Tea", nutrients: NutrientAmounts(caloriesKcal: 0)),
    ])
    try workflow.confirmMeal(zero.id)
    await workflow.syncPendingAppleHealthChanges()
    let sample = try #require(await fixture.health.samples.first)
    #expect(sample.mealID == zero.id)
    #expect(sample.amount == 0)
}

@MainActor @Test(arguments: [true, false])
func healthWorkRetriesOnRelaunchAfterCloudAcknowledgment(healthWasAvailable: Bool) async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    await fixture.health.setAvailable(healthWasAvailable)
    await fixture.health.setWriteAccess([])

    let workflow = fixture.open(mealSync: AcknowledgingAppleHealthTestCloud())
    workflow.restoreSession()
    await workflow.setAppleHealthSyncEnabled(true)
    let draft = try fixture.draft(in: workflow)
    let logged = try workflow.confirmMeal(draft.id)
    await workflow.syncPendingAppleHealthChanges()
    #expect(workflow.loggedMeals == [logged])
    #expect(await fixture.health.samples.isEmpty)
    await workflow.syncPendingMealChanges()
    #expect(workflow.pendingMealChanges.isEmpty)

    await fixture.health.setAvailable(true)
    await fixture.health.setWriteAccess([.calories])
    let reopened = fixture.open()
    reopened.restoreSession()
    #expect(reopened.appleHealthSyncEnabled)
    #expect(reopened.loggedMeals == [logged])
    #expect(reopened.pendingMealChanges.isEmpty)
    let sample = try #require(await fixture.health.waitForFirstSample())
    #expect(sample.mealID == logged.id)
    await reopened.syncPendingAppleHealthChanges()
}

@MainActor @Test func replayAfterLosingTheHealthResponseLeavesOneCalorieSample() async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    await fixture.health.loseNextSaveResponse()
    let workflow = fixture.open()
    workflow.restoreSession()
    await workflow.setAppleHealthSyncEnabled(true)
    let draft = try fixture.draft(in: workflow)
    try workflow.confirmMeal(draft.id)
    await workflow.syncPendingAppleHealthChanges()
    let first = try #require(await fixture.health.samples.first)
    #expect(await fixture.health.saveAttempts == [first])

    let reopened = fixture.open()
    reopened.restoreSession()
    await reopened.syncPendingAppleHealthChanges()
    #expect(await fixture.health.saveAttempts == [first])
    #expect(await fixture.health.samples == [first])
    #expect(first.syncIdentifier == "bitelens.\(draft.id.uuidString.lowercased()).calories")

    let afterAcknowledgment = fixture.open()
    afterAcknowledgment.restoreSession()
    await afterAcknowledgment.syncPendingAppleHealthChanges()
    #expect(await fixture.health.saveAttempts == [first])
}

@MainActor @Test func turningSyncOffKeepsExistingEntriesAndSkipsMealsConfirmedWhileOff() async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    await workflow.setAppleHealthSyncEnabled(true)
    let eligible = try fixture.draft(in: workflow)
    try workflow.confirmMeal(eligible.id)
    await workflow.syncPendingAppleHealthChanges()

    await workflow.setAppleHealthSyncEnabled(false)
    let reopened = fixture.open()
    reopened.restoreSession()
    #expect(!reopened.appleHealthSyncEnabled)
    let paused = try fixture.draft(in: reopened)
    try reopened.confirmMeal(paused.id)
    await reopened.syncPendingAppleHealthChanges()
    #expect(await fixture.health.samples.map(\.mealID) == [eligible.id])

    await reopened.setAppleHealthSyncEnabled(true)
    #expect(await fixture.health.samples.map(\.mealID) == [eligible.id])
}

@MainActor struct AppleHealthFixture {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let directory: URL
    let health = TestAppleHealthClient()

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func open(mealSync: (any MealSyncClient)? = nil, now: Date? = nil) -> MealWorkflow {
        let identity = AppleHealthTestIdentity()
        let now = now ?? self.now
        return MealWorkflow(auth: identity, sessionStore: identity, preferences: identity,
                            approvedOwnerID: identity.ownerID, now: { now },
                            draftStorage: LocalMealDraftStorage(directory: directory),
                            mealSync: mealSync, appleHealth: health)
    }

    func draft(in workflow: MealWorkflow, capturedAt: Date? = nil,
               items: [MealItem] = [
                   MealItem(name: "Soup", nutrients: NutrientAmounts(caloriesKcal: 225)),
                   MealItem(name: "Bread", nutrients: NutrientAmounts(caloriesKcal: 50)),
               ]) throws -> MealDraft {
        let draft = try workflow.captureMeal(photoData: Data([1]), capturedAt: capturedAt)
        try workflow.updateDraftItems(draft.id, items: items)
        return draft
    }
}

actor TestAppleHealthClient: AppleHealthClient {
    private(set) var samples: [AppleHealthSample] = []
    private var deletedSamples: [AppleHealthSample] = []
    private var samplesFromOtherSources: [AppleHealthSample] = []
    var entriesFromAllSources: [AppleHealthSample] { samples + samplesFromOtherSources }

    func addEntryFromAnotherSource(_ sample: AppleHealthSample) { samplesFromOtherSources.append(sample) }

    private(set) var requestedNutrients: Set<Nutrient> = []

    private(set) var saveAttempts: [AppleHealthSample] = []
    private var available = true
    private var authorizationRequestAvailable = true
    private var lookupAvailable = true
    private var loseRemovalResponse = false
    private var removeBeforeDeletion = false
    private var writeAccess: Set<Nutrient>?
    private var failBeforeSave = false
    private var loseResponse = false
    private var holdSaveResponse = false
    private var heldSaveResponse: CheckedContinuation<Void, Never>?

    func setAvailable(_ value: Bool) { available = value }
    func setAuthorizationRequestAvailable(_ value: Bool) { authorizationRequestAvailable = value }
    func setLookupAvailable(_ value: Bool) { lookupAvailable = value }
    func loseNextRemovalResponse() { loseRemovalResponse = true }
    func removeEntryBeforeNextBiteLensDeletion() { removeBeforeDeletion = true }
    func setWriteAccess(_ nutrients: Set<Nutrient>) { writeAccess = nutrients }
    func failNextSaveBeforeWriting() { failBeforeSave = true }
    func loseNextSaveResponse() { loseResponse = true }

    func holdAndLoseNextSaveResponse() {
        holdSaveResponse = true
        loseNextSaveResponse()
    }

    func releaseSaveResponse() {
        heldSaveResponse?.resume()
        heldSaveResponse = nil
    }

    func isAvailable() async -> Bool { available }
    func authorizedNutrients() async -> Set<Nutrient> { writeAccess ?? requestedNutrients }

    func requestAuthorization(for nutrients: Set<Nutrient>) async throws {
        guard authorizationRequestAvailable else { throw URLError(.notConnectedToInternet) }
        requestedNutrients = nutrients
    }

    func save(_ sample: AppleHealthSample) async throws {
        saveAttempts.append(sample)
        if failBeforeSave {
            failBeforeSave = false
            throw URLError(.notConnectedToInternet)
        }
        if let index = samples.firstIndex(where: { $0.syncIdentifier == sample.syncIdentifier }) {
            if sample.revision > samples[index].revision { samples[index] = sample }
        } else {
            samples.append(sample)
        }
        if holdSaveResponse {
            holdSaveResponse = false
            await withCheckedContinuation { heldSaveResponse = $0 }
        }
        if loseResponse {
            loseResponse = false
            throw URLError(.networkConnectionLost)
        }
    }

    func ownSampleRevision(mealID: UUID, nutrient: Nutrient) async throws -> Int? {
        guard lookupAvailable else { throw URLError(.notConnectedToInternet) }
        return samples.first { $0.mealID == mealID && $0.nutrient == nutrient }?.revision
    }

    func hasOwnSampleDeletion(mealID: UUID, nutrient: Nutrient, revision: Int) async throws -> Bool {
        guard lookupAvailable else { throw URLError(.notConnectedToInternet) }
        return deletedSamples.contains { $0.mealID == mealID && $0.nutrient == nutrient && $0.revision == revision }
    }

    func deleteOwnSamples(mealID: UUID, nutrient: Nutrient) async throws -> Bool {
        if removeBeforeDeletion {
            removeBeforeDeletion = false
            removeEntryInHealth(mealID: mealID, nutrient: nutrient)
        }
        let deleted = removeEntryInHealth(mealID: mealID, nutrient: nutrient)
        if loseRemovalResponse {
            loseRemovalResponse = false
            throw URLError(.networkConnectionLost)
        }
        return deleted
    }

    @discardableResult func removeEntryInHealth(mealID: UUID, nutrient: Nutrient) -> Bool {
        let count = samples.count
        samples.removeAll { sample in
            guard sample.mealID == mealID, sample.nutrient == nutrient else { return false }
            deletedSamples.append(sample)
            return true
        }
        return samples.count < count
    }

    func waitForFirstSample(revision: Int? = nil) async throws -> AppleHealthSample? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !samples.contains(where: { revision == nil || $0.revision == revision }), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return samples.first { revision == nil || $0.revision == revision }
    }
}

private struct AcknowledgingAppleHealthTestCloud: MealSyncClient {
    func sync(_ change: PendingMealChange, accessToken: String) async throws -> MealSyncAcknowledgement {
        MealSyncAcknowledgement(id: change.id, revision: change.revision)
    }
}

private struct AppleHealthTestIdentity: AuthenticationClient, SessionStore, ProviderPreferences {
    let ownerID = UUID(uuidString: "F5FB1BFF-6D3D-4786-99C4-0291253212AE")!

    func signIn(email: String, password: String) async throws -> AuthSession { throw AuthenticationFailure.unavailable }
    func refresh(refreshToken: String) async throws -> AuthSession { throw AuthenticationFailure.unavailable }
    func signOut(accessToken: String) async throws {}
    func load() throws -> AuthSession? {
        AuthSession(userID: ownerID, accessToken: "test", refreshToken: "test", expiresAt: .distantFuture)
    }
    func save(_ session: AuthSession) throws {}
    func clear() throws {}
    func loadProvider() -> AIProvider? { nil }
    func saveProvider(_ provider: AIProvider) {}
}
