@testable import BiteLensCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@MainActor @Test(arguments: [true, false])
func importedReceiptKeepsPurchaseQuantityAndSeparatesMealTimeFromExpiry(hasOrderTime: Bool) async throws {
    let fixture = try AnalysisFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let draft = try workflow.importMealImage(fixturePhoto, timeZone: .gmt)
    #expect(draft.needsMealTime)
    #expect(draft.photo?.expiresAt == fixtureInstant.addingTimeInterval(604_800))
    #expect(draft.review == nil)
    try workflow.updateDraftNotes(draft.id, notes: hasOrderTime ? "Receipt fixture" : "Undated receipt fixture")
    try await workflow.analyzeDraft(draft.id)
    let estimate = try #require(workflow.drafts.first)
    #expect(estimate.needsMealTime == !hasOrderTime)
    if hasOrderTime {
        #expect(estimate.mealTime.localDate == "2026-10-14")
        try workflow.updateDraftNotes(draft.id, notes: "Undated receipt fixture")
        try await workflow.analyzeDraft(draft.id)
        #expect(workflow.drafts.first?.needsMealTime == true)
        try workflow.updateDraftNotes(draft.id, notes: "Receipt fixture")
    } else {
        #expect(throws: DraftIssue.mealTimeRequired) { try workflow.confirmMeal(draft.id) }
    }

    let chosenTime = Date(timeIntervalSince1970: 1_792_019_400)
    try workflow.setMealTime(draft.id, instant: chosenTime, timeZone: .gmt)
    try await workflow.analyzeDraft(draft.id)
    #expect(workflow.drafts.first?.mealTime.instant == chosenTime)

    let offline = fixture.open(online: false)
    offline.restoreSession()
    let review = try #require(offline.drafts.first?.review)
    var item = try #require(review.items.first)
    #expect(item.portion.count == 5)
    #expect(review.purchasedQuantity(for: item.id) == 5)
    item.portion.count = 3
    try offline.updateDraftItems(draft.id, items: [item])
    #expect(offline.drafts.first?.review?.purchasedQuantity(for: item.id) == 5)
    fixture.clock.advance(604_800)
    #expect(throws: DraftIssue.photoExpired) { try offline.photoData(for: draft.id) }
    let meal = try offline.confirmMeal(draft.id)
    #expect(meal.record.mealTime.instant == chosenTime)
    #expect(meal.record.items.first?.portion.count == 3)
    #expect(meal.record.items.first?.nutrients.caloriesKcal == 240)
}

@MainActor @Test func receiptWithOnlyAnOrderTimeKeepsManualItems() async throws {
    let fixture = try AnalysisFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let draft = try workflow.importMealImage(fixturePhoto, timeZone: .gmt)
    let item = MealItem(name: "Spring rolls")
    try workflow.updateDraftItems(draft.id, items: [item])
    try workflow.updateDraftNotes(draft.id, notes: "Time-only receipt fixture")
    await #expect(throws: AnalysisIssue.itemsNotIdentified) { try await workflow.analyzeDraft(draft.id) }
    #expect(workflow.drafts.first?.mealTime.localDate == "2026-10-14")
    #expect(workflow.drafts.first?.review?.items == [item])
    #expect(try workflow.confirmMeal(draft.id).record.items == [item])
}

@MainActor @Test(arguments: AIProvider.allCases)
func receiptEmailTimeFillsMealTimeWhenProviderOmitsIt(_ provider: AIProvider) async throws {
    let fixture = try AnalysisFixture()
    defer { fixture.remove() }
    let workflow = fixture.open(provider: provider)
    workflow.restoreSession()
    let timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
    workflow.receiptEmailHeader = recognizedReceiptHeader
    let draft = try workflow.importMealImage(fixturePhoto, timeZone: timeZone)
    try workflow.updateDraftNotes(draft.id, notes: "Undated receipt fixture")
    try await workflow.analyzeDraft(draft.id)
    let analyzed = try #require(workflow.drafts.first)
    #expect(analyzed.usesImportDateForMealTime)
    #expect(analyzed.mealTime.instant == ISO8601DateFormatter().date(from: "2027-01-15T06:02:00Z"))
    #expect(analyzed.review?.items.count == 1)
}

