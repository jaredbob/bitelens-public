import Foundation
import Testing
import BiteLensCore

private let draftOwner = UUID(uuidString: "a1000000-0000-4000-8000-000000000001")!
private let captureInstant = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor @Test func offlineCaptureAndOptionalNotesSurviveRestart() throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let draft = try workflow.captureMeal(photoData: Data("private-photo".utf8), timeZone: TimeZone(identifier: "America/Chicago")!)
    try workflow.updateDraftNotes(draft.id, notes: "Olive oil; half the rice")

    let reopened = fixture.open()
    reopened.restoreSession()
    let restored = try #require(reopened.drafts.first)
    #expect(restored.id == draft.id)
    #expect(restored.notes == "Olive oil; half the rice")
    #expect(restored.photo?.capturedAt == captureInstant)
    #expect(restored.mealTime.instant == captureInstant)
    #expect(restored.mealTime.timeZoneIdentifier == "America/Chicago")
    #expect(restored.mealTime.localDate == "2027-01-15")
    #expect(try reopened.photoData(for: draft.id) == Data("private-photo".utf8))
}

@MainActor @Test func photoAccessExpiresAtExactly168HoursAndExecutionCleansFilesWithoutLosingDraft() throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let draft = try workflow.captureMeal(photoData: Data("private-photo".utf8))
    try workflow.updateDraftNotes(draft.id, notes: "Still needs recording")
    fixture.clock.advance(604_799)
    #expect(try workflow.photoData(for: draft.id) == Data("private-photo".utf8))

    fixture.clock.advance(1)
    #expect(throws: DraftIssue.photoExpired) { try workflow.photoData(for: draft.id) }
    let reopened = fixture.open()
    reopened.restoreSession()
    #expect(reopened.drafts.first?.notes == "Still needs recording")
    #expect(throws: DraftIssue.photoExpired) { try reopened.photoData(for: draft.id) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.appendingPathComponent("photos").path).isEmpty)
}

@MainActor @Test func editedMealTimeKeepsChosenTravelDayAndCannotExtendPhotoLifetime() throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let draft = try workflow.captureMeal(photoData: Data([1, 2, 3]))
    // 2027-01-16 00:30 UTC is January 15 in Los Angeles and January 16 in Tokyo.
    let chosenTime = Date(timeIntervalSince1970: 1_800_059_400)
    try workflow.setMealTime(draft.id, instant: chosenTime, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
    fixture.clock.advance(604_800)
    let reopened = fixture.open()
    reopened.restoreSession()
    let restored = try #require(reopened.drafts.first)
    #expect(restored.mealTime.instant == chosenTime)
    #expect(restored.mealTime.localDate == "2027-01-15")
    #expect(restored.mealTime.timeZoneIdentifier == "America/Los_Angeles")
    #expect(restored.photo?.capturedAt == captureInstant)
    #expect(throws: DraftIssue.photoExpired) { try reopened.photoData(for: draft.id) }
}

@MainActor @Test func retakeKeepsOneSelectedPhotoAndPreservesDraftContextAcrossRestart() throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let original = try workflow.captureMeal(photoData: Data("first".utf8))
    try workflow.updateDraftNotes(original.id, notes: "For two people")
    fixture.clock.advance(60)
    try workflow.retakePhoto(for: original.id, photoData: Data("replacement".utf8))
    let reopened = fixture.open()
    reopened.restoreSession()
    let draft = try #require(reopened.drafts.first)
    #expect(reopened.drafts.count == 1)
    #expect(draft.id == original.id)
    #expect(draft.notes == "For two people")
    #expect(draft.mealTime == original.mealTime)
    #expect(draft.photo?.id != original.photo?.id)
    #expect(draft.photo?.capturedAt == captureInstant.addingTimeInterval(60))
    #expect(try reopened.photoData(for: draft.id) == Data("replacement".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.appendingPathComponent("photos").path).count == 1)
}

@MainActor @Test func expiredDraftCanBeDiscardedWithoutDiscardingOtherPendingMeals() throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let expired = try workflow.captureMeal(photoData: Data([1]))
    fixture.clock.advance(604_800)
    let retained = try workflow.captureMeal(photoData: Data([2]))
    try workflow.discardDraft(expired.id)
    let reopened = fixture.open()
    reopened.restoreSession()
    #expect(reopened.drafts.map(\.id) == [retained.id])
    #expect(try reopened.photoData(for: retained.id) == Data([2]))
    try reopened.discardDraft(retained.id)
    let afterDiscard = fixture.open()
    afterDiscard.restoreSession()
    #expect(afterDiscard.drafts.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.appendingPathComponent("photos").path).isEmpty)
}

@MainActor @Test func unreadableDraftRecordsCannotBeOverwrittenByANewCapture() throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    _ = try workflow.captureMeal(photoData: Data([1]))
    let records = fixture.directory.appendingPathComponent("drafts.json")
    let recoverableRecords = try Data(contentsOf: records)
    try Data("interrupted-or-corrupt-records".utf8).write(to: records, options: .atomic)
    let reopened = fixture.open()
    reopened.restoreSession()
    #expect(throws: DraftIssue.storageUnavailable) { try reopened.captureMeal(photoData: Data([2])) }
    try recoverableRecords.write(to: records, options: .atomic)
    reopened.resumeLocalWork()
    #expect(reopened.drafts.count == 1)
    #expect(try reopened.photoData(for: #require(reopened.drafts.first).id) == Data([1]))
}

@MainActor @Test func failedCaptureOrRetakePreservesExistingDraftAndAllowsRecovery() throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    #expect(throws: DraftIssue.invalidPhoto) { try workflow.captureMeal(photoData: Data()) }
    #expect(workflow.drafts.isEmpty)
    let draft = try workflow.captureMeal(photoData: Data([1]))
    #expect(throws: DraftIssue.invalidPhoto) { try workflow.retakePhoto(for: draft.id, photoData: Data()) }
    #expect(try workflow.photoData(for: draft.id) == Data([1]))
    try workflow.retakePhoto(for: draft.id, photoData: Data([2]))
    #expect(try workflow.photoData(for: draft.id) == Data([2]))
}

@MainActor @Test func delayedCameraDeliveryUsesOriginalShutterTimeForRetentionAndMealDefault() throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    fixture.clock.advance(30)
    let draft = try workflow.captureMeal(photoData: Data([1]), capturedAt: captureInstant)
    #expect(draft.photo?.capturedAt == captureInstant)
    #expect(draft.mealTime.instant == captureInstant)
    fixture.clock.advance(604_770)
    #expect(throws: DraftIssue.photoExpired) { try workflow.photoData(for: draft.id) }
    #expect(throws: DraftIssue.invalidCaptureTime) {
        try workflow.captureMeal(photoData: Data([2]), capturedAt: fixture.clock.date.addingTimeInterval(1))
    }
}

@MainActor @Test func privatePhotoFilesAreSeparateAndRequestBackupExclusionAfterRetake() throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let photoBytes = Data("sensitive-photo-only-bytes".utf8)
    let draft = try workflow.captureMeal(photoData: photoBytes)
    try workflow.retakePhoto(for: draft.id, photoData: photoBytes)
    let photosDirectory = fixture.directory.appendingPathComponent("photos")
    let photo = try #require(FileManager.default.contentsOfDirectory(at: photosDirectory, includingPropertiesForKeys: nil).first)
    #expect(try Data(contentsOf: photo) == photoBytes)
    #expect(try photo.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    #expect(try photosDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    let attributes = try FileManager.default.attributesOfItem(atPath: photo.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: fixture.directory.path)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #if os(iOS)
    #expect(attributes[.protectionKey] as? FileProtectionType == .complete)
    #endif
    let records = try Data(contentsOf: fixture.directory.appendingPathComponent("drafts.json"))
    #expect(records.range(of: photoBytes) == nil)
    #expect(String(data: records, encoding: .utf8)?.contains(photoBytes.base64EncodedString()) == false)
}

