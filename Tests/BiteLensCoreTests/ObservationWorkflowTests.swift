import BiteLensCore
import Foundation
import Testing

private let observationNow = Date(timeIntervalSince1970: 1_800_059_400)
private let observationZone = TimeZone(identifier: "America/Los_Angeles")!

@MainActor @Test func symptomSaveSurvivesOfflineRestartWithItsPendingSnapshot() throws {
    let fixture = ObservationFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    let time = MealTime(instant: observationNow, timeZone: observationZone)
    let first = try workflow.logSymptom(.headache, time: time, severity: .moderate, notes: "After lunch")

    let reopened = fixture.open()
    let saved = try #require(reopened.loggedObservations.first)
    #expect(saved.id == first.id)
    #expect(saved.record.kind == .symptom)
    #expect(saved.record.symptom == .headache)
    #expect(saved.record.time.localDate == "2027-01-15")
    #expect(saved.record.time.timeZoneIdentifier == "America/Los_Angeles")
    #expect(saved.record.severity == .moderate)
    #expect(saved.record.notes == "After lunch")
    #expect(!saved.appleHealthEligible)
    #expect(reopened.pendingObservationChanges == [.save(saved.record, revision: 1)])
}

private struct ObservationFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let ownerID = UUID()

    @MainActor func open() -> MealWorkflow {
        let dependencies = ObservationWorkflowDependencies(ownerID: ownerID)
        let workflow = MealWorkflow(auth: dependencies, sessionStore: dependencies, preferences: dependencies,
                                    approvedOwnerID: ownerID, now: { observationNow },
                                    draftStorage: LocalMealDraftStorage(directory: directory))
        workflow.restoreSession()
        return workflow
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private struct ObservationWorkflowDependencies: AuthenticationClient, SessionStore, ProviderPreferences {
    let ownerID: UUID

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

@MainActor @Test func anUrgeStartedMealLinksOnConfirmationAfterRestart() throws {
    let fixture = ObservationFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    let prior = MealTime(instant: observationNow.addingTimeInterval(-1_800), timeZone: observationZone)
    let urge = try workflow.logUrge(time: prior, intensity: .mild)
    let draft = try workflow.startManualDraft(timeZone: observationZone, linkingUrgeID: urge.id)
    try workflow.updateDraftItems(draft.id, items: [MealItem(name: "Soup")])

    let reopened = fixture.open()
    #expect(reopened.loggedObservations == [urge])
    #expect(reopened.pendingObservationChanges == [.save(urge.record, revision: 1)])
    #expect(reopened.loggedMeals.isEmpty)
    let pending = try #require(reopened.drafts.first)
    let meal = try reopened.confirmMeal(pending.id)

    let saved = fixture.open()
    let linkedUrge = try #require(saved.loggedObservations.first)
    #expect(linkedUrge.id == urge.id)
    #expect(linkedUrge.record.time == prior)
    #expect(linkedUrge.record.mealID == meal.id)
    #expect(saved.pendingObservationChanges == [.save(linkedUrge.record, revision: 2)])
    #expect(saved.loggedMeals == [meal])
    #expect(saved.drafts.isEmpty)
}

@MainActor @Test func cancelledMealDraftLeavesAnUnlinkedUrgeSavedOffline() throws {
    let fixture = ObservationFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    let urge = try workflow.logUrge(intensity: .severe, notes: "Before dinner")
    let draft = try workflow.startManualDraft(timeZone: observationZone, linkingUrgeID: urge.id)
    try workflow.discardDraft(draft.id)

    let reopened = fixture.open()
    let saved = try #require(reopened.loggedObservations.first)
    #expect(saved == urge)
    #expect(saved.record.time.instant == observationNow)
    #expect(saved.record.kind == .urge)
    #expect(saved.record.symptom == nil)
    #expect(saved.record.severity == .severe)
    #expect(saved.record.notes == "Before dinner")
    #expect(saved.record.mealID == nil)
    #expect(reopened.pendingObservationChanges == [.save(saved.record, revision: 1)])
    #expect(reopened.drafts.isEmpty)
    #expect(reopened.loggedMeals.isEmpty)
}

@MainActor @Test func observationSearchIncludesUrgesAndShowsRecentlySavedMatchingTypesFirst() throws {
    let fixture = ObservationFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    let older = MealTime(instant: observationNow.addingTimeInterval(-86_400), timeZone: observationZone)
    try workflow.logSymptom(.headache)
    try workflow.logSymptom(.heartburn, time: older)
    try workflow.logSymptom(.headache, time: older)
    try workflow.logUrge(time: older)

    let reopened = fixture.open()
    #expect(Array(reopened.searchObservationTypes("  HEA ").prefix(2)) == [.symptom(.headache), .symptom(.heartburn)])
    #expect(reopened.searchObservationTypes("breath") == [.symptom(.shortnessOfBreath)])
    #expect(reopened.searchObservationTypes("binge eating") == [.bingeEatingUrge])
    #expect(reopened.searchObservationTypes("").first == .bingeEatingUrge)
    #expect(reopened.loggedObservations.filter { $0.record.symptom == .headache }.count == 2)
    #expect(reopened.searchObservationTypes("").count == 40)
}

@MainActor @Test func offlineEditsAndDeletionReplaceThePendingObservationRevision() throws {
    let fixture = ObservationFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    let entry = try workflow.logSymptom(.moodChanges, severity: .mild)
    let past = MealTime(instant: observationNow.addingTimeInterval(-86_400), timeZone: observationZone)
    let edited = try workflow.updateObservation(entry.id, time: past, severity: .severe, notes: "After a long walk")

    let reopened = fixture.open()
    #expect(reopened.loggedObservations == [edited])
    #expect(edited.record.symptom == .moodChanges)
    #expect(edited.record.time == past)
    #expect(edited.record.severity == .severe)
    #expect(edited.record.notes == "After a long walk")
    #expect(reopened.pendingObservationChanges == [.save(edited.record, revision: 2)])

    try reopened.deleteObservation(edited.id)
    let afterDeletion = fixture.open()
    #expect(afterDeletion.loggedObservations.isEmpty)
    #expect(afterDeletion.pendingObservationChanges == [.delete(id: edited.id, ownerID: fixture.ownerID, revision: 3)])
}

@MainActor @Test func confirmedMealsCanBeLinkedReplacedAndUnlinkedWithoutMovingTheUrge() throws {
    let fixture = ObservationFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    let prior = MealTime(instant: observationNow.addingTimeInterval(-1_800), timeZone: observationZone)
    let urge = try workflow.logUrge(time: prior, intensity: .mild)
    let draft = try workflow.startManualDraft(timeZone: observationZone, linkingUrgeID: urge.id)
    try workflow.updateDraftItems(draft.id, items: [MealItem(name: "Soup")])
    #expect(throws: ObservationIssue.mealNotFound) { try workflow.linkUrge(urge.id, to: draft.id) }

    let first = try workflow.confirmMeal(draft.id)
    let reopened = fixture.open()
    #expect(reopened.loggedObservations.first?.record.mealID == first.id)
    #expect(reopened.loggedObservations.first?.record.time == prior)

    let nextDraft = try reopened.startManualDraft(timeZone: observationZone)
    try reopened.updateDraftItems(nextDraft.id, items: [MealItem(name: "Toast")])
    let second = try reopened.confirmMeal(nextDraft.id)
    let replaced = try reopened.linkUrge(urge.id, to: second.id)
    #expect(replaced.record.mealID == second.id)
    let unlinked = try reopened.linkUrge(urge.id, to: nil)
    #expect(unlinked.record.mealID == nil)
    #expect(unlinked.record.time == prior)
}

@MainActor @Test func deletingTheUrgeLeavesItsPendingMealConfirmable() throws {
    let fixture = ObservationFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    let urge = try workflow.logUrge()
    let draft = try workflow.startManualDraft(linkingUrgeID: urge.id)
    try workflow.updateDraftItems(draft.id, items: [MealItem(name: "Soup")])
    try workflow.deleteObservation(urge.id)

    let reopened = fixture.open()
    let meal = try reopened.confirmMeal(draft.id)

    #expect(reopened.loggedMeals == [meal])
    #expect(reopened.loggedObservations.isEmpty)
    #expect(reopened.pendingObservationChanges == [.delete(id: urge.id, ownerID: fixture.ownerID, revision: 2)])
}

@MainActor @Test func mealDeletionClearsAllLinkedUrgesAndTheirPendingSnapshotsAtomically() throws {
    let fixture = ObservationFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    let draft = try workflow.startManualDraft(timeZone: observationZone)
    try workflow.updateDraftItems(draft.id, items: [MealItem(name: "Toast")])
    let meal = try workflow.confirmMeal(draft.id)
    let first = try workflow.logUrge(intensity: .severe, notes: "First urge", mealID: meal.id)
    let second = try workflow.logUrge(notes: "Second urge")
    try workflow.linkUrge(second.id, to: meal.id)

    try workflow.deleteLoggedMeal(meal.id)
    let reopened = fixture.open()
    #expect(reopened.loggedMeals.isEmpty)
    #expect(reopened.pendingMealChanges == [.delete(id: meal.id, ownerID: fixture.ownerID, revision: 2)])
    #expect(Set(reopened.loggedObservations.map(\.id)) == [first.id, second.id])
    #expect(reopened.loggedObservations.allSatisfy { $0.record.mealID == nil })
    let afterDeletion = try #require(reopened.loggedObservations.first { $0.id == first.id })
    #expect(afterDeletion.record.notes == first.record.notes)
    #expect(afterDeletion.record.time == first.record.time)
    let otherAfterDeletion = try #require(reopened.loggedObservations.first { $0.id == second.id })
    #expect(reopened.pendingObservationChanges == [
        .save(afterDeletion.record, revision: 2),
        .save(otherAfterDeletion.record, revision: 3)
    ])
}