@MainActor @Test func reopeningAReviewedReceiptFillsMissingTimeAndKeepsEdits() async throws {
    let fixture = try AnalysisFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
    workflow.receiptEmailHeader = recognizedReceiptHeader
    let draft = try workflow.importMealImage(fixturePhoto, timeZone: timeZone)
    try workflow.applyEstimate(MealEstimate(items: [MealItem(name: "Spring rolls")],
                                           provenance: EstimateProvenance(provider: .openAI, model: "fixture")), to: draft.id)
    var item = try #require(workflow.drafts.first?.review?.items.first)
    item.name = "Corrected spring rolls"
    try workflow.updateDraftItems(draft.id, items: [item])

    let reopened = fixture.open(online: false)
    reopened.restoreSession()
    reopened.receiptEmailHeader = recognizedReceiptHeader
    await reopened.suggestReceiptTimeForReviewedDraft(draft.id)
    let restored = try #require(reopened.drafts.first)
    #expect(restored.usesImportDateForMealTime)
    #expect(restored.review?.items == [item])
}

// Vision's OCR output can vary across macOS versions. Exercise the production
// header parser and workflow with fixed observations.
private func recognizedReceiptHeader(_: Data) async -> String? {
    ReceiptImageTime.emailHeader(from: [
        ("6:15", CGRect(x: 0.16, y: 0.96, width: 0.1, height: 0.03)),
        ("3:02 PM", CGRect(x: 0.16, y: 0.69, width: 0.15, height: 0.03)),
        ("to me", CGRect(x: 0.16, y: 0.65, width: 0.12, height: 0.03)),
    ])
}

@MainActor @Test(arguments: [false, true])
func sharedReceiptUsesItsImportDayAfterAReopen(fromDocument: Bool) async throws {
    let fixture = try AnalysisFixture()
    defer { fixture.remove() }
    let inbox = SharedMealImageInbox(directory: fixture.directory.appendingPathComponent("Inbox"))
    try inbox.enqueue(fixturePhoto, sharedAt: fixtureInstant.addingTimeInterval(-604_800), timeZone: .gmt)
    let sharedAt = fixtureInstant.addingTimeInterval(-86_400)
    let id: UUID
    if fromDocument {
        let source = fixture.directory.appendingPathComponent("receipt.jpg")
        try fixturePhoto.write(to: source)
        id = try inbox.enqueueDocument(at: source, receivedAt: sharedAt, timeZone: .gmt)
        #expect(try Data(contentsOf: source) == fixturePhoto)
    } else {
        id = try inbox.enqueue(fixturePhoto, sharedAt: sharedAt, timeZone: .gmt)
    }

    let workflow = fixture.open(inbox: inbox)
    workflow.resumeLocalWork()
    #expect(workflow.drafts.isEmpty)
    workflow.restoreSession()
    #expect(workflow.drafts.map(\.id) == [id])
    #expect(workflow.sharedDraftToOpen == id)
    workflow.didOpenSharedDraft(id)
    workflow.resumeLocalWork()
    #expect(workflow.sharedDraftToOpen == nil)
    let draft = try #require(workflow.drafts.first)
    #expect(draft.photo?.retentionStartedAt == sharedAt)
    #expect(draft.review == nil)
    #expect(try workflow.photoData(for: id) == fixturePhoto)
    try workflow.updateDraftNotes(id, notes: "Shared receipt fixture")

    let reopened = fixture.open(inbox: inbox)
    reopened.restoreSession()
    #expect(reopened.drafts.map(\.id) == [id])
    try await reopened.analyzeDraft(id)
    let analyzed = try #require(reopened.drafts.first)
    #expect(analyzed.usesImportDateForMealTime)
    #expect(analyzed.mealTime.instant == ISO8601DateFormatter().date(from: "2027-01-14T15:02:00Z"))
    #expect(analyzed.review?.items.count == 1)
    #expect(reopened.loggedMeals.isEmpty)
}

@MainActor @Test(arguments: [true, false])
func importedImageUsesPhotoTimestampOnlyWhenItShowsFood(isFoodPhoto: Bool) async throws {
    let fixture = try AnalysisFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()

    let source = try #require(CGImageSourceCreateWithData(fixturePhoto as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let taggedPhoto = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(taggedPhoto, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifDateTimeOriginal: "2026:10:14 17:19:42",
    ]] as CFDictionary)
    try #require(CGImageDestinationFinalize(destination))

    let draft = try workflow.importMealImage(taggedPhoto as Data, timeZone: .gmt)
    try workflow.updateDraftNotes(draft.id, notes: isFoodPhoto ? "Food photo fixture" : "Undated receipt fixture")
    try await workflow.analyzeDraft(draft.id)
    let analyzed = try #require(workflow.drafts.first)
    #expect(analyzed.needsMealTime == !isFoodPhoto)
    if isFoodPhoto { #expect(analyzed.mealTime.localDate == "2026-10-14") }
}