@MainActor @Test func localDraftAccessRequiresOwnerAndSignOutKeepsFilesWithoutExposingThem() async throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    #expect(throws: WorkflowIssue.accessDenied) { try workflow.captureMeal(photoData: Data([1])) }
    workflow.restoreSession()
    let draft = try workflow.captureMeal(photoData: Data([1]))
    await workflow.signOut()
    #expect(workflow.drafts.isEmpty)
    #expect(throws: WorkflowIssue.accessDenied) { try workflow.photoData(for: draft.id) }
    #expect(throws: WorkflowIssue.accessDenied) { try workflow.updateDraftNotes(draft.id, notes: "unauthorized") }
    #expect(throws: WorkflowIssue.accessDenied) { try workflow.discardDraft(draft.id) }
    let reopened = fixture.open()
    reopened.restoreSession()
    #expect(try reopened.photoData(for: draft.id) == Data([1]))
}

@MainActor @Test func foregroundResumeCleansUnaccessedExpiredPhotosAndInterruptedCaptureOrphans() throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let draft = try workflow.captureMeal(photoData: Data([1]))
    let photos = fixture.directory.appendingPathComponent("photos")
    try Data([9]).write(to: photos.appendingPathComponent("interrupted.photo"))
    fixture.clock.advance(604_800)
    workflow.resumeLocalWork()
    #expect(try FileManager.default.contentsOfDirectory(atPath: photos.path).isEmpty)
    #expect(workflow.drafts.map(\.id) == [draft.id])
}

@MainActor @Test func expiryCleanupRunsWhileSignedOutWithoutExposingOrDeletingDraftMetadata() async throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let draft = try workflow.captureMeal(photoData: Data([1]))
    await workflow.signOut()
    fixture.clock.advance(604_800)
    workflow.resumeLocalWork()
    #expect(workflow.drafts.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.appendingPathComponent("photos").path).isEmpty)
    let reopened = fixture.open()
    reopened.restoreSession()
    #expect(reopened.drafts.map(\.id) == [draft.id])
}

@MainActor @Test func foregroundCleanupFollowsDraftAndLoggedPhotoDeadlinesWithoutOpeningEitherPhoto() async throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    let clock = fixture.clock
    workflow.restoreSession()
    let day: TimeInterval = 86_400
    let draft = try workflow.captureMeal(photoData: Data([1]), capturedAt: clock.date.addingTimeInterval(-6 * day))
    let next = try workflow.captureMeal(photoData: Data([2]), capturedAt: clock.date.addingTimeInterval(-5 * day))
    try workflow.updateDraftItems(next.id, items: [MealItem(name: "Lunch")])
    let logged = try workflow.confirmMeal(next.id)
    let photos = fixture.directory.appendingPathComponent("photos").path

    let firstDeadline = try #require(workflow.nextPhotoExpiration)
    #expect(firstDeadline == draft.photo?.expiresAt)
    await workflow.waitForPhotoExpiry(at: firstDeadline) { duration in
        #expect(duration == .seconds(day))
        clock.advance(day)
        // A save racing the deadline must not bump it past an uncleaned photo.
        try await workflow.updateDraftNotes(draft.id, notes: "Edited at expiry")
    }
    let loggedPhoto = try #require(logged.photo)
    #expect(try FileManager.default.contentsOfDirectory(atPath: photos) == ["\(loggedPhoto.id).photo"])
    #expect(workflow.drafts.first?.notes == "Edited at expiry")
    #expect(workflow.loggedMeals == [logged])

    await workflow.signOut()
    let secondDeadline = try #require(workflow.nextPhotoExpiration)
    #expect(secondDeadline == loggedPhoto.expiresAt)
    await workflow.waitForPhotoExpiry(at: secondDeadline) { duration in
        #expect(duration == .seconds(day))
        clock.advance(day)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: photos).isEmpty)
    #expect(workflow.nextPhotoExpiration == nil)
    #expect(workflow.drafts.isEmpty)
    let reopened = fixture.open()
    reopened.restoreSession()
    #expect(reopened.drafts.map(\.id) == [draft.id])
    #expect(reopened.loggedMeals == [logged])
}

@MainActor @Test func cancelledForegroundCleanupLeavesExpiryForTheNextResume() async throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    let clock = fixture.clock
    workflow.restoreSession()
    _ = try workflow.captureMeal(photoData: Data([1]))
    let photos = fixture.directory.appendingPathComponent("photos").path
    let deadline = try #require(workflow.nextPhotoExpiration)
    let foreground = Task {
        await workflow.waitForPhotoExpiry(at: deadline) { _ in
            clock.advance(604_800)
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
    await foreground.value
    #expect(try FileManager.default.contentsOfDirectory(atPath: photos).count == 1)
    workflow.resumeLocalWork()
    #expect(try FileManager.default.contentsOfDirectory(atPath: photos).isEmpty)
}

@MainActor private struct DraftFixture {
    let directory: URL
    let clock: DraftClock
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BiteLensDrafts-\(UUID().uuidString)")
        clock = DraftClock()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func open(mealSync: (any MealSyncClient)? = nil, tokenExpiresAt: Date = .distantPast,
              auth: any AuthenticationClient = DraftOfflineAuth(),
              observationSync: (any ObservationSyncClient)? = nil) -> MealWorkflow {
        let clock = clock
        return MealWorkflow(auth: auth, sessionStore: DraftIdentity(expiresAt: tokenExpiresAt), preferences: DraftIdentity(),
                            approvedOwnerID: draftOwner, now: { clock.date },
                            draftStorage: LocalMealDraftStorage(directory: directory), mealSync: mealSync,
                            observationSync: observationSync)
    }
}

private final class DraftClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = captureInstant
    var date: Date { lock.withLock { instant } }
    func advance(_ interval: TimeInterval) { lock.withLock { instant.addTimeInterval(interval) } }
}

private struct DraftIdentity: SessionStore, ProviderPreferences {
    var expiresAt: Date = .distantPast
    func load() throws -> AuthSession? {
        AuthSession(userID: draftOwner, accessToken: "offline-test", refreshToken: "offline-test", expiresAt: expiresAt)
    }
    func save(_ session: AuthSession) throws {}
    func clear() throws {}
    func loadProvider() -> AIProvider? { .openAI }
    func saveProvider(_ provider: AIProvider) {}
}

private struct DraftOfflineAuth: AuthenticationClient {
    func signIn(email: String, password: String) async throws -> AuthSession { throw URLError(.notConnectedToInternet) }
    func refresh(refreshToken: String) async throws -> AuthSession { throw URLError(.notConnectedToInternet) }
    func signOut(accessToken: String) async throws { throw URLError(.notConnectedToInternet) }
}

@MainActor @Test func explicitlyConfirmedManualMealAndItsPendingCreateSurviveAnOfflineRestart() async throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    do { _ = try await workflow.accessToken() }
    catch { #expect(error as? WorkflowIssue == .authenticationUnavailable) }
    #expect(workflow.cloudStatus == .offline)

    let photo = Data("private-photo".utf8)
    let draft = try workflow.captureMeal(photoData: photo, timeZone: TimeZone(identifier: "America/Chicago")!)
    try workflow.updateDraftNotes(draft.id, notes: "Lunch after a walk")
    let soup = MealItem(name: "Soup", description: "Tomato",
                        portion: ConsumedPortion(grams: 250, servingDescription: "One cup"))
    let tea = MealItem(name: "Tea", portion: ConsumedPortion(servingDescription: "One mug"))
    try workflow.updateDraftItems(draft.id, items: [soup, tea])
    #expect(workflow.loggedMeals.isEmpty)
    #expect(workflow.pendingMealChanges.isEmpty)

    let restored = fixture.open()
    restored.restoreSession()
    #expect(restored.drafts.first?.review?.items == [soup, tea])
    let logged = try restored.confirmMeal(draft.id)
    #expect(logged.id == draft.id)
    #expect(restored.drafts.isEmpty)
    #expect(throws: DraftIssue.draftNotFound) { try restored.confirmMeal(draft.id) }

    let reopened = fixture.open()
    reopened.restoreSession()
    #expect(reopened.loggedMeals == [logged])
    #expect(reopened.drafts.isEmpty)
    let pending = try #require(reopened.pendingMealChanges.first)
    #expect(reopened.pendingMealChanges.count == 1)
    #expect(pending == .save(logged.record, revision: 1))
    #expect(logged.record.ownerID == draftOwner)
    #expect(logged.record.items == [soup, tea])
    #expect(logged.record.notes == "Lunch after a walk")
    #expect(logged.record.estimateProvenance == nil)
    #expect(try reopened.photoData(forLoggedMeal: logged.id) == photo)
}

