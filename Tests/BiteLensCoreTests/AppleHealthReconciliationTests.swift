import BiteLensCore
import Foundation
import Testing

@MainActor @Test func aHealthDeletionAfterAnUnacknowledgedFirstWriteStaysAbsent() async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    await workflow.setAppleHealthSyncEnabled(true)
    await fixture.health.loseNextSaveResponse()
    let draft = try fixture.draft(in: workflow)
    let meal = try workflow.confirmMeal(draft.id)
    await workflow.syncPendingAppleHealthChanges()
    #expect(workflow.appleHealthSyncStatus.hasFailedWork)
    #expect(await fixture.health.samples.map(\.mealID) == [meal.id])
    await fixture.health.removeEntryInHealth(mealID: meal.id, nutrient: .calories)

    let reopened = fixture.open()
    reopened.restoreSession()
    await reopened.syncPendingAppleHealthChanges()
    #expect(!reopened.appleHealthSyncStatus.hasPendingWork)
    #expect(await fixture.health.samples.isEmpty)

    let corrected = try reopened.updateLoggedMeal(meal.id, mealTime: meal.record.mealTime, notes: "", items: [
        MealItem(name: "Soup", nutrients: NutrientAmounts(caloriesKcal: 315)),
    ])
    await reopened.syncPendingAppleHealthChanges()
    #expect(reopened.loggedMeals == [corrected])
    #expect(await fixture.health.samples.isEmpty)
}

@MainActor @Test func aHealthDeletionDuringAnIncompleteEditStaysAbsentAfterCompletion() async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    await workflow.setAppleHealthSyncEnabled(true)
    let draft = try fixture.draft(in: workflow)
    let meal = try workflow.confirmMeal(draft.id)
    await workflow.syncPendingAppleHealthChanges()
    #expect(await fixture.health.samples.map(\.mealID) == [meal.id])

    await fixture.health.removeEntryBeforeNextBiteLensDeletion()
    try workflow.updateLoggedMeal(meal.id, mealTime: meal.record.mealTime, notes: "", items: [MealItem(name: "Soup")])
    await workflow.syncPendingAppleHealthChanges()
    #expect(await fixture.health.samples.isEmpty)

    let reopened = fixture.open()
    reopened.restoreSession()
    let corrected = try reopened.updateLoggedMeal(meal.id, mealTime: meal.record.mealTime, notes: "", items: [
        MealItem(name: "Soup", nutrients: NutrientAmounts(caloriesKcal: 315)),
    ])
    await reopened.syncPendingAppleHealthChanges()
    #expect(reopened.loggedMeals == [corrected])
    #expect(await fixture.health.samples.isEmpty)
}

@MainActor @Test func retryingANewerWriteIgnoresTheEarlierIntentionalRemoval() async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    await workflow.setAppleHealthSyncEnabled(true)
    let draft = try fixture.draft(in: workflow)
    let meal = try workflow.confirmMeal(draft.id)
    await workflow.syncPendingAppleHealthChanges()
    #expect(await fixture.health.samples.map(\.revision) == [1])

    try workflow.updateLoggedMeal(meal.id, mealTime: meal.record.mealTime, notes: "", items: [MealItem(name: "Soup")])
    await workflow.syncPendingAppleHealthChanges()
    #expect(await fixture.health.samples.isEmpty)

    await fixture.health.failNextSaveBeforeWriting()
    try workflow.updateLoggedMeal(meal.id, mealTime: meal.record.mealTime, notes: "", items: [
        MealItem(name: "Soup", nutrients: NutrientAmounts(caloriesKcal: 315)),
    ])
    await workflow.syncPendingAppleHealthChanges()
    #expect(workflow.appleHealthSyncStatus.hasFailedWork)
    #expect(await fixture.health.samples.isEmpty)

    let reopened = fixture.open()
    reopened.restoreSession()
    await reopened.syncPendingAppleHealthChanges()
    #expect(await fixture.health.samples.map(\.revision) == [3])
    #expect(await fixture.health.samples.map(\.amount) == [315])
}