@MainActor @Test func groupedEstimateScalesAndKeepsItsOriginalThroughLogging() async throws {
    let fixture = try AnalysisFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let draft = try workflow.captureMeal(photoData: fixturePhoto)
    try workflow.updateDraftNotes(draft.id, notes: "Spring rolls fixture")
    try await workflow.analyzeDraft(draft.id)
    var item = try #require(workflow.drafts.first?.review?.items.first)
    #expect(item.portion.count == 5)
    #expect(item.isCorrected == false)
    item.portion.count = 3
    #expect(item.portion.grams == 150)
    #expect(item.nutrients.caloriesKcal == 240)
    #expect(item.nutrients.addedSugarGrams == 3)
    #expect(item.nutrients.caffeineMilligrams == nil)
    #expect(item.nutrients.alcoholGrams == 0)
    try workflow.updateDraftItems(draft.id, items: [item])
    let offline = fixture.open(online: false)
    offline.restoreSession()
    let logged = try offline.confirmMeal(draft.id)
    var recorded = try #require(logged.record.items.first)
    #expect(recorded.originalEstimate?.nutrients.caloriesKcal == 400)
    #expect(recorded.isCorrected == true)
    #expect(offline.dailyMealSummaries.first?.nutrientTotals[.caffeine].isIncomplete == true)
    let change = try #require(offline.pendingMealChanges.first)
    let config = try SupabaseConfiguration(url: #require(URL(string: "https://analysis.test.invalid")),
                                           publishableKey: "sb_publishable_fixture")
    let network = URLSessionConfiguration.ephemeral
    network.protocolClasses = [AnalysisFixtureProtocol.self]
    let sync = SupabaseMealSyncClient(configuration: config, session: URLSession(configuration: network))
    let acknowledgement = try await sync.sync(change, accessToken: "fixture-token")
    #expect(acknowledgement == MealSyncAcknowledgement(id: logged.id, revision: 1))
    recorded.portion.count = 2.5
    #expect(recorded.portion.grams == 125)
    recorded.portion.count = 5
    let restored = try offline.updateLoggedMeal(logged.id, mealTime: logged.record.mealTime,
                                                notes: logged.record.notes, items: [recorded])
    #expect(restored.record.items.first?.isCorrected == false)
    recorded.portion.grams = 0
    recorded.portion.count = 2.5
    recorded.portion.grams = 125
    #expect(recorded.nutrients.caloriesKcal == 200)
}

@MainActor @Test(arguments: AIProvider.allCases) func selectedAnalysisSurvivesRestartAndConfirmsOfflineWithUnknownNutrients(_ provider: AIProvider) async throws {
    let fixture = try AnalysisFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    workflow.selectProvider(provider)
    let draft = try workflow.captureMeal(photoData: fixturePhoto, timeZone: .gmt)
    try workflow.updateDraftNotes(draft.id, notes: "Half a bowl")

    try await workflow.analyzeDraft(draft.id)
    #expect(workflow.loggedMeals.isEmpty)
    #expect(workflow.pendingMealChanges.isEmpty)

    let offline = fixture.open(online: false)
    offline.restoreSession()
    let restored = try #require(offline.drafts.first)
    let review = try #require(restored.review)
    #expect(review.estimateProvenance == EstimateProvenance(provider: provider, model: "fixture-\(provider.rawValue)-snapshot", version: "meal-estimate-v1/\(provider.rawValue)-v1"))
    #expect(review.nutrientTotals[.sodium] == NutrientTotal(knownAmount: nil, isIncomplete: true))
    #expect(review.nutrientTotals[.fiber] == NutrientTotal(knownAmount: 0, isIncomplete: false))
    var item = try #require(review.items.first)
    #expect(item.portion == ConsumedPortion(grams: 240, servingDescription: "1 cup"))
    item.name = "Homemade tomato soup"
    item.portion.grams = 120
    #expect(item.nutrients[.sodium] == nil)
    #expect(item.nutrients[.fiber] == 0)
    try offline.updateDraftItems(draft.id, items: [item])
    let logged = try offline.confirmMeal(draft.id)
    #expect(logged.record.items == [item])
    #expect(logged.record.notes == "Half a bowl")
    #expect(logged.record.mealTime.instant == fixtureInstant)
    #expect(offline.dailyMealSummaries.first?.nutrientTotals[.calories].knownAmount == 55)
}