@MainActor @Test func mealAndDailyTotalsPreserveUnknownsZeroAndTheChosenDayAfterTravel() throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let chicago = TimeZone(identifier: "America/Chicago")!
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    let draft = try workflow.captureMeal(photoData: Data([1]), timeZone: chicago)
    #expect(draft.mealTime.instant == captureInstant)
    #expect(draft.mealTime.localDate == "2027-01-15")

    let soup = MealItem(name: "Soup", nutrients: NutrientAmounts(caloriesKcal: 110, proteinGrams: 3,
                                                               fatGrams: 2, sodiumMilligrams: 75))
    let tea = MealItem(name: "Tea", nutrients: NutrientAmounts(caloriesKcal: 0, fatGrams: 0, sodiumMilligrams: 0))
    try workflow.updateDraftItems(draft.id, items: [soup, tea])
    // 2027-01-16 00:30 UTC is January 15 in Los Angeles and January 16 in Tokyo.
    let correctedTime = Date(timeIntervalSince1970: 1_800_059_400)
    try workflow.setMealTime(draft.id, instant: correctedTime, timeZone: losAngeles)
    #expect(workflow.dailyMealSummaries.isEmpty)
    #expect(workflow.drafts.first?.review?.nutrientTotals[.fat] == NutrientTotal(knownAmount: 2, isIncomplete: false))

    fixture.clock.advance(86_400)
    let first = try workflow.confirmMeal(draft.id)
    #expect(first.record.mealTime.instant == correctedTime)
    #expect(first.record.mealTime.timeZoneIdentifier == losAngeles.identifier)
    #expect(first.record.mealTime.localDate == "2027-01-15")
    #expect(first.record.confirmedAt == fixture.clock.date)
    #expect(first.record.items[1].nutrients[.calories] == 0)
    #expect(first.record.items[1].nutrients[.protein] == nil)
    #expect(first.record.nutrientTotals[.protein] == NutrientTotal(knownAmount: 3, isIncomplete: true))
    #expect(first.record.nutrientTotals[.carbohydrates] == NutrientTotal(knownAmount: nil, isIncomplete: true))

    let second = try workflow.captureMeal(photoData: Data([2]), capturedAt: correctedTime, timeZone: chicago)
    let rice = MealItem(name: "Rice", nutrients: NutrientAmounts(caloriesKcal: 200, proteinGrams: 4,
                                                                carbohydratesGrams: 44, fatGrams: 0, sodiumMilligrams: 0))
    try workflow.updateDraftItems(second.id, items: [rice])
    _ = try workflow.confirmMeal(second.id)

    let travel = try workflow.captureMeal(photoData: Data([3]), capturedAt: correctedTime, timeZone: tokyo)
    try workflow.updateDraftItems(travel.id, items: [
        MealItem(name: "Water", nutrients: NutrientAmounts(caloriesKcal: 0, sodiumMilligrams: 0))
    ])
    _ = try workflow.confirmMeal(travel.id)

    let reopened = fixture.open()
    reopened.restoreSession()
    #expect(reopened.dailyMealSummaries.map(\.localDate) == ["2027-01-16", "2027-01-15"])
    let jan15 = try #require(reopened.dailyMealSummaries.last)
    #expect(jan15.meals.count == 2)
    #expect(jan15.nutrientTotals[.calories] == NutrientTotal(knownAmount: 310, isIncomplete: false))
    #expect(jan15.nutrientTotals[.protein] == NutrientTotal(knownAmount: 7, isIncomplete: true))
    #expect(jan15.nutrientTotals[.carbohydrates] == NutrientTotal(knownAmount: 44, isIncomplete: true))
    #expect(jan15.nutrientTotals[.fat] == NutrientTotal(knownAmount: 2, isIncomplete: false))
    #expect(jan15.nutrientTotals[.fiber] == NutrientTotal(knownAmount: nil, isIncomplete: true))
    #expect(jan15.nutrientTotals[.sodium] == NutrientTotal(knownAmount: 75, isIncomplete: false))
    #expect(reopened.dailyMealSummaries.first?.nutrientTotals[.sodium] == NutrientTotal(knownAmount: 0, isIncomplete: false))
}

@MainActor @Test func nutrientHistoryUsesCompleteDailyTotalsAndFindsTheLatestTiedDates() throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    try logHistoryMeal(workflow, at: "2027-01-04T10:00:00Z", protein: 30)
    try logHistoryMeal(workflow, at: "2027-01-04T18:00:00Z", protein: 70)
    try logHistoryMeal(workflow, at: "2027-01-06T10:00:00Z", protein: 160)
    try logHistoryMeal(workflow, at: "2027-01-06T18:00:00Z", protein: nil)
    try logHistoryMeal(workflow, at: "2027-01-07T10:00:00Z", protein: 0)
    try logHistoryMeal(workflow, at: "2027-01-08T10:00:00Z", protein: 100)
    try logHistoryMeal(workflow, at: "2027-01-11T10:00:00Z", protein: 0)
    let observationTime = MealTime(instant: try Date.ISO8601FormatStyle().parse("2027-01-12T10:00:00Z"), timeZone: .gmt)
    try workflow.logSymptom(.headache, time: observationTime)
    try logHistoryMeal(workflow, at: "2027-01-15T11:00:00Z", protein: 200)

    let reopened = fixture.open()
    reopened.restoreSession()
    let now = try Date.ISO8601FormatStyle().parse("2027-01-16T00:30:00Z")
    let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let protein = try #require(reopened.nutrientHistory(for: .protein, in: .allTime, asOf: now,
                                                        timeZone: zone).summaries.first)
    #expect(protein.dayCount == 4)
    #expect(protein.average == 50)
    #expect(protein.high?.amount == 100)
    #expect(protein.high?.localDate == "2027-01-08")
    #expect(protein.high?.tieCount == 2)
    #expect(protein.low?.amount == 0)
    #expect(protein.low?.localDate == "2027-01-11")
    #expect(protein.low?.tieCount == 2)

    let calories = try #require(reopened.nutrientHistory(for: .calories, in: .allTime, asOf: now,
                                                          timeZone: zone).summaries.first)
    #expect(calories.dayCount == 5)
    #expect(calories.average == 140)
    #expect(calories.high?.tieCount == 2)
    #expect(calories.high?.localDate == "2027-01-06")
}

@MainActor @Test func nutrientHistoryGroupsRecordedDaysIntoMondayWeeksAndCalendarMonths() throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
    try logHistoryMeal(workflow, at: "2026-11-01T00:30:00Z", timeZone: losAngeles, protein: 80)
    try logHistoryMeal(workflow, at: "2026-11-01T00:30:00Z", timeZone: tokyo, protein: 100)
    try logHistoryMeal(workflow, at: "2026-11-02T10:00:00Z", protein: 90)
    try logHistoryMeal(workflow, at: "2027-01-10T10:00:00Z", protein: nil)
    try logHistoryMeal(workflow, at: "2027-01-14T10:00:00Z", protein: 40)
    let now = try Date.ISO8601FormatStyle().parse("2027-01-15T12:00:00Z")
    let week = workflow.nutrientHistory(for: .protein, in: .week, asOf: now, timeZone: .gmt)
    #expect(week.through == (try Date.ISO8601FormatStyle().parse("2027-01-14T00:00:00Z")))
    let weekStarts = try ["2027-01-11", "2027-01-04", "2026-11-02", "2026-10-26"].map {
        try Date.ISO8601FormatStyle().parse("\($0)T00:00:00Z")
    }
    #expect(week.summaries.compactMap { $0.dates?.lowerBound } == weekStarts)
    #expect(week.summaries.map(\.average) == [40, nil, 90, 90])
    #expect(week.summaries.map(\.dayCount) == [1, 0, 1, 2])
    #expect(week.summaries.last?.high?.localDate == "2026-11-01")
    #expect(week.summaries.last?.low?.localDate == "2026-10-31")

    let month = workflow.nutrientHistory(for: .protein, in: .month, asOf: now, timeZone: .gmt)
    #expect(month.summaries.map(\.average) == [40, 95, 80])
    #expect(month.summaries.map(\.dayCount) == [1, 2, 1])
    #expect(month.summaries.first?.high?.localDate == "2027-01-14")
}