@MainActor @Test func correctingCaloriesAndMealTimeReplacesTheHealthEntry() async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    await workflow.setAppleHealthSyncEnabled(true)
    let draft = try fixture.draft(in: workflow)
    let meal = try workflow.confirmMeal(draft.id)
    await workflow.syncPendingAppleHealthChanges()

    let correctedTime = MealTime(instant: fixture.now.addingTimeInterval(-3_600), timeZone: .gmt)
    try workflow.updateLoggedMeal(meal.id, mealTime: correctedTime, notes: "", items: [
        MealItem(name: "Soup", nutrients: NutrientAmounts(caloriesKcal: 310)),
    ])
    _ = try #require(await fixture.health.waitForFirstSample(revision: 2))
    await workflow.syncPendingAppleHealthChanges()

    let entries = await fixture.health.samples
    #expect(entries.count == 1)
    let entry = try #require(entries.first)
    #expect(entry.amount == 310)
    #expect(entry.mealTime == correctedTime.instant)
    #expect(entry.revision == 2)
}

@MainActor @Test func aTotalMadeIncompleteDisappearsAndCanReturnWhenComplete() async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    await workflow.setAppleHealthSyncEnabled(true)
    let draft = try fixture.draft(in: workflow)
    let meal = try workflow.confirmMeal(draft.id)
    await workflow.syncPendingAppleHealthChanges()

    try workflow.updateLoggedMeal(meal.id, mealTime: meal.record.mealTime, notes: "", items: [
        MealItem(name: "Soup", nutrients: NutrientAmounts(caloriesKcal: 225)),
        MealItem(name: "Bread"),
    ])
    await workflow.syncPendingAppleHealthChanges()
    #expect(await fixture.health.samples.isEmpty)

    try workflow.updateLoggedMeal(meal.id, mealTime: meal.record.mealTime, notes: "", items: [
        MealItem(name: "Soup", nutrients: NutrientAmounts(caloriesKcal: 225)),
        MealItem(name: "Bread", nutrients: NutrientAmounts(caloriesKcal: 75)),
    ])
    await workflow.syncPendingAppleHealthChanges()
    let entries = await fixture.health.samples
    #expect(entries.map(\.amount) == [300])
    #expect(entries.map(\.revision) == [3])
}

@MainActor @Test func anEntryRemovedInHealthStaysAbsentAfterBiteLensCorrections() async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    await workflow.setAppleHealthSyncEnabled(true)
    let draft = try fixture.draft(in: workflow)
    let meal = try workflow.confirmMeal(draft.id)
    await workflow.syncPendingAppleHealthChanges()

    await fixture.health.removeEntryInHealth(mealID: meal.id, nutrient: .calories)
    await workflow.syncPendingAppleHealthChanges()
    #expect(await fixture.health.samples.isEmpty)

    let corrected = try workflow.updateLoggedMeal(meal.id, mealTime: meal.record.mealTime, notes: "", items: [
        MealItem(name: "Soup", nutrients: NutrientAmounts(caloriesKcal: 305)),
    ])
    await workflow.syncPendingAppleHealthChanges()
    #expect(workflow.loggedMeals == [corrected])
    #expect(await fixture.health.samples.isEmpty)

    let reopened = fixture.open()
    reopened.restoreSession()
    try reopened.updateLoggedMeal(meal.id, mealTime: meal.record.mealTime, notes: "", items: [
        MealItem(name: "Soup", nutrients: NutrientAmounts(caloriesKcal: 310)),
    ])
    await reopened.syncPendingAppleHealthChanges()
    #expect(await fixture.health.samples.isEmpty)
}

@MainActor @Test(arguments: [false, true])
func deletingAMealRemovesItsHealthEntryButPreservesOtherSources(whilePaused: Bool) async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    await workflow.setAppleHealthSyncEnabled(true)
    let draft = try fixture.draft(in: workflow)
    let meal = try workflow.confirmMeal(draft.id)
    await workflow.syncPendingAppleHealthChanges()
    let entry = try #require(await fixture.health.samples.first)
    await fixture.health.addEntryFromAnotherSource(entry)

    if whilePaused { await workflow.setAppleHealthSyncEnabled(false) }
    try workflow.deleteLoggedMeal(meal.id)
    #expect(workflow.loggedMeals.isEmpty)
    await workflow.syncPendingAppleHealthChanges()

    let reopened = fixture.open()
    reopened.restoreSession()
    if whilePaused {
        #expect(await fixture.health.entriesFromAllSources == [entry, entry])
        await reopened.setAppleHealthSyncEnabled(true)
    }
    await reopened.syncPendingAppleHealthChanges()
    #expect(reopened.loggedMeals.isEmpty)
    #expect(await fixture.health.samples.isEmpty)
    #expect(await fixture.health.entriesFromAllSources == [entry])
}