@MainActor @Test(arguments: AIProvider.allCases) func retryFailuresPreserveCorrectedEstimateNotesAndOriginalPhoto(_ provider: AIProvider) async throws {
    let fixture = try AnalysisFixture()
    defer { fixture.remove() }
    let workflow = fixture.open(provider: provider)
    workflow.restoreSession()
    let draft = try workflow.captureMeal(photoData: fixturePhoto)
    try await workflow.analyzeDraft(draft.id)
    var corrected = try #require(workflow.drafts.first?.review?.items.first)
    corrected.name = "Corrected soup"
    try workflow.updateDraftItems(draft.id, items: [corrected])

    for (notes, failure) in [
        ("refused", AnalysisIssue.refused),
        ("timeout", .timedOut),
        ("offline", .unavailable),
        ("invalid", .invalidEstimate),
        ("invalid v2", .invalidEstimate),
        ("wrong provider", .invalidEstimate),
        ("unauthenticated", .reauthenticationRequired),
    ] {
        try workflow.updateDraftNotes(draft.id, notes: notes)
        let before = try #require(workflow.drafts.first)
        await #expect(throws: failure) { try await workflow.analyzeDraft(draft.id) }
        let reopened = fixture.open()
        reopened.restoreSession()
        #expect(reopened.drafts.first == before)
        #expect(try reopened.photoData(for: draft.id) == fixturePhoto)
    }
    #expect(workflow.cloudStatus == .reauthenticationRequired)
    try workflow.updateDraftNotes(draft.id, notes: "Half a bowl")
    try await workflow.analyzeDraft(draft.id)
    #expect(workflow.drafts.first?.review?.items.first?.name == "Soup")
}

@MainActor @Test func analysisRequiresASelectionAndChecksOriginalPhotoExpiryOnEveryRetry() async throws {
    let fixture = try AnalysisFixture()
    defer { fixture.remove() }
    let workflow = fixture.open(provider: nil)
    workflow.restoreSession()
    let draft = try workflow.captureMeal(photoData: fixturePhoto)
    await #expect(throws: AnalysisIssue.providerRequired) { try await workflow.analyzeDraft(draft.id) }

    workflow.selectProvider(.openAI)
    try await workflow.analyzeDraft(draft.id)
    fixture.clock.advance(168 * 60 * 60)
    await #expect(throws: DraftIssue.photoExpired) { try await workflow.analyzeDraft(draft.id) }
    #expect(workflow.drafts.first?.review?.items.first?.name == "Soup")
    #expect(try workflow.confirmMeal(draft.id).record.items.first?.name == "Soup")
}

@MainActor @Test(arguments: AIProvider.allCases)
func allowanceExhaustionPreservesTheDraftAndManualLogging(_ provider: AIProvider) async throws {
    let fixture = try AnalysisFixture()
    defer { fixture.remove() }
    let workflow = fixture.open(provider: provider)
    workflow.restoreSession()
    let draft = try workflow.captureMeal(photoData: fixturePhoto)
    try await workflow.analyzeDraft(draft.id)
    try workflow.updateDraftNotes(draft.id, notes: "allowance exhausted")
    let before = try #require(workflow.drafts.first)
    let reset = Date(timeIntervalSince1970: 1_800_057_600)

    await #expect(throws: AnalysisIssue.allowanceExhausted(resetAt: reset)) {
        try await workflow.analyzeDraft(draft.id)
    }
    #expect(workflow.drafts.first == before)

    var item = try #require(before.review?.items.first)
    item.name = "Manually reviewed soup"
    try workflow.updateDraftItems(draft.id, items: [item])
    #expect(try workflow.confirmMeal(draft.id).record.items.first?.name == "Manually reviewed soup")
    #expect(workflow.pendingMealChanges.count == 1)
}

@MainActor @Test func successfulAnalysisPreventsRetakesAndPreservesCorrectionsAfterRestart() async throws {
    let fixture = try AnalysisFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let draft = try workflow.captureMeal(photoData: fixturePhoto)
    try await workflow.analyzeDraft(draft.id)
    var item = try #require(workflow.drafts.first?.review?.items.first)
    item.name = "Corrected soup"
    try workflow.updateDraftItems(draft.id, items: [item])
    let reviewed = try #require(workflow.drafts.first)

    let reopened = fixture.open()
    reopened.restoreSession()
    #expect(throws: DraftIssue.retakeAfterEstimate) {
        try reopened.retakePhoto(for: draft.id, photoData: Data([42]))
    }
    #expect(reopened.drafts.first == reviewed)
    #expect(try reopened.photoData(for: draft.id) == fixturePhoto)
}

