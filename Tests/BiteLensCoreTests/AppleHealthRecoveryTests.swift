import BiteLensCore
import Testing

@MainActor @Test(arguments: [true, false])
func interruptedOptInCanRequestAuthorizationAgain(healthWasAvailable: Bool) async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    await fixture.health.setAvailable(healthWasAvailable)
    await fixture.health.setAuthorizationRequestAvailable(!healthWasAvailable)
    let workflow = fixture.open()
    workflow.restoreSession()
    await workflow.setAppleHealthSyncEnabled(true)
    #expect(workflow.appleHealthSyncEnabled)
    #expect(workflow.appleHealthSyncStatus.hasPendingWork)
    #expect(workflow.appleHealthSyncStatus.hasFailedWork == healthWasAvailable)

    let draft = try fixture.draft(in: workflow)
    let meal = try workflow.confirmMeal(draft.id)
    await workflow.syncPendingAppleHealthChanges()
    #expect(workflow.loggedMeals == [meal])
    #expect(await fixture.health.samples.isEmpty)

    if healthWasAvailable {
        await fixture.health.setAuthorizationRequestAvailable(true)
        await workflow.retryAppleHealthSync()
        #expect(!workflow.appleHealthSyncStatus.hasPendingWork)
    } else {
        await fixture.health.setAvailable(true)
        let reopened = fixture.open()
        reopened.restoreSession()
        await reopened.syncPendingAppleHealthChanges()
        #expect(!reopened.appleHealthSyncStatus.hasPendingWork)
    }
    #expect(await fixture.health.samples.map(\.mealID) == [meal.id])
}

@MainActor @Test func denyingAllPermissionsCompletesTheAuthorizationRequest() async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    await fixture.health.setWriteAccess([])
    let workflow = fixture.open()
    workflow.restoreSession()
    await workflow.setAppleHealthSyncEnabled(true)
    #expect(workflow.appleHealthSyncStatus.writeAccess == .available([]))
    #expect(!workflow.appleHealthSyncStatus.hasPendingWork)

    await fixture.health.setAuthorizationRequestAvailable(false)
    let reopened = fixture.open()
    reopened.restoreSession()
    await reopened.retryAppleHealthSync()
    #expect(!reopened.appleHealthSyncStatus.hasPendingWork)
    #expect(!reopened.appleHealthSyncStatus.hasFailedWork)
}

@MainActor @Test func pausingAnUnfinishedOptInDefersTheRequestUntilResuming() async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    await fixture.health.setAvailable(false)
    let workflow = fixture.open()
    workflow.restoreSession()
    await workflow.setAppleHealthSyncEnabled(true)
    await workflow.setAppleHealthSyncEnabled(false)

    await fixture.health.setAvailable(true)
    let reopened = fixture.open()
    reopened.restoreSession()
    await reopened.retryAppleHealthSync()
    #expect(reopened.appleHealthSyncStatus.writeAccess == .available([]))
    #expect(!reopened.appleHealthSyncStatus.hasPendingWork)

    await reopened.setAppleHealthSyncEnabled(true)
    #expect(reopened.appleHealthSyncStatus.writeAccess == .available(AppleHealthSample.supportedNutrients))
}

@MainActor @Test func returningFromHealthWithChangedPermissionsCatchesUpAuthorizedNutrients() async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    await fixture.health.setWriteAccess([.calories])
    let workflow = fixture.open()
    workflow.restoreSession()
    await workflow.setAppleHealthSyncEnabled(true)
    let draft = try fixture.draft(in: workflow, items: [
        MealItem(name: "Tea", nutrients: NutrientAmounts(caloriesKcal: 5, caffeineMilligrams: 40)),
    ])
    let meal = try workflow.confirmMeal(draft.id)
    await workflow.syncPendingAppleHealthChanges()
    #expect(workflow.appleHealthSyncStatus.writeAccess == .available([.calories]))
    #expect(workflow.appleHealthSyncStatus.hasPendingWork)
    #expect(await fixture.health.samples.map(\.nutrient) == [.calories])

    await fixture.health.setWriteAccess([.caffeine])
    let reopened = fixture.open()
    reopened.restoreSession()
    await reopened.syncPendingAppleHealthChanges()
    #expect(reopened.appleHealthSyncStatus.writeAccess == .available([.caffeine]))
    #expect(!reopened.appleHealthSyncStatus.hasPendingWork)

    try reopened.updateLoggedMeal(meal.id, mealTime: meal.record.mealTime, notes: "", items: [
        MealItem(name: "Tea", nutrients: NutrientAmounts(caloriesKcal: 10, caffeineMilligrams: 50)),
    ])
    await reopened.syncPendingAppleHealthChanges()
    #expect(reopened.appleHealthSyncStatus.hasPendingWork)
    #expect(await fixture.health.samples.first { $0.nutrient == .caffeine }?.amount == 50)
    #expect(await fixture.health.samples.first { $0.nutrient == .calories }?.amount == 5)

    await fixture.health.setWriteAccess([.calories, .caffeine])
    reopened.resumeLocalWork()
    await reopened.syncPendingAppleHealthChanges()
    #expect(reopened.appleHealthSyncStatus.writeAccess == .available([.calories, .caffeine]))
    #expect(!reopened.appleHealthSyncStatus.hasPendingWork)
    #expect(await fixture.health.samples.first { $0.nutrient == .calories }?.amount == 10)
    #expect(await fixture.health.samples.count == 2)
}