@MainActor private func logHistoryMeal(_ workflow: MealWorkflow, at timestamp: String, timeZone: TimeZone = .gmt,
                                     protein: Double?) throws {
    let draft = try workflow.startManualDraft(timeZone: timeZone)
    try workflow.setMealTime(draft.id, instant: Date.ISO8601FormatStyle().parse(timestamp), timeZone: timeZone)
    try workflow.updateDraftItems(draft.id, items: [
        MealItem(name: "Meal item", nutrients: .init(caloriesKcal: 100, proteinGrams: protein))
    ])
    try workflow.confirmMeal(draft.id)
}

@MainActor @Test func aCorrectedEstimateUsesTheSameReviewAndKeepsOriginalProvenanceAfterPhotoExpiry() throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let draft = try workflow.captureMeal(photoData: Data([1]))
    let provenance = EstimateProvenance(provider: .openAI, model: "fixture-model", version: "1")
    let item = MealItem(name: "Rice", portion: ConsumedPortion(grams: 100),
                        nutrients: NutrientAmounts(caloriesKcal: 130))
    try workflow.applyEstimate(MealEstimate(items: [item], provenance: provenance), to: draft.id)
    #expect(workflow.loggedMeals.isEmpty)
    #expect(workflow.drafts.first?.review?.items.first?.nutrients[.calories] == 130)

    var corrected = item
    corrected.description = "Cooked brown rice"
    corrected.nutrients[.calories] = 115
    try workflow.updateDraftItems(draft.id, items: [corrected])
    workflow.selectProvider(.grok)
    fixture.clock.advance(604_800)
    workflow.resumeLocalWork()
    #expect(throws: DraftIssue.photoExpired) { try workflow.photoData(for: draft.id) }
    let meal = try workflow.confirmMeal(draft.id)

    let reopened = fixture.open()
    reopened.restoreSession()
    let saved = try #require(reopened.loggedMeals.first?.record.items.first)
    #expect(saved.id == corrected.id && saved.description == "Cooked brown rice")
    #expect(saved.nutrients.caloriesKcal == 115)
    #expect(saved.originalEstimate?.nutrients.caloriesKcal == 130 && saved.isCorrected == true)
    #expect(reopened.loggedMeals.first?.record.estimateProvenance == provenance)
    #expect(throws: DraftIssue.photoExpired) { try reopened.photoData(forLoggedMeal: meal.id) }
}

@MainActor @Test func copyingALoggedMealCreatesAnIndependentEditableDraft() throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let photo = Data([1])
    let original = try workflow.captureMeal(photoData: photo)
    try workflow.updateDraftNotes(original.id, notes: "Lunch leftovers")
    let provenance = EstimateProvenance(provider: .openAI, model: "fixture-model")
    let item = MealItem(name: "Rice", portion: ConsumedPortion(grams: 100, servingDescription: "One small bowl"),
                        nutrients: NutrientAmounts(caloriesKcal: 130))
    try workflow.applyEstimate(MealEstimate(items: [item], provenance: provenance), to: original.id)
    var corrected = item
    corrected.description = "Cooked brown rice"
    corrected.portion.grams = 150
    try workflow.updateDraftItems(original.id, items: [corrected, MealItem(name: "Tea")])
    let meal = try workflow.confirmMeal(original.id)

    fixture.clock.advance(86_400)
    let zone = try #require(TimeZone(identifier: "America/Chicago"))
    let copy = try workflow.copyLoggedMealToDraft(meal.id, timeZone: zone)
    #expect(copy.id != meal.id)
    #expect(copy.mealTime == MealTime(instant: fixture.clock.date, timeZone: zone))
    #expect(copy.notes == meal.record.notes)
    #expect(copy.photo == nil)
    #expect(workflow.loggedMeals == [meal])
    #expect(workflow.pendingMealChanges.map(\.id) == [meal.id])

    let reopened = fixture.open()
    reopened.restoreSession()
    #expect(reopened.drafts == [copy])
    let review = try #require(copy.review)
    #expect(review.estimateProvenance == provenance)
    #expect(review.nutrientTotals == meal.record.nutrientTotals)
    #expect(review.items.map(\.name) == ["Rice", "Tea"])
    #expect(Set(review.items.map(\.id)).isDisjoint(with: meal.record.items.map(\.id)))
    var rice = try #require(review.items.first)
    #expect(rice.description == "Cooked brown rice")
    #expect(rice.portion == corrected.portion)
    #expect(rice.origin == .ai && rice.isCorrected == true)
    #expect(rice.originalEstimate == meal.record.items.first?.originalEstimate)
    rice.portion.grams = 100
    #expect(rice.nutrients.caloriesKcal == 130)

    try reopened.updateDraftNotes(copy.id, notes: "Today's tea")
    try reopened.updateDraftItems(copy.id, items: Array(review.items.dropFirst()))
    let newMeal = try reopened.confirmMeal(copy.id)
    #expect(newMeal.record.notes == "Today's tea")
    #expect(newMeal.record.estimateProvenance == nil)
    #expect(reopened.loggedMeals == [newMeal, meal])
    #expect(try reopened.photoData(forLoggedMeal: meal.id) == photo)
}

@MainActor @Test func installedDraftArrayOpensWithItsOriginalPhotoThenRecoversManuallyAfterExpiry() throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let draftID = UUID(uuidString: "8CFA1EEA-AEE4-4091-84BE-839EDCB21E51")!
    let photoID = UUID(uuidString: "8D821F70-9158-401C-A9DA-38F1A6E88E3C")!
    let original = """
        [{
          "id":"\(draftID)",
          "photo":{"id":"\(photoID)","capturedAt":821692800},
          "notes":"Leftover soup",
          "mealTime":{"instant":821692800,"localDate":"2027-01-15","timeZoneIdentifier":"America/Chicago"}
        }]
        """
    let photo = Data("ticket-three-photo".utf8)
    let photosDirectory = fixture.directory.appendingPathComponent("photos")
    try FileManager.default.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
    try photo.write(to: photosDirectory.appendingPathComponent("\(photoID).photo"))
    try Data(original.utf8).write(to: fixture.directory.appendingPathComponent("drafts.json"))

    let upgraded = fixture.open()
    upgraded.restoreSession()
    #expect(upgraded.drafts.first?.notes == "Leftover soup")
    #expect(upgraded.drafts.first?.photo?.capturedAt == captureInstant)
    #expect(try upgraded.photoData(for: draftID) == photo)
    #expect(throws: MealReviewIssue.itemsRequired) { try upgraded.confirmMeal(draftID) }
    fixture.clock.advance(604_800)
    upgraded.resumeLocalWork()
    #expect(throws: DraftIssue.photoExpired) { try upgraded.photoData(for: draftID) }
    try upgraded.updateDraftItems(draftID, items: [MealItem(name: "Soup")])
    _ = try upgraded.confirmMeal(draftID)

    let reopened = fixture.open()
    reopened.restoreSession()
    #expect(reopened.drafts.isEmpty)
    #expect(reopened.loggedMeals.first?.id == draftID)
    #expect(reopened.loggedMeals.first?.record.mealTime.localDate == "2027-01-15")
    #expect(reopened.loggedMeals.first?.record.notes == "Leftover soup")
    #expect(reopened.loggedMeals.first?.record.nutrientTotals[.calories].isIncomplete == true)
    #expect(throws: DraftIssue.photoExpired) { try reopened.photoData(forLoggedMeal: draftID) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: photosDirectory.path).isEmpty)
}