@MainActor @Test(arguments: [false, true])
func replacingTheLastEstimatedItemAfterRestartConfirmsAManualMeal(olderReview: Bool) async throws {
    let fixture = try AnalysisFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let draft = try workflow.captureMeal(photoData: fixturePhoto)
    try await workflow.analyzeDraft(draft.id)
    let estimate = try #require(workflow.drafts.first?.review)
    var corrected = try #require(estimate.items.first)
    corrected.name = "Homemade soup"
    let manual = MealItem(name: "Tea")

    if olderReview {
        let records = fixture.directory.appendingPathComponent("drafts.json")
        var library = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: records)) as? [String: Any])
        var drafts = try #require(library["drafts"] as? [[String: Any]])
        var review = try #require(drafts.first?["review"] as? [String: Any])
        review.removeValue(forKey: "originalEstimateItemIDs")
        drafts[0]["review"] = review
        library["drafts"] = drafts
        try JSONSerialization.data(withJSONObject: library).write(to: records)
        workflow.resumeLocalWork()
    }

    try workflow.updateDraftItems(draft.id, items: [corrected, manual])
    #expect(workflow.drafts.first?.review?.estimateProvenance == estimate.estimateProvenance)
    let reopened = fixture.open()
    reopened.restoreSession()
    try reopened.updateDraftItems(draft.id, items: [manual])
    #expect(reopened.drafts.first?.review?.estimateProvenance == nil)
    #expect(throws: DraftIssue.retakeAfterEstimate) {
        try reopened.retakePhoto(for: draft.id, photoData: Data([42]))
    }
    let logged = try reopened.confirmMeal(draft.id)
    #expect(logged.record.items == [manual])
    #expect(logged.record.estimateProvenance == nil)
    #expect(try reopened.photoData(forLoggedMeal: draft.id) == fixturePhoto)
}

@MainActor @Test func explicitRetryUsesAnotherProviderWithoutChangingTheDefaultOrLoggedMeals() async throws {
    let fixture = try AnalysisFixture()
    defer { fixture.remove() }
    let workflow = fixture.open(provider: .openAI)
    workflow.restoreSession()
    let first = try workflow.captureMeal(photoData: fixturePhoto)
    try await workflow.analyzeDraft(first.id)
    let saved = try workflow.confirmMeal(first.id)

    let next = try workflow.captureMeal(photoData: fixturePhoto)
    try await workflow.analyzeDraft(next.id)
    try await workflow.analyzeDraft(next.id, provider: .grok)
    #expect(workflow.drafts.first?.review?.estimateProvenance?.provider == .grok)
    #expect(workflow.selectedProvider == .openAI)
    #expect(workflow.loggedMeals.first == saved)

    workflow.selectProvider(.grok)
    let later = try workflow.captureMeal(photoData: fixturePhoto)
    try await workflow.analyzeDraft(later.id)
    #expect(workflow.drafts.first(where: { $0.id == later.id })?.review?.estimateProvenance?.provider == .grok)
    #expect(workflow.loggedMeals.first?.record.estimateProvenance?.provider == .openAI)
}

private let fixtureOwner = UUID(uuidString: "a1000000-0000-4000-8000-000000000001")!
private let fixtureInstant = Date(timeIntervalSince1970: 1_800_000_000)
let fixturePhoto = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAAAf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AH//Z")!
private let writtenMeal = "Five vegetable spring rolls"

@MainActor @Test(arguments: AIProvider.allCases)
func writtenMealDraftReopensAndConfirmsWithoutAPhoto(_ provider: AIProvider) async throws {
    let fixture = try AnalysisFixture()
    defer { fixture.remove() }
    let offline = fixture.open(online: false)
    offline.restoreSession()
    let draft = try offline.startManualDraft(timeZone: .gmt)
    #expect(draft.photo == nil)
    #expect(!draft.canRetakePhoto)
    #expect(draft.mealTime.instant == fixtureInstant)
    try offline.updateDraftNotes(draft.id, notes: writtenMeal)
    let mealTime = fixtureInstant.addingTimeInterval(-3_600)
    try offline.setMealTime(draft.id, instant: mealTime, timeZone: .gmt)

    fixture.clock.advance(604_800)
    let workflow = fixture.open(provider: provider)
    workflow.restoreSession()
    #expect(workflow.drafts.first?.notes == writtenMeal)
    #expect(workflow.nextPhotoExpiration == nil)
    try await workflow.analyzeDraft(draft.id)
    #expect(workflow.pendingMealChanges.isEmpty)
    #expect(workflow.loggedMeals.isEmpty)

    let reopened = fixture.open(online: false)
    reopened.restoreSession()
    let review = try #require(reopened.drafts.first?.review)
    #expect(review.estimateProvenance?.provider == provider)
    var item = try #require(review.items.first)
    #expect(item.portion.count == 5)
    #expect(review.purchasedQuantity(for: item.id) == nil)
    item.portion.count = 3
    try reopened.updateDraftItems(draft.id, items: [item])
    let meal = try reopened.confirmMeal(draft.id)
    #expect(meal.photo == nil)
    #expect(meal.record.notes == writtenMeal)
    #expect(meal.record.mealTime.instant == mealTime)
    #expect(meal.record.nutrientTotals[.calories].knownAmount == 240)
    #expect(reopened.pendingMealChanges.count == 1)
    let photos = fixture.directory.appendingPathComponent("photos")
    #expect(try FileManager.default.contentsOfDirectory(atPath: photos.path).isEmpty)

    let history = fixture.open(online: false)
    history.restoreSession()
    #expect(history.loggedMeals == [meal])
    #expect(throws: DraftIssue.photoUnavailable) { try history.photoData(forLoggedMeal: meal.id) }
    try history.deleteLoggedMeal(meal.id)
    #expect(history.loggedMeals.isEmpty)
}