@MainActor @Test func settingsReportsAFailureAcrossRestartAndRetryLeavesOneEntry() async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    let workflow = fixture.open()
    workflow.restoreSession()
    await workflow.setAppleHealthSyncEnabled(true)

    await fixture.health.loseNextSaveResponse()
    let draft = try fixture.draft(in: workflow)
    let meal = try workflow.confirmMeal(draft.id)
    await workflow.syncPendingAppleHealthChanges()
    #expect(workflow.appleHealthSyncStatus.hasPendingWork)
    #expect(workflow.appleHealthSyncStatus.hasFailedWork)
    #expect(await fixture.health.samples.map(\.mealID) == [meal.id])

    await fixture.health.setAvailable(false)
    let reopened = fixture.open()
    reopened.restoreSession()
    await reopened.syncPendingAppleHealthChanges()
    #expect(reopened.appleHealthSyncStatus.writeAccess == .unavailable)
    #expect(reopened.appleHealthSyncStatus.hasFailedWork)

    await fixture.health.setAvailable(true)
    await reopened.retryAppleHealthSync()
    #expect(!reopened.appleHealthSyncStatus.hasPendingWork)
    #expect(!reopened.appleHealthSyncStatus.hasFailedWork)
    #expect(await fixture.health.samples.map(\.mealID) == [meal.id])
}

@MainActor @Test func resumingAppliesPausedChangesAndKeepsAHealthRemovalAbsent() async throws {
    let fixture = try AppleHealthFixture()
    defer { fixture.remove() }
    await fixture.health.setWriteAccess([.calories, .protein, .sodium])
    let workflow = fixture.open()
    workflow.restoreSession()
    let beforeOptIn = try fixture.draft(in: workflow)
    try workflow.confirmMeal(beforeOptIn.id)
    await workflow.setAppleHealthSyncEnabled(true)
    let editedDraft = try fixture.draft(in: workflow, items: [
        MealItem(name: "Soup", nutrients: NutrientAmounts(caloriesKcal: 150, proteinGrams: 8)),
    ])
    let edited = try workflow.confirmMeal(editedDraft.id)
    let deletedDraft = try fixture.draft(in: workflow, items: [
        MealItem(name: "Crackers", nutrients: NutrientAmounts(sodiumMilligrams: 50)),
    ])
    let deleted = try workflow.confirmMeal(deletedDraft.id)
    await workflow.syncPendingAppleHealthChanges()

    await workflow.setAppleHealthSyncEnabled(false)
    await fixture.health.removeEntryInHealth(mealID: edited.id, nutrient: .calories)
    try workflow.updateLoggedMeal(edited.id, mealTime: edited.record.mealTime, notes: "", items: [
        MealItem(name: "Soup", nutrients: NutrientAmounts(caloriesKcal: 200, proteinGrams: 12)),
    ])
    try workflow.deleteLoggedMeal(deleted.id)
    let pausedDraft = try fixture.draft(in: workflow)
    try workflow.confirmMeal(pausedDraft.id)

    await fixture.health.setWriteAccess([.calories, .protein])
    let reopened = fixture.open()
    reopened.restoreSession()
    await reopened.retryAppleHealthSync()
    #expect(!reopened.appleHealthSyncEnabled)
    #expect(reopened.appleHealthSyncStatus.writeAccess == .available([.calories, .protein]))
    #expect(reopened.appleHealthSyncStatus.hasPendingWork)
    #expect(await fixture.health.samples.first { $0.nutrient == .protein }?.amount == 8)
    #expect(await fixture.health.samples.first { $0.nutrient == .sodium }?.mealID == deleted.id)

    await reopened.setAppleHealthSyncEnabled(true)
    #expect(reopened.appleHealthSyncStatus.hasPendingWork)
    #expect(!reopened.appleHealthSyncStatus.hasFailedWork)
    #expect(await fixture.health.samples.count == 2)
    #expect(await fixture.health.samples.first { $0.nutrient == .protein }?.amount == 12)

    await fixture.health.setWriteAccess([.calories, .protein, .sodium])
    await reopened.retryAppleHealthSync()
    let samples = await fixture.health.samples
    #expect(!reopened.appleHealthSyncStatus.hasPendingWork)
    #expect(samples.map(\.mealID) == [edited.id])
    #expect(samples.map(\.nutrient) == [.protein])
}