@MainActor @Test func historyInterleavesRowsOnRecordedDaysAndKeepsMealTotals() throws {
    let fixture = ObservationFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let tokyoSymptom = try workflow.logSymptom(.nausea, time: MealTime(instant: observationNow, timeZone: tokyo))
    let earlier = observationNow.addingTimeInterval(-3_600)
    let urge = try workflow.logUrge(time: MealTime(instant: earlier, timeZone: observationZone))
    let tiedSymptom = try workflow.logSymptom(.headache, time: MealTime(instant: earlier, timeZone: observationZone))
    let priorDay = MealTime(instant: observationNow.addingTimeInterval(-86_400), timeZone: observationZone)
    let standaloneUrge = try workflow.logUrge(time: priorDay)
    let draft = try workflow.startManualDraft(timeZone: observationZone)
    try workflow.updateDraftItems(draft.id, items: [MealItem(name: "Soup", nutrients: .init(caloriesKcal: 250))])
    let meal = try workflow.confirmMeal(draft.id)

    let days = fixture.open().dailyHistory
    #expect(days.map(\.localDate) == ["2027-01-16", "2027-01-15", "2027-01-14"])
    #expect(days.map(\.rows.count) == [1, 3, 1])
    let tokyoDay = try #require(days.first)
    #expect(tokyoDay.rows.map(\.id) == [.observation(tokyoSymptom.id)])
    #expect(tokyoDay.nutrientTotals == nil)
    let mealDay = try #require(days.first { $0.localDate == "2027-01-15" })
    let ties = [urge.id, tiedSymptom.id].sorted { $0.uuidString < $1.uuidString }
    #expect(mealDay.rows.map(\.id) == [.meal(meal.id)] + ties.map { .observation($0) })
    #expect(mealDay.nutrientTotals?[.calories].knownAmount == 250)
    let urgeDay = try #require(days.last)
    #expect(urgeDay.rows.map(\.id) == [.observation(standaloneUrge.id)])
    #expect(urgeDay.nutrientTotals == nil)
}

@MainActor @Test func futureTimeCannotCreateOrMoveAnObservation() throws {
    let fixture = ObservationFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    let future = MealTime(instant: observationNow.addingTimeInterval(1), timeZone: observationZone)
    #expect(throws: ObservationIssue.futureTime) { try workflow.logSymptom(.fatigue, time: future) }
    #expect(throws: ObservationIssue.futureTime) { try workflow.logUrge(time: future) }

    let urge = try workflow.logUrge()
    #expect(throws: ObservationIssue.futureTime) {
        try workflow.updateObservation(urge.id, time: future, severity: .severe, notes: "Future")
    }
    #expect(workflow.loggedObservations == [urge])
    #expect(workflow.pendingObservationChanges == [.save(urge.record, revision: 1)])
}