@MainActor @Test func writtenAnalysisRejectsBlankInputAndKeepsExistingItemsWhenNothingIsIdentified() async throws {
    let fixture = try AnalysisFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let draft = try workflow.startManualDraft()
    try workflow.updateDraftNotes(draft.id, notes: " \n\t")
    await #expect(throws: AnalysisIssue.descriptionRequired) { try await workflow.analyzeDraft(draft.id) }
    try workflow.updateDraftNotes(draft.id, notes: String(repeating: "🍜", count: 1_001))
    await #expect(throws: AnalysisIssue.notesTooLong) { try await workflow.analyzeDraft(draft.id) }

    let item = MealItem(name: "Entered by hand")
    try workflow.updateDraftItems(draft.id, items: [item])
    try workflow.updateDraftNotes(draft.id, notes: "Nothing identifiable")
    await #expect(throws: AnalysisIssue.itemsNotIdentified) { try await workflow.analyzeDraft(draft.id) }
    #expect(workflow.drafts.first?.review?.items == [item])
    #expect(workflow.drafts.first?.notes == "Nothing identifiable")
    try workflow.discardDraft(draft.id)
    #expect(workflow.drafts.isEmpty)
}

@MainActor private struct AnalysisFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BiteLensAnalysis-\(UUID())")
    let clock = AnalysisClock()

    init() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }

    func open(online: Bool = true, provider: AIProvider? = .openAI, client: (any MealAnalysisClient)? = nil,
              inbox: SharedMealImageInbox? = nil) -> MealWorkflow {
        let config = try! SupabaseConfiguration(url: URL(string: "https://analysis.test.invalid")!, publishableKey: "sb_publishable_fixture")
        let network = URLSessionConfiguration.ephemeral
        network.protocolClasses = [AnalysisFixtureProtocol.self]
        let httpClient = SupabaseMealAnalysisClient(configuration: config, session: URLSession(configuration: network))
        let identity = AnalysisFixtureIdentity(online: online, provider: provider, now: clock.date)
        return MealWorkflow(auth: identity, sessionStore: identity, preferences: identity, approvedOwnerID: fixtureOwner,
                            now: { [clock] in clock.date }, analysis: online ? (client ?? httpClient) : nil,
                            draftStorage: LocalMealDraftStorage(directory: directory), sharedImageInbox: inbox)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private final class AnalysisClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = fixtureInstant
    var date: Date { lock.withLock { instant } }
    func advance(_ interval: TimeInterval) { lock.withLock { instant.addTimeInterval(interval) } }
}

private struct AnalysisFixtureIdentity: AuthenticationClient, SessionStore, ProviderPreferences {
    let online: Bool
    let provider: AIProvider?
    let now: Date
    func load() throws -> AuthSession? {
        AuthSession(userID: fixtureOwner, accessToken: "fixture-token", refreshToken: "fixture-refresh",
                    expiresAt: online ? now.addingTimeInterval(3_600) : .distantPast)
    }
    func save(_ session: AuthSession) throws {}
    func clear() throws {}
    func loadProvider() -> AIProvider? { provider }
    func saveProvider(_ provider: AIProvider) {}
    func signIn(email: String, password: String) async throws -> AuthSession { throw AuthenticationFailure.unavailable }
    func refresh(refreshToken: String) async throws -> AuthSession { throw AuthenticationFailure.unavailable }
    func signOut(accessToken: String) async throws {}
}