@MainActor @Test func failedConfirmationKeepsTheReviewedDraftAndQueuesOnlyOneCreateOnRetry() throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let draft = try workflow.captureMeal(photoData: Data([1, 2, 3]))
    let item = MealItem(name: "Tea")
    try workflow.updateDraftItems(draft.id, items: [item])

    // A directory at the installed record path makes the atomic replacement fail.
    let records = fixture.directory.appendingPathComponent("drafts.json")
    let backup = fixture.directory.appendingPathComponent("saved-records")
    try FileManager.default.moveItem(at: records, to: backup)
    try FileManager.default.createDirectory(at: records, withIntermediateDirectories: false)
    #expect(throws: DraftIssue.storageUnavailable) { try workflow.confirmMeal(draft.id) }
    #expect(workflow.drafts.first?.review?.items == [item])
    #expect(workflow.loggedMeals.isEmpty)
    #expect(workflow.pendingMealChanges.isEmpty)
    try FileManager.default.removeItem(at: records)
    try FileManager.default.moveItem(at: backup, to: records)

    let reopened = fixture.open()
    reopened.restoreSession()
    #expect(reopened.drafts.first?.review?.items == [item])
    _ = try reopened.confirmMeal(draft.id)
    #expect(reopened.pendingMealChanges.map(\.id) == [draft.id])
}

@MainActor @Test func signedOutCleanupRemovesAnExpiredConfirmedPhotoWithoutExposingMealHistory() async throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let draft = try workflow.captureMeal(photoData: Data([1, 2, 3]))
    try workflow.updateDraftItems(draft.id, items: [MealItem(name: "Tea")])
    _ = try workflow.confirmMeal(draft.id)
    await workflow.signOut()
    #expect(workflow.loggedMeals.isEmpty)
    #expect(workflow.dailyMealSummaries.isEmpty)
    #expect(workflow.pendingMealChanges.isEmpty)
    #expect(throws: WorkflowIssue.accessDenied) { try workflow.photoData(forLoggedMeal: draft.id) }

    fixture.clock.advance(604_800)
    workflow.resumeLocalWork()
    let photos = fixture.directory.appendingPathComponent("photos")
    #expect(try FileManager.default.contentsOfDirectory(atPath: photos.path).isEmpty)
    let reopened = fixture.open()
    reopened.restoreSession()
    #expect(reopened.loggedMeals.first?.record.items.first?.name == "Tea")
    #expect(reopened.pendingMealChanges.map(\.id) == [draft.id])
    #expect(throws: DraftIssue.photoExpired) { try reopened.photoData(forLoggedMeal: draft.id) }
}

@MainActor @Test func confirmedMealRemainsPendingAcrossOfflineRestartAndLostSaveResponse() async throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let remote = ReplayableMealSyncFixture()
    let offline = fixture.open(mealSync: remote)
    offline.restoreSession()
    let draft = try offline.captureMeal(photoData: Data("private photo".utf8))
    let item = MealItem(name: "Tea", nutrients: NutrientAmounts(caloriesKcal: 0))
    try offline.updateDraftItems(draft.id, items: [item])
    await offline.syncPendingMealChanges()
    #expect(await remote.savedMeals().isEmpty)

    let logged = try offline.confirmMeal(draft.id)
    await offline.syncPendingMealChanges()
    #expect(offline.pendingMealChanges.map(\.id) == [logged.id])
    #expect(await remote.savedMeals().isEmpty)

    let reconnected = fixture.open(mealSync: remote, tokenExpiresAt: .distantFuture)
    reconnected.restoreSession()
    #expect(reconnected.pendingMealChanges.map(\.id) == [logged.id])
    await reconnected.syncPendingMealChanges()
    #expect(reconnected.pendingMealChanges.map(\.id) == [logged.id])
    #expect(await remote.savedMeals() == [logged.record])

    let reopened = fixture.open(mealSync: remote, tokenExpiresAt: .distantFuture)
    reopened.restoreSession()
    await reopened.syncPendingMealChanges()
    #expect(reopened.pendingMealChanges.isEmpty)
    #expect(await remote.savedMeals() == [logged.record])
    let synced = fixture.open()
    synced.restoreSession()
    #expect(synced.pendingMealChanges.isEmpty)
    #expect(synced.loggedMeals == [logged])
}

private actor ReplayableMealSyncFixture: MealSyncClient {
    private var meals: [UUID: MealRecord] = [:]

    func sync(_ change: PendingMealChange, accessToken: String) async throws -> MealSyncAcknowledgement {
        guard case .save(let meal, _) = change else { throw MealSyncFailure.rejected }
        if meals.updateValue(meal, forKey: meal.id) == nil {
            // The server committed, but the app lost the response.
            throw URLError(.networkConnectionLost)
        }
        return MealSyncAcknowledgement(id: change.id, revision: change.revision)
    }

    func savedMeals() -> [MealRecord] { Array(meals.values) }
}

@MainActor @Test func observationLinkWaitsForTheMealAndLatestUnlinkSurvivesARestart() async throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let mealSync = AcceptingMealSyncFixture()
    let observationSync = RecordingObservationSyncFixture()
    let workflow = fixture.open(mealSync: mealSync, tokenExpiresAt: .distantFuture, observationSync: observationSync)
    workflow.restoreSession()

    let urge = try workflow.logUrge(notes: "Before lunch")
    let draft = try workflow.startManualDraft(linkingUrgeID: urge.id)
    try workflow.updateDraftItems(draft.id, items: [MealItem(name: "Lunch")])
    let meal = try workflow.confirmMeal(draft.id)

    await workflow.syncPendingObservationChanges()
    #expect(await observationSync.changes.isEmpty)
    await workflow.syncPendingMealChanges()
    await workflow.syncPendingObservationChanges()
    let linked = try #require(workflow.loggedObservations.first?.record)
    #expect(linked.mealID == meal.id)
    #expect(await observationSync.changes == [.save(linked, revision: 2)])

    try workflow.updateObservation(urge.id, time: linked.time, severity: .moderate, notes: linked.notes)
    try workflow.deleteLoggedMeal(meal.id)
    let reopened = fixture.open(mealSync: mealSync, tokenExpiresAt: .distantFuture, observationSync: observationSync)
    reopened.restoreSession()
    let unlinked = try #require(reopened.loggedObservations.first?.record)
    #expect(unlinked.mealID == nil)
    await reopened.syncPendingMealChanges()
    await reopened.syncPendingObservationChanges()
    #expect(await observationSync.changes == [.save(linked, revision: 2), .save(unlinked, revision: 4)])
    #expect(reopened.pendingObservationChanges.isEmpty)
}

private struct AcceptingMealSyncFixture: MealSyncClient {
    func sync(_ change: PendingMealChange, accessToken: String) async throws -> MealSyncAcknowledgement {
        MealSyncAcknowledgement(id: change.id, revision: change.revision)
    }
}

private actor RecordingObservationSyncFixture: ObservationSyncClient {
    private(set) var changes: [PendingObservationChange] = []

    func sync(_ change: PendingObservationChange, accessToken: String) async throws -> MealSyncAcknowledgement {
        changes.append(change)
        return MealSyncAcknowledgement(id: change.id, revision: change.revision)
    }
}

@MainActor @Test func observationUploadsMatchTheSupabaseWireContract() async throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let config = try SupabaseConfiguration(url: #require(URL(string: "https://observation-sync.test.invalid")),
                                           publishableKey: "sb_publishable_test")
    let network = URLSessionConfiguration.ephemeral
    network.protocolClasses = [ObservationSyncFixtureProtocol.self]
    let remote = SupabaseObservationSyncClient(configuration: config, session: URLSession(configuration: network))
    let workflow = fixture.open(tokenExpiresAt: .distantFuture, observationSync: remote)
    workflow.restoreSession()
    let time = MealTime(instant: captureInstant, timeZone: TimeZone(identifier: "America/Chicago")!)
    let logged = try workflow.logSymptom(.headache, time: time, severity: .moderate, notes: "After lunch")

    await workflow.syncPendingObservationChanges()
    #expect(workflow.pendingObservationChanges.isEmpty)
    try workflow.deleteObservation(logged.id)
    await workflow.syncPendingObservationChanges()
    #expect(workflow.pendingObservationChanges.isEmpty)
}