@MainActor @Test func deletingDuringAnUnacknowledgedWriteClearsTheHealthEntry() async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    await workflow.setAppleHealthSyncEnabled(true)
    await fixture.health.holdAndLoseNextSaveResponse()
    let draft = try fixture.draft(in: workflow)
    let meal = try workflow.confirmMeal(draft.id)
    _ = try #require(await fixture.health.waitForFirstSample())
    let correction = [MealItem(name: "Soup", nutrients: NutrientAmounts(caloriesKcal: 315))]
    try workflow.updateLoggedMeal(meal.id, mealTime: meal.record.mealTime, notes: "", items: correction)
    try workflow.deleteLoggedMeal(meal.id)
    #expect(workflow.loggedMeals.isEmpty)
    await fixture.health.releaseSaveResponse()
    await workflow.syncPendingAppleHealthChanges()

    let reopened = fixture.open()
    reopened.restoreSession()
    await reopened.syncPendingAppleHealthChanges()
    #expect(reopened.loggedMeals.isEmpty)
    #expect(await fixture.health.samples.isEmpty)
}

@MainActor @Test func aFailedLookupDefersCorrectionUntilRelaunch() async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    await workflow.setAppleHealthSyncEnabled(true)
    let draft = try fixture.draft(in: workflow)
    let meal = try workflow.confirmMeal(draft.id)
    await workflow.syncPendingAppleHealthChanges()
    let originalEntries = await fixture.health.samples

    await fixture.health.setLookupAvailable(false)
    let corrected = try workflow.updateLoggedMeal(meal.id, mealTime: meal.record.mealTime, notes: "", items: [
        MealItem(name: "Soup", nutrients: NutrientAmounts(caloriesKcal: 330)),
    ])
    await workflow.syncPendingAppleHealthChanges()
    #expect(workflow.loggedMeals == [corrected])
    #expect(await fixture.health.samples == originalEntries)

    await fixture.health.setLookupAvailable(true)
    let reopened = fixture.open()
    reopened.restoreSession()
    await reopened.syncPendingAppleHealthChanges()
    #expect(await fixture.health.samples.map(\.amount) == [330])
}

@MainActor @Test func aTotalCanReturnAfterBiteLensLosesTheRemovalResponse() async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    await workflow.setAppleHealthSyncEnabled(true)
    let draft = try fixture.draft(in: workflow)
    let meal = try workflow.confirmMeal(draft.id)
    await workflow.syncPendingAppleHealthChanges()

    await fixture.health.loseNextRemovalResponse()
    try workflow.updateLoggedMeal(meal.id, mealTime: meal.record.mealTime, notes: "", items: [MealItem(name: "Soup")])
    await workflow.syncPendingAppleHealthChanges()
    #expect(await fixture.health.samples.isEmpty)

    let reopened = fixture.open()
    reopened.restoreSession()
    try reopened.updateLoggedMeal(meal.id, mealTime: meal.record.mealTime, notes: "", items: [
        MealItem(name: "Soup", nutrients: NutrientAmounts(caloriesKcal: 290)),
    ])
    await reopened.syncPendingAppleHealthChanges()
    #expect(await fixture.health.samples.map(\.amount) == [290])
}

@MainActor @Test func deletingBeforeTheFirstWritePreventsHealthExportOnRelaunch() async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    await workflow.setAppleHealthSyncEnabled(true)
    await fixture.health.setAvailable(false)
    let draft = try fixture.draft(in: workflow)
    let meal = try workflow.confirmMeal(draft.id)
    try workflow.deleteLoggedMeal(meal.id)
    await workflow.syncPendingAppleHealthChanges()

    await fixture.health.setAvailable(true)
    let reopened = fixture.open()
    reopened.restoreSession()
    await reopened.syncPendingAppleHealthChanges()
    #expect(reopened.loggedMeals.isEmpty)
    #expect(await fixture.health.samples.isEmpty)
    #expect(await fixture.health.saveAttempts.isEmpty)
}