private final class AnalysisFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "analysis.test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        if request.url?.path == "/rest/v1/rpc/bitelens_sync_meal" {
            respondToGroupedMealSave()
            return
        }
        guard request.httpMethod == "POST", request.url?.path == "/functions/v1/analyze-meal",
              request.value(forHTTPHeaderField: "apikey") == "sb_publishable_fixture",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token",
              let body = try? JSONDecoder().decode(FixtureRequest.self, from: readBody())
        else { return respond(400, #"{"error":"invalid_request"}"#) }

        guard let provider = AIProvider(rawValue: body.provider) else {
            return respond(400, #"{"error":"invalid_provider"}"#)
        }
        if let description = body.description {
            guard body.captured_at_ms == nil, body.photo_base64 == nil, body.notes == nil else {
                return respond(400, #"{"error":"invalid_request"}"#)
            }
            switch description {
            case writtenMeal:
                respond(200, Self.textEstimate.replacingOccurrences(of: "openai", with: provider.rawValue))
            case "Nothing identifiable":
                respond(200, #"{"image_kind":null,"order_time":null,"items":[],"provenance":{"provider":"openai","model":"fixture","version":"meal-estimate-v3/openai-v4-text-v1"}}"#)
            default: respond(400, #"{"error":"invalid_request"}"#)
            }
            return
        }
        guard let notes = body.notes,
              body.captured_at_ms == (notes == "Shared receipt fixture" ? 1_799_913_600_000 : 1_800_000_000_000),
              let photo = body.photo_base64, let jpeg = Data(base64Encoded: photo),
              jpeg.starts(with: [0xff, 0xd8]), jpeg.suffix(2) == Data([0xff, 0xd9])
        else { return respond(400, #"{"error":"invalid_request"}"#) }

        let estimate = Self.estimate.replacingOccurrences(of: "openai", with: provider.rawValue)
        switch notes {
        case "refused": respond(422, #"{"error":"refused"}"#)
        case "timeout": client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        case "allowance exhausted": respond(429, #"{"error":"allowance_exhausted","reset_at":"2027-01-16T00:00:00.000Z"}"#)
        case "offline": client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case "invalid": respond(200, estimate.replacingOccurrences(of: #","sodium_mg":null"#, with: ""))
        case "invalid v2":
            let v2 = Self.springRollEstimate.replacingOccurrences(of: "openai", with: provider.rawValue)
            respond(200, v2.replacingOccurrences(of: #","caffeine_mg":null"#, with: ""))
        case "wrong provider": respond(200, estimate.replacingOccurrences(of: provider.rawValue, with: provider == .openAI ? "grok" : "openai"))
        case "unauthenticated": respond(401, #"{"error":"unauthenticated"}"#)
        case "Spring rolls fixture": respond(200, Self.springRollEstimate)
        case "Receipt fixture": respond(200, Self.receiptEstimate)
        case "Shared receipt fixture": respond(200, Self.receiptEstimate.replacingOccurrences(of: "2026-10-14T18:24", with: "15:02"))
        case "Undated receipt fixture":
            respond(200, Self.receiptEstimate.replacingOccurrences(of: #""2026-10-14T18:24""#, with: "null")
                .replacingOccurrences(of: "openai", with: provider.rawValue))
        case "Time-only receipt fixture": respond(200, Self.timeOnlyReceiptEstimate)
        case "Food photo fixture": respond(200, Self.foodPhotoEstimate)
        case "Half a bowl", "": respond(200, estimate)
        default: respond(400, #"{"error":"invalid_request"}"#)
        }
    }

    private static let estimate = """
        {"items":[{"name":"Soup","description":"Tomato soup","grams":240,"serving_description":"1 cup","nutrients":{"calories_kcal":110,"protein_g":3,"carbohydrates_g":18,"fat_g":2,"fiber_g":0,"sodium_mg":null}}],"provenance":{"provider":"openai","model":"fixture-openai-snapshot","version":"meal-estimate-v1/openai-v1"}}
        """

    private static let springRollEstimate = """
        {"items":[{"name":"Spring roll","description":"Vegetable spring rolls","grams":250,"count":5,"serving_description":"pieces","nutrients":{"calories_kcal":400,"protein_g":10,"carbohydrates_g":70,"fat_g":12,"fiber_g":5,"sodium_mg":300,"alcohol_g":0,"caffeine_mg":null,"added_sugar_g":5}}],"provenance":{"provider":"openai","model":"fixture-openai-snapshot","version":"meal-estimate-v2/openai-v2"}}
        """

    private static let receiptEstimate = springRollEstimate
        .replacingOccurrences(of: #"{"items""#, with: #"{"image_kind":"receipt","order_time":"2026-10-14T18:24","items""#)
        .replacingOccurrences(of: #""count":5"#, with: #""count":5,"purchased_quantity":5"#)
        .replacingOccurrences(of: "-v2", with: "-v3")

    private static let timeOnlyReceiptEstimate = """
        {"image_kind":"receipt","order_time":"2026-10-14T18:24","items":[],"provenance":{"provider":"openai","model":"fixture-openai-snapshot","version":"meal-estimate-v3/openai-v3"}}
        """

    private static let foodPhotoEstimate = receiptEstimate
        .replacingOccurrences(of: #""receipt","order_time":"2026-10-14T18:24""#, with: #""food_photo","order_time":null"#)
        .replacingOccurrences(of: #""purchased_quantity":5"#, with: #""purchased_quantity":null"#)

    private static let textEstimate = foodPhotoEstimate
        .replacingOccurrences(of: #""image_kind":"food_photo""#, with: #""image_kind":null"#)
        .replacingOccurrences(of: "openai-v3", with: "openai-v4-text-v1")

    private func respondToGroupedMealSave() {
        guard request.httpMethod == "POST",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token",
              let body = (try? JSONSerialization.jsonObject(with: readBody())) as? [String: Any],
              let id = (body["p_meal_id"] as? String).flatMap(UUID.init(uuidString:)),
              body["p_revision"] as? Int == 1,
              let meal = body["p_meal"] as? [String: Any],
              let items = meal["items"] as? [[String: Any]], items.count == 1, let item = items.first,
              item["item_origin"] as? String == "ai", item["consumed_count"] as? Double == 3,
              item["calories_kcal"] as? Double == 240, item["alcohol_grams"] as? Double == 0,
              let original = item["original_item_estimate"] as? [String: Any],
              original["consumed_count"] as? Double == 5, original["calories_kcal"] as? Double == 400,
              original["caffeine_milligrams"] == nil, original["id"] == nil
        else { return respond(422, "{}") }
        respond(200, #"{"id":"\#(id.uuidString)","revision":1}"#)
    }

    private struct FixtureRequest: Decodable {
        let provider: String
        let captured_at_ms: Int64?
        let photo_base64: String?
        let notes: String?
        let description: String?
    }

    private func respond(_ status: Int, _ body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private func readBody() -> Data {
        if let bytes = request.httpBody { return bytes }
        guard let stream = request.httpBodyStream else { return Data() }
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

@MainActor @Test func changingDraftDuringAnalysisKeepsNewerEditsAndPhoto() async throws {
    let fixture = try AnalysisFixture()
    defer { fixture.remove() }
    let provider = SuspendedMealAnalysis()
    let workflow = fixture.open(client: provider)
    workflow.restoreSession()
    let draft = try workflow.captureMeal(photoData: fixturePhoto)
    let running = Task { try await workflow.analyzeDraft(draft.id) }
    await provider.waitForRequest()

    #expect(workflow.isAnalyzingDraft(draft.id))
    await #expect(throws: AnalysisIssue.alreadyRunning) { try await workflow.analyzeDraft(draft.id) }
    let replacement = Data([42])
    try workflow.retakePhoto(for: draft.id, photoData: replacement)
    try workflow.updateDraftNotes(draft.id, notes: "Use the new photo")
    let item = MealItem(name: "Entered during analysis")
    try workflow.updateDraftItems(draft.id, items: [item])
    await provider.complete()
    await #expect(throws: AnalysisIssue.draftChanged) { try await running.value }

    #expect(workflow.isAnalyzingDraft(draft.id) == false)
    #expect(workflow.drafts.first?.notes == "Use the new photo")
    #expect(workflow.drafts.first?.review?.items == [item])
    #expect(try workflow.photoData(for: draft.id) == replacement)
}

private actor SuspendedMealAnalysis: MealAnalysisClient {
    private var completion: CheckedContinuation<MealEstimate, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func estimate(provider: AIProvider, input: MealAnalysisInput,
                  accessToken: String,
                  authorizeDispatch: @MainActor @Sendable () throws -> Void) async throws -> MealEstimate {
        try await authorizeDispatch()
        return await withCheckedContinuation { continuation in
            completion = continuation
            started?.resume()
            started = nil
        }
    }

    func waitForRequest() async {
        if completion == nil { await withCheckedContinuation { started = $0 } }
    }

    func complete() {
        completion?.resume(returning: MealEstimate(items: [MealItem(name: "Old photo result")],
                                                    provenance: EstimateProvenance(provider: .openAI, model: "fixture")))
        completion = nil
    }
}