private final class ObservationSyncFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "observation-sync.test.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let change = validChange()
        let status = change == nil ? 422 : 200
        let body = change.map { "{\"id\":\"\($0.id)\",\"revision\":\($0.revision)}" } ?? "{}"
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private func validChange() -> (id: String, revision: Int)? {
        guard request.url?.path == "/rest/v1/rpc/bitelens_sync_observation", request.httpMethod == "POST",
              request.value(forHTTPHeaderField: "apikey") == "sb_publishable_test",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer offline-test",
              let data = request.syncBody(),
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(body.keys) == ["p_observation", "p_observation_id", "p_user_id", "p_revision"],
              let id = body["p_observation_id"] as? String, UUID(uuidString: id) != nil,
              let ownerID = body["p_user_id"] as? String, UUID(uuidString: ownerID) == draftOwner,
              let revision = body["p_revision"] as? Int else { return nil }
        if revision == 2, body["p_observation"] is NSNull { return (id, revision) }
        guard revision == 1, let record = body["p_observation"] as? [String: Any],
              Set(record.keys) == ["id", "user_id", "kind", "symptom_id", "observed_at_epoch_seconds",
                                   "local_date", "time_zone", "level", "notes"],
              record["id"] as? String == id, record["user_id"] as? String == ownerID,
              record["kind"] as? String == "symptom", record["symptom_id"] as? String == "headache",
              record["observed_at_epoch_seconds"] as? Double == 1_800_000_000,
              record["local_date"] as? String == "2027-01-15", record["time_zone"] as? String == "America/Chicago",
              record["level"] as? String == "moderate", record["notes"] as? String == "After lunch"
        else { return nil }
        return (id, revision)
    }
}

@MainActor @Test func confirmedStructuredMealUsesTheSupabaseWireContractAndRefreshesARejectedToken() async throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let config = try SupabaseConfiguration(url: #require(URL(string: "https://meal-sync.test.invalid")),
                                           publishableKey: "sb_publishable_test")
    let network = URLSessionConfiguration.ephemeral
    network.protocolClasses = [MealSyncFixtureProtocol.self]
    let remote = SupabaseMealSyncClient(configuration: config, session: URLSession(configuration: network))
    let workflow = fixture.open(mealSync: remote, tokenExpiresAt: .distantFuture, auth: MealSyncRefreshAuth())
    workflow.restoreSession()
    let draft = try workflow.captureMeal(photoData: Data("secret photo".utf8), timeZone: TimeZone(identifier: "America/Chicago")!)
    try workflow.updateDraftNotes(draft.id, notes: "One serving")
    var tea = MealItem(name: "Tea", description: "Unsweetened", portion: ConsumedPortion(servingDescription: "One glass"),
                       nutrients: NutrientAmounts(caloriesKcal: 0, sodiumMilligrams: 2.5,
                                                  alcoholGrams: 0, caffeineMilligrams: 25, addedSugarGrams: 0))
    tea.portion.count = 1.5
    #expect(tea.nutrients.caffeineMilligrams == 25)
    try workflow.updateDraftItems(draft.id, items: [tea])
    _ = try workflow.confirmMeal(draft.id)
    await workflow.syncPendingMealChanges()
    #expect(workflow.pendingMealChanges.isEmpty)
    try workflow.deleteLoggedMeal(draft.id)
    #expect(workflow.pendingMealChanges == [.delete(id: draft.id, ownerID: draftOwner, revision: 2)])
    await workflow.syncPendingMealChanges()
    #expect(workflow.pendingMealChanges.isEmpty)
}

private struct MealSyncRefreshAuth: AuthenticationClient {
    func signIn(email: String, password: String) async throws -> AuthSession { throw AuthenticationFailure.unavailable }
    func refresh(refreshToken: String) async throws -> AuthSession {
        AuthSession(userID: draftOwner, accessToken: "refreshed-sync-test", refreshToken: "fixture",
                    expiresAt: .distantFuture)
    }
    func signOut(accessToken: String) async throws {}
}

private final class MealSyncFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "meal-sync.test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "Authorization")
        let change = confirmedChange()
        let status: Int
        let body: String
        switch (token, change) {
        case ("Bearer offline-test", .some):
            status = 401
            body = "{}"
        case ("Bearer refreshed-sync-test", let .some((id, revision))):
            status = 200
            body = "{\"id\":\"\(id)\",\"revision\":\(revision)}"
        default:
            status = 422
            body = "{}"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private func confirmedChange() -> (String, Int)? {
        guard request.url?.path == "/rest/v1/rpc/bitelens_sync_meal", request.httpMethod == "POST",
              request.value(forHTTPHeaderField: "apikey") == "sb_publishable_test",
              let data = request.syncBody(),
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(body.keys) == ["p_meal", "p_meal_id", "p_user_id", "p_revision"],
              let id = body["p_meal_id"] as? String, UUID(uuidString: id) != nil,
              (body["p_user_id"] as? String).flatMap(UUID.init(uuidString:)) == draftOwner,
              let revision = body["p_revision"] as? Int
        else { return nil }
        if revision == 2, body["p_meal"] is NSNull { return (id, revision) }
        guard revision == 1, let meal = body["p_meal"] as? [String: Any],
              id == meal["id"] as? String,
              body["p_user_id"] as? String == meal["user_id"] as? String,
              Set(meal.keys) == ["id", "user_id", "meal_at_epoch_seconds", "local_date", "time_zone",
                                 "confirmed_at_epoch_seconds", "notes", "items"],
              (meal["user_id"] as? String).flatMap(UUID.init(uuidString:)) == draftOwner,
              meal["meal_at_epoch_seconds"] as? Double == 1_800_000_000,
              meal["confirmed_at_epoch_seconds"] as? Double == 1_800_000_000,
              meal["time_zone"] as? String == "America/Chicago", meal["local_date"] as? String == "2027-01-15",
              meal["notes"] as? String == "One serving",
              let items = meal["items"] as? [[String: Any]], items.count == 1, let item = items.first,
              Set(item.keys) == ["id", "name", "description", "serving_description", "calories_kcal", "sodium_milligrams",
                                 "consumed_count", "alcohol_grams", "caffeine_milligrams", "added_sugar_grams", "item_origin"],
              item["name"] as? String == "Tea", item["description"] as? String == "Unsweetened",
              item["serving_description"] as? String == "One glass",
              item["calories_kcal"] as? Double == 0, item["sodium_milligrams"] as? Double == 2.5,
              item["consumed_count"] as? Double == 1.5, item["item_origin"] as? String == "manual",
              item["alcohol_grams"] as? Double == 0, item["caffeine_milligrams"] as? Double == 25,
              item["added_sugar_grams"] as? Double == 0
        else { return nil }
        return (id, revision)
    }

}

private extension URLRequest {
    func syncBody() -> Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            bytes.append(buffer, count: count)
        }
        return bytes
    }
}

@MainActor @Test func acknowledgingOneMealPreservesConfirmationsMadeDuringItsRequest() async throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let remote = SuspendedMealSyncFixture()
    let workflow = fixture.open(mealSync: remote, tokenExpiresAt: .distantFuture)
    workflow.restoreSession()
    let first = try workflow.captureMeal(photoData: Data([1]))
    try workflow.updateDraftItems(first.id, items: [MealItem(name: "Lunch")])
    _ = try workflow.confirmMeal(first.id)

    let upload = Task { await workflow.syncPendingMealChanges() }
    await remote.waitUntilStarted()
    let next = try workflow.captureMeal(photoData: Data([2]))
    try workflow.updateDraftItems(next.id, items: [MealItem(name: "Dinner")])
    _ = try workflow.confirmMeal(next.id)
    await remote.acknowledge()
    await upload.value

    let restored = fixture.open()
    restored.restoreSession()
    #expect(Set(restored.loggedMeals.map(\.id)) == [first.id, next.id])
    #expect(restored.pendingMealChanges.map(\.id) == [next.id])
}

