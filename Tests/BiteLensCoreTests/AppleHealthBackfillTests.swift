import BiteLensCore
import Foundation
import Testing

@MainActor @Test func backfillUsesRecordedLocalDaysAndKeepsEligibleMealsAfterTheWindowMoves() async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()

    // January 15 in UTC includes December 17, which starts earlier in Tokyo.
    let boundary = try Date.ISO8601FormatStyle().parse("2026-12-16T18:30:00Z")
    let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
    let included = try fixture.draft(in: workflow, items: [
        MealItem(name: "Drink", nutrients: NutrientAmounts(caloriesKcal: 0, alcoholGrams: 21)),
    ])
    try workflow.setMealTime(included.id, instant: boundary, timeZone: tokyo)
    let meal = try workflow.confirmMeal(included.id)
    let excluded = try fixture.draft(in: workflow)
    try workflow.setMealTime(excluded.id, instant: boundary, timeZone: .gmt)
    try workflow.confirmMeal(excluded.id)

    await #expect(throws: AppleHealthBackfillError.self) { try await workflow.backfillAppleHealth(timeZone: .gmt) }
    await fixture.health.setWriteAccess([])
    await workflow.setAppleHealthSyncEnabled(true)
    await #expect(throws: AppleHealthBackfillError.self) { try await workflow.backfillAppleHealth(timeZone: .gmt) }

    await fixture.health.setWriteAccess([.calories])
    await workflow.syncPendingAppleHealthChanges()
    #expect(await fixture.health.samples.isEmpty)
    #expect(try await workflow.backfillAppleHealth(timeZone: .gmt) == 1)
    await workflow.syncPendingAppleHealthChanges()
    #expect(await fixture.health.samples.map(\.mealID) == [included.id])
    #expect(await fixture.health.samples.map(\.amount) == [0])
    #expect(workflow.pendingMealChanges.count == 2)

    let reopened = fixture.open(now: fixture.now.addingTimeInterval(3 * 86_400))
    await fixture.health.setWriteAccess([.calories, .alcohol])
    reopened.restoreSession()
    await reopened.syncPendingAppleHealthChanges()
    let alcohol = try #require(await fixture.health.samples.first { $0.nutrient == .alcohol })
    #expect(alcohol.mealID == meal.id)
    #expect(alcohol.amount == 1.5)
    #expect(alcohol.mealTime == boundary)
    #expect(try await reopened.backfillAppleHealth(timeZone: .gmt) == 0)

    try reopened.deleteLoggedMeal(meal.id)
    await reopened.syncPendingAppleHealthChanges()
    #expect(await fixture.health.samples.isEmpty)
}

@MainActor @Test func backfillPreservesHealthDeletionsAndAlcoholReturnsAfterABiteLensCorrection() async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    let draft = try fixture.draft(in: workflow, items: [
        MealItem(name: "Drink", nutrients: NutrientAmounts(caloriesKcal: 160, alcoholGrams: 21)),
    ])
    let meal = try workflow.confirmMeal(draft.id)
    await workflow.setAppleHealthSyncEnabled(true)
    #expect(try await workflow.backfillAppleHealth(timeZone: .current) == 1)
    await workflow.syncPendingAppleHealthChanges()
    #expect(await fixture.health.samples.count == 2)
    #expect(await fixture.health.removeEntryInHealth(mealID: meal.id, nutrient: .calories))

    var item = try #require(meal.record.items.first)
    item.setNutrientAmount(0, for: .alcohol)
    try workflow.updateLoggedMeal(meal.id, mealTime: meal.record.mealTime, notes: "", items: [item])
    await workflow.syncPendingAppleHealthChanges()
    #expect(await fixture.health.samples.isEmpty)

    item.setNutrientAmount(7, for: .alcohol)
    try workflow.updateLoggedMeal(meal.id, mealTime: meal.record.mealTime, notes: "", items: [item])
    #expect(try await workflow.backfillAppleHealth(timeZone: .current) == 1)
    await workflow.syncPendingAppleHealthChanges()
    #expect(await fixture.health.samples.map(\.nutrient) == [.alcohol])
    #expect(await fixture.health.samples.map(\.amount) == [0.5])
}

@MainActor @Test func backfillRequestsAlcoholWriteAccessForExistingAppleHealthOptIn() async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    await workflow.setAppleHealthSyncEnabled(true)

    let records = fixture.directory.appendingPathComponent("drafts.json")
    var legacy = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: records)) as? [String: Any])
    legacy.removeValue(forKey: "appleHealthAuthorizationIncludesAlcohol")
    try JSONSerialization.data(withJSONObject: legacy).write(to: records)
    try await fixture.health.requestAuthorization(for: AppleHealthSample.supportedNutrients.subtracting([.alcohol]))

    let reopened = fixture.open()
    reopened.restoreSession()
    await reopened.syncPendingAppleHealthChanges()
    #expect(reopened.appleHealthSyncStatus.hasPendingWork)
    #expect(await !fixture.health.requestedNutrients.contains(.alcohol))
    await fixture.health.setAuthorizationRequestAvailable(false)
    _ = try await reopened.backfillAppleHealth(timeZone: .current)
    #expect(reopened.appleHealthSyncStatus.hasFailedWork)

    await fixture.health.setAuthorizationRequestAvailable(true)
    _ = try await reopened.backfillAppleHealth(timeZone: .current)
    #expect(await fixture.health.requestedNutrients.contains(.alcohol))
    #expect(!reopened.appleHealthSyncStatus.hasPendingWork)
    let updated = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: records)) as? [String: Any])
    #expect(updated["appleHealthAuthorizationRequest"] as? String == "completed")
    #expect(updated["appleHealthAuthorizationIncludesAlcohol"] as? Bool == true)
}