private actor SuspendedMealSyncFixture: MealSyncClient {
    private var upload: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func sync(_ change: PendingMealChange, accessToken: String) async throws -> MealSyncAcknowledgement {
        await withCheckedContinuation { continuation in
            upload = continuation
            started?.resume()
            started = nil
        }
        return MealSyncAcknowledgement(id: change.id, revision: change.revision)
    }

    func waitUntilStarted() async {
        guard upload == nil else { return }
        await withCheckedContinuation { started = $0 }
    }

    func acknowledge() {
        upload?.resume()
        upload = nil
    }
}

@MainActor @Test(arguments: AIProvider.allCases)
func correctedEstimatePortionsUpdateLocalTotalsAndSurviveOfflineConfirmation(provider: AIProvider) async throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    await #expect(throws: WorkflowIssue.authenticationUnavailable) { try await workflow.accessToken() }
    #expect(workflow.cloudStatus == .offline)

    let draft = try workflow.captureMeal(photoData: Data([1]))
    try workflow.updateDraftNotes(draft.id, notes: "Left some on the plate")
    let provenance = EstimateProvenance(provider: provider, model: "fixture-model")
    let original = MealItem(name: "Rice", portion: ConsumedPortion(grams: 100, servingDescription: "One scoop"),
                            nutrients: NutrientAmounts(caloriesKcal: 130, proteinGrams: 3, fatGrams: 0))
    try workflow.applyEstimate(MealEstimate(items: [original], provenance: provenance), to: draft.id)

    var item = try #require(workflow.drafts.first?.review?.items.first)
    item.portion.grams = 50
    try workflow.updateDraftItems(draft.id, items: [item])
    let half = try #require(workflow.drafts.first?.review)
    #expect(half.items.first?.nutrients[.protein] == 1.5)
    #expect(half.nutrientTotals[.calories] == NutrientTotal(knownAmount: 65, isIncomplete: false))
    #expect(workflow.dailyMealSummaries.isEmpty)

    item = try #require(half.items.first)
    item.portion.grams = 200
    try workflow.updateDraftItems(draft.id, items: [item])
    let restored = fixture.open()
    restored.restoreSession()
    let review = try #require(restored.drafts.first?.review)
    #expect(review.items.first?.id == original.id)
    #expect(review.items.first?.portion == ConsumedPortion(grams: 200, servingDescription: "One scoop"))
    #expect(review.items.first?.nutrients[.protein] == 6)
    #expect(review.nutrientTotals[.calories] == NutrientTotal(knownAmount: 260, isIncomplete: false))
    #expect(review.nutrientTotals[.fat] == NutrientTotal(knownAmount: 0, isIncomplete: false))
    #expect(review.nutrientTotals[.fiber] == NutrientTotal(knownAmount: nil, isIncomplete: true))

    _ = try restored.confirmMeal(draft.id)
    let reopened = fixture.open()
    reopened.restoreSession()
    let logged = try #require(reopened.loggedMeals.first?.record)
    #expect(logged.items == review.items)
    #expect(logged.notes == "Left some on the plate")
    #expect(logged.estimateProvenance == provenance)
    #expect(reopened.dailyMealSummaries.first?.nutrientTotals == review.nutrientTotals)
}

@MainActor @Test func repeatedManualCorrectionsKeepIndependentNutrientBaselinesAcrossRestart() throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let draft = try workflow.captureMeal(photoData: Data([1]))
    let original = MealItem(name: "Spice blend", portion: ConsumedPortion(grams: 7),
                            nutrients: NutrientAmounts(caloriesKcal: 35, proteinGrams: 14.3, fiberGrams: 2,
                                                       sodiumMilligrams: 9))
    try workflow.updateDraftItems(draft.id, items: [original])

    var item = try #require(workflow.drafts.first?.review?.items.first)
    item.portion.grams = 1
    item.nutrients[.calories] = 6
    item.nutrients[.fiber] = nil
    try workflow.updateDraftItems(draft.id, items: [item])

    let restored = fixture.open()
    restored.restoreSession()
    item = try #require(restored.drafts.first?.review?.items.first)
    item.portion.grams = 7
    try restored.updateDraftItems(draft.id, items: [item])
    #expect(restored.drafts.first?.review?.items.first?.nutrients[.protein] == 14.3)
    #expect(restored.drafts.first?.review?.nutrientTotals[.calories].knownAmount == 42)
    #expect(restored.drafts.first?.review?.nutrientTotals[.fiber].isIncomplete == true)

    item.portion.grams = 0
    item.setNutrientAmount(0, for: .sodium)
    try restored.updateDraftItems(draft.id, items: [item])
    #expect(restored.drafts.first?.review?.nutrientTotals[.calories].knownAmount == 0)
    #expect(restored.drafts.first?.review?.nutrientTotals[.protein].knownAmount == 0)

    let reopened = fixture.open()
    reopened.restoreSession()
    item = try #require(reopened.drafts.first?.review?.items.first)
    item.portion.grams = 14
    try reopened.updateDraftItems(draft.id, items: [item])
    let logged = try reopened.confirmMeal(draft.id)
    #expect(logged.record.items.first?.nutrients[.calories] == 84)
    #expect(logged.record.items.first?.nutrients[.protein] == 28.6)
    #expect(logged.record.items.first?.nutrients[.fiber] == nil)
    #expect(logged.record.items.first?.nutrients[.sodium] == 0)
    #expect(logged.record.estimateProvenance == nil)
}

@MainActor @Test(arguments: [Double?.none, 0])
func enteringWeightWithoutAUsableBaselineKeepsExistingNutrients(initialWeight: Double?) throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let draft = try workflow.captureMeal(photoData: Data([1]))
    let original = MealItem(name: "Soup", portion: ConsumedPortion(grams: initialWeight),
                            nutrients: NutrientAmounts(caloriesKcal: 100, fatGrams: 0))
    try workflow.updateDraftItems(draft.id, items: [original])

    var item = try #require(workflow.drafts.first?.review?.items.first)
    item.portion.grams = 50
    try workflow.updateDraftItems(draft.id, items: [item])
    #expect(workflow.drafts.first?.review?.items.first?.nutrients == original.nutrients)

    item.portion.grams = nil
    try workflow.updateDraftItems(draft.id, items: [item])
    #expect(workflow.drafts.first?.review?.items.first?.nutrients == original.nutrients)

    let reopened = fixture.open()
    reopened.restoreSession()
    item = try #require(reopened.drafts.first?.review?.items.first)
    item.portion.grams = 100
    try reopened.updateDraftItems(draft.id, items: [item])
    let logged = try reopened.confirmMeal(draft.id)
    #expect(logged.record.items.first?.portion.grams == 100)
    #expect(logged.record.items.first?.nutrients == NutrientAmounts(caloriesKcal: 200, fatGrams: 0))
    #expect(reopened.dailyMealSummaries.first?.nutrientTotals[.protein].isIncomplete == true)
}

@MainActor @Test func offlineMealEditMovesDayAndKeepsProvenanceAcrossRestart() async throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let draft = try workflow.captureMeal(photoData: Data([1]), timeZone: .gmt)
    let rice = MealItem(name: "Rice", portion: .init(grams: 100), nutrients: .init(caloriesKcal: 200))
    let provenance = EstimateProvenance(provider: .grok, model: "fixture-grok", version: "fixture-v1")
    try workflow.applyEstimate(MealEstimate(items: [rice, MealItem(name: "Remove me")], provenance: provenance), to: draft.id)
    let original = try workflow.confirmMeal(draft.id)
    fixture.clock.advance(168 * 60 * 60)
    workflow.resumeLocalWork()

    let nextDay = MealTime(instant: draft.mealTime.instant.addingTimeInterval(86_400), timeZone: .gmt)
    var corrected = rice
    corrected.name = "Brown rice"
    corrected.description = "Homemade"
    corrected.portion.grams = 50
    corrected.setNutrientAmount(3, for: .protein)
    let tea = MealItem(name: "Tea", nutrients: .init(caloriesKcal: 0))
    let edited = try workflow.updateLoggedMeal(draft.id, mealTime: nextDay, notes: "Left half", items: [corrected, tea])
    #expect(workflow.dailyMealSummaries.map(\.localDate) == [nextDay.localDate])
    #expect(workflow.dailyMealSummaries.first?.nutrientTotals[.calories] == .init(knownAmount: 100, isIncomplete: false))
    #expect(workflow.dailyMealSummaries.first?.nutrientTotals[.protein] == .init(knownAmount: 3, isIncomplete: true))
    #expect(edited.photo == original.photo)
    #expect(edited.record.confirmedAt == original.record.confirmedAt)
    #expect(edited.record.estimateProvenance == provenance)
    #expect(throws: DraftIssue.photoExpired) { try workflow.photoData(forLoggedMeal: draft.id) }

    let reopened = fixture.open()
    reopened.restoreSession()
    #expect(reopened.loggedMeals == [edited])
    #expect(reopened.pendingMealChanges == [.save(edited.record, revision: 2)])
    let summary = reopened.nutrientHistory(for: .calories, in: .allTime, asOf: fixture.clock.date, timeZone: .gmt)
    #expect(summary.summaries.first?.high?.localDate == nextDay.localDate)
    #expect(summary.summaries.first?.average == 100)
    try reopened.deleteLoggedMeal(draft.id)
    #expect(reopened.dailyMealSummaries.isEmpty)
    #expect(reopened.nutrientHistory(for: .calories, in: .allTime, asOf: fixture.clock.date,
                                      timeZone: .gmt).summaries.isEmpty)
    let afterDelete = fixture.open()
    afterDelete.restoreSession()
    #expect(afterDelete.loggedMeals.isEmpty)
    #expect(afterDelete.pendingMealChanges == [.delete(id: draft.id, ownerID: draftOwner, revision: 3)])
}

@MainActor @Test func acknowledgingAnOlderSnapshotKeepsTheNewerDeletionPending() async throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let remote = SuspendedMealSyncFixture()
    let workflow = fixture.open(mealSync: remote, tokenExpiresAt: .distantFuture)
    workflow.restoreSession()
    let draft = try workflow.captureMeal(photoData: Data([1]))
    try workflow.updateDraftItems(draft.id, items: [MealItem(name: "Lunch")])
    let meal = try workflow.confirmMeal(draft.id)
    let upload = Task { await workflow.syncPendingMealChanges() }
    await remote.waitUntilStarted()
    _ = try workflow.updateLoggedMeal(meal.id, mealTime: meal.record.mealTime, notes: "Edited", items: meal.record.items)
    try workflow.deleteLoggedMeal(meal.id)
    await remote.acknowledge()
    await upload.value

    let restored = fixture.open()
    restored.restoreSession()
    #expect(restored.pendingMealChanges == [.delete(id: meal.id, ownerID: draftOwner, revision: 3)])
    #expect(restored.loggedMeals.isEmpty)
}

@MainActor @Test(arguments: [false, true])
func aChangeSupersededDuringTokenRefreshWaitsForTheNextDrain(rejectedInitialToken: Bool) async throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let auth = SuspendedMealSyncRefresh()
    let remote = RecordingMealSync(rejectsFirstAttempt: rejectedInitialToken)
    let workflow = fixture.open(mealSync: remote, tokenExpiresAt: rejectedInitialToken ? .distantFuture : .distantPast,
                                auth: auth)
    workflow.restoreSession()
    let draft = try workflow.captureMeal(photoData: Data([1]))
    try workflow.updateDraftItems(draft.id, items: [MealItem(name: "Lunch")])
    let meal = try workflow.confirmMeal(draft.id)

    let upload = Task { await workflow.syncPendingMealChanges() }
    await auth.waitForRefresh()
    let edited = try workflow.updateLoggedMeal(meal.id, mealTime: meal.record.mealTime, notes: "Edited",
                                               items: meal.record.items)
    await auth.completeRefresh()
    await upload.value

    let firstDrain: [PendingMealChange] = rejectedInitialToken ? [.save(meal.record, revision: 1)] : []
    let correction = PendingMealChange.save(edited.record, revision: 2)
    #expect(await remote.changes == firstDrain)
    let reopened = fixture.open()
    reopened.restoreSession()
    #expect(reopened.pendingMealChanges == [correction])
    await workflow.syncPendingMealChanges()
    #expect(await remote.changes == firstDrain + [correction])
    #expect(workflow.pendingMealChanges.isEmpty)
}

private actor SuspendedMealSyncRefresh: AuthenticationClient {
    private var completion: CheckedContinuation<AuthSession, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func signIn(email: String, password: String) async throws -> AuthSession { throw AuthenticationFailure.unavailable }
    func signOut(accessToken: String) async throws {}

    func refresh(refreshToken: String) async throws -> AuthSession {
        await withCheckedContinuation { continuation in
            completion = continuation
            started?.resume()
            started = nil
        }
    }

    func waitForRefresh() async {
        if completion == nil { await withCheckedContinuation { started = $0 } }
    }

    func completeRefresh() {
        completion?.resume(returning: AuthSession(userID: draftOwner, accessToken: "renewed", refreshToken: "renewed",
                                                   expiresAt: .distantFuture))
        completion = nil
    }
}

private actor RecordingMealSync: MealSyncClient {
    let rejectsFirstAttempt: Bool
    private(set) var changes: [PendingMealChange] = []

    init(rejectsFirstAttempt: Bool) { self.rejectsFirstAttempt = rejectsFirstAttempt }

    func sync(_ change: PendingMealChange, accessToken: String) async throws -> MealSyncAcknowledgement {
        changes.append(change)
        if rejectsFirstAttempt, changes.count == 1 { throw MealSyncFailure.authenticationRequired }
        return MealSyncAcknowledgement(id: change.id, revision: change.revision)
    }
}

@MainActor @Test func legacyPendingCreateAndSyncedMealsKeepTheirOriginalRevision() throws {
    let fixture = try DraftFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let first = try workflow.captureMeal(photoData: Data([1]))
    try workflow.updateDraftItems(first.id, items: [MealItem(name: "Tea")])
    let pending = try workflow.confirmMeal(first.id)
    let second = try workflow.captureMeal(photoData: Data([2]))
    try workflow.updateDraftItems(second.id, items: [MealItem(name: "Rice")])
    let synced = try workflow.confirmMeal(second.id)
    let records = fixture.directory.appendingPathComponent("drafts.json")
    let previous = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: records)) as? [String: Any])
    let loggedMeals = try #require(previous["loggedMeals"] as? [[String: Any]])
    let legacy = try loggedMeals.map { meal in
        var oldMeal = meal.filter { $0.key != "revision" }
        var record = try #require(meal["record"] as? [String: Any])
        let items = try #require(record["items"] as? [[String: Any]])
        record["items"] = items.map { $0.filter { $0.key != "origin" } }
        oldMeal["record"] = record
        return oldMeal
    }
    try JSONSerialization.data(withJSONObject: [
        "drafts": [], "loggedMeals": legacy,
        "pendingCreates": [["meal": try #require(legacy[0]["record"])]],
    ]).write(to: records)

    let restored = fixture.open()
    restored.restoreSession()
    #expect(Set(restored.loggedMeals.map(\.id)) == [pending.id, synced.id])
    #expect(restored.loggedMeals.allSatisfy { $0.revision == 1 })
    #expect(restored.pendingMealChanges == [.save(try #require(restored.loggedMeals.first { $0.id == pending.id }).record, revision: 1)])
    #expect(restored.loggedMeals.allSatisfy { $0.record.items.first?.origin == nil })
    let olderItem = try #require(restored.loggedMeals.first { $0.id == synced.id }?.record.items.first)
    let correction = try restored.updateLoggedMeal(synced.id, mealTime: synced.record.mealTime,
                                                     notes: "Corrected", items: [olderItem])
    #expect(correction.revision == 2)
    #expect(correction.record.estimateProvenance == nil)
    #expect(correction.record.items.first?.origin == nil)
}
