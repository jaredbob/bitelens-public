import Foundation
import Testing
import BiteLensCore

private let ownerID = UUID(uuidString: "a1000000-0000-4000-8000-000000000001")!
private let instant = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor @Test func approvedOwnerCanSignIn() async throws {
    let storage = try TestStorage()
    let workflow = MealWorkflow(auth: TestAuth(session: session()), sessionStore: storage,
                                preferences: storage, approvedOwnerID: ownerID, now: { instant })
    await workflow.signIn(email: "owner@example.com", password: "test-password")
    #expect(workflow.access == .owner)
}

@MainActor @Test func authenticatedUnapprovedAccountIsDenied() async throws {
    let storage = try TestStorage()
    let workflow = MealWorkflow(auth: TestAuth(session: session(userID: UUID())), sessionStore: storage,
                                preferences: storage, approvedOwnerID: ownerID, now: { instant })
    await workflow.signIn(email: "other@example.com", password: "test-password")
    #expect(workflow.access == .denied)
}

@MainActor @Test func providerChoiceIsExplicitAndSurvivesRestart() async throws {
    let storage = try TestStorage()
    let suiteName = "BiteLensTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let workflow = MealWorkflow(auth: TestAuth(session: session()), sessionStore: storage,
                                preferences: UserDefaultsProviderPreferences(defaults: defaults), approvedOwnerID: ownerID, now: { instant })
    await workflow.signIn(email: "owner@example.com", password: "test-password")
    #expect(workflow.selectedProvider == nil)
    workflow.selectProvider(.grok)
    let reopened = MealWorkflow(auth: TestAuth(session: session()), sessionStore: try TestStorage(directory: storage.directory),
                               preferences: UserDefaultsProviderPreferences(defaults: UserDefaults(suiteName: suiteName)!), approvedOwnerID: ownerID, now: { instant })
    #expect(reopened.selectedProvider == .grok)
}

@MainActor @Test func ownerSessionReopensLocallyWithoutNetworkEvenAfterTokenExpiry() async throws {
    let storage = try TestStorage()
    let workflow = MealWorkflow(auth: TestAuth(session: session(expiresAt: instant.addingTimeInterval(-1))),
                                sessionStore: storage, preferences: storage, approvedOwnerID: ownerID, now: { instant })
    await workflow.signIn(email: "owner@example.com", password: "test-password")
    workflow.selectProvider(.openAI)
    let reopened = MealWorkflow(auth: OfflineAuth(), sessionStore: try TestStorage(directory: storage.directory),
                               preferences: try TestStorage(directory: storage.directory), approvedOwnerID: ownerID, now: { instant })
    reopened.restoreSession()
    #expect(reopened.access == .owner)
    #expect(reopened.selectedProvider == .openAI)
}

@MainActor @Test func failedSignInCanBeRetriedWithoutRestart() async throws {
    let storage = try TestStorage()
    let auth = RetryAuth()
    let workflow = MealWorkflow(auth: auth, sessionStore: storage, preferences: storage,
                                approvedOwnerID: ownerID, now: { instant })
    await workflow.signIn(email: "owner@example.com", password: "wrong")
    #expect(workflow.access == .signedOut)
    #expect(workflow.issue == .invalidCredentials)
    await workflow.signIn(email: "owner@example.com", password: "correct")
    #expect(workflow.access == .owner)
    #expect(workflow.issue == nil)
}

@MainActor @Test func expiredSessionRefreshesAndNewCredentialsSurviveRestart() async throws {
    let storage = try TestStorage()
    let workflow = MealWorkflow(auth: RefreshAuth(), sessionStore: storage, preferences: storage,
                                approvedOwnerID: ownerID, now: { instant })
    await workflow.signIn(email: "owner@example.com", password: "correct")
    #expect(try await workflow.accessToken() == "renewed-access")
    let reopened = MealWorkflow(auth: OfflineAuth(), sessionStore: try TestStorage(directory: storage.directory),
                               preferences: storage, approvedOwnerID: ownerID, now: { instant })
    reopened.restoreSession()
    #expect(try await reopened.accessToken() == "renewed-access")
}

@MainActor @Test func revokedCloudSessionRequestsReauthenticationAndRetainsLocalAccess() async throws {
    let storage = try TestStorage()
    let workflow = MealWorkflow(auth: RevokedAuth(), sessionStore: storage, preferences: storage,
                                approvedOwnerID: ownerID, now: { instant })
    await workflow.signIn(email: "owner@example.com", password: "correct")
    workflow.selectProvider(.grok)
    await #expect(throws: WorkflowIssue.signInRequired) { try await workflow.accessToken() }
    #expect(workflow.cloudStatus == .reauthenticationRequired)
    #expect(workflow.access == .owner)
    #expect(workflow.selectedProvider == .grok)
}

@MainActor @Test func localSignOutRemovesSavedIdentityEvenWithoutNetworkAndKeepsPreference() async throws {
    let storage = try TestStorage()
    let workflow = MealWorkflow(auth: TestAuth(session: session()), sessionStore: storage, preferences: storage,
                                approvedOwnerID: ownerID, now: { instant })
    await workflow.signIn(email: "owner@example.com", password: "correct")
    workflow.selectProvider(.grok)
    let reopened = MealWorkflow(auth: OfflineAuth(), sessionStore: storage, preferences: storage,
                               approvedOwnerID: ownerID, now: { instant })
    reopened.restoreSession()
    await reopened.signOut()
    let signedOut = MealWorkflow(auth: OfflineAuth(), sessionStore: storage, preferences: storage,
                                approvedOwnerID: ownerID, now: { instant })
    signedOut.restoreSession()
    #expect(signedOut.access == .signedOut)
    #expect(signedOut.selectedProvider == .grok)
    await #expect(throws: WorkflowIssue.signInRequired) { try await signedOut.accessToken() }
}

private struct RevokedAuth: AuthenticationClient {
    func signIn(email: String, password: String) async throws -> AuthSession { session(expiresAt: instant.addingTimeInterval(-1)) }
    func refresh(refreshToken: String) async throws -> AuthSession { throw AuthenticationFailure.sessionExpired }
    func signOut(accessToken: String) async throws {}
}

private struct RefreshAuth: AuthenticationClient {
    func signIn(email: String, password: String) async throws -> AuthSession { session(expiresAt: instant.addingTimeInterval(-1)) }
    func refresh(refreshToken: String) async throws -> AuthSession {
        AuthSession(userID: ownerID, accessToken: "renewed-access", refreshToken: "renewed-refresh", expiresAt: instant.addingTimeInterval(3600))
    }
    func signOut(accessToken: String) async throws {}
}

private struct RetryAuth: AuthenticationClient {
    func signIn(email: String, password: String) async throws -> AuthSession {
        guard password == "correct" else { throw AuthenticationFailure.invalidCredentials }
        return session()
    }
    func refresh(refreshToken: String) async throws -> AuthSession { session() }
    func signOut(accessToken: String) async throws {}
}

private struct OfflineAuth: AuthenticationClient {
    func signIn(email: String, password: String) async throws -> AuthSession { throw URLError(.notConnectedToInternet) }
    func refresh(refreshToken: String) async throws -> AuthSession { throw URLError(.notConnectedToInternet) }
    func signOut(accessToken: String) async throws { throw URLError(.notConnectedToInternet) }
}

private func session(userID: UUID = ownerID, expiresAt: Date = instant.addingTimeInterval(3600)) -> AuthSession {
    AuthSession(userID: userID, accessToken: "test-access", refreshToken: "test-refresh", expiresAt: expiresAt)
}

private struct TestAuth: AuthenticationClient {
    let session: AuthSession
    func signIn(email: String, password: String) async throws -> AuthSession { session }
    func refresh(refreshToken: String) async throws -> AuthSession { session }
    func signOut(accessToken: String) async throws {}
}

private final class TestStorage: SessionStore, ProviderPreferences, @unchecked Sendable {
    let directory: URL
    var sessionURL: URL { directory.appendingPathComponent("session.json") }
    var providerURL: URL { directory.appendingPathComponent("provider.txt") }
    init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }
    func load() throws -> AuthSession? {
        guard FileManager.default.fileExists(atPath: sessionURL.path) else { return nil }
        return try JSONDecoder().decode(AuthSession.self, from: Data(contentsOf: sessionURL))
    }
    func save(_ session: AuthSession) throws { try JSONEncoder().encode(session).write(to: sessionURL, options: .atomic) }
    func clear() throws {
        if FileManager.default.fileExists(atPath: sessionURL.path) { try FileManager.default.removeItem(at: sessionURL) }
    }
    func loadProvider() -> AIProvider? {
        guard let raw = try? String(contentsOf: providerURL, encoding: .utf8) else { return nil }
        return AIProvider(rawValue: raw)
    }
    func saveProvider(_ provider: AIProvider) { try! provider.rawValue.write(to: providerURL, atomically: true, encoding: .utf8) }
}

@MainActor @Test func passwordGrantRefreshAndLocalLogoutUseExistingSupabaseAuthContract() async throws {
    let config = try SupabaseConfiguration(url: URL(string: "https://auth.test.invalid")!, publishableKey: "sb_publishable_test")
    let network = URLSessionConfiguration.ephemeral
    network.protocolClasses = [SupabaseFixtureProtocol.self]
    let auth = SupabaseAuthenticationClient(configuration: config, session: URLSession(configuration: network), now: { instant })
    let storage = try TestStorage()
    let workflow = MealWorkflow(auth: auth, sessionStore: storage, preferences: storage, approvedOwnerID: ownerID, now: { instant })
    await workflow.signIn(email: "owner@example.com", password: "correct")
    #expect(workflow.access == .owner)
    #expect(try await workflow.accessToken() == "fixture-renewed")
    await workflow.signOut()
    #expect(workflow.access == .signedOut)
}

/// A deterministic Auth HTTP boundary, never a live project or a real password.
private final class SupabaseFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "auth.test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        let grant = query?.first(where: { $0.name == "grant_type" })?.value
        let body: [String: String]
        if let bytes = request.httpBody {
            body = (try? JSONDecoder().decode([String: String].self, from: bytes)) ?? [:]
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(buffer, count: count)
            }
            body = (try? JSONDecoder().decode([String: String].self, from: bytes)) ?? [:]
        } else { body = [:] }
        var status = 400
        var response = "{}"
        if request.httpMethod == "POST", request.value(forHTTPHeaderField: "apikey") == "sb_publishable_test" {
            if request.url!.path == "/auth/v1/token", grant == "password", body["email"] == "owner@example.com", body["password"] == "correct" {
                status = 200
                response = "{\"access_token\":\"fixture-access\",\"refresh_token\":\"fixture-refresh\",\"expires_in\":0,\"user\":{\"id\":\"a1000000-0000-4000-8000-000000000001\"}}"
            } else if request.url!.path == "/auth/v1/token", grant == "refresh_token", body["refresh_token"] == "fixture-refresh" {
                status = 200
                response = "{\"access_token\":\"fixture-renewed\",\"refresh_token\":\"fixture-refresh-2\",\"expires_in\":3600,\"user\":{\"id\":\"a1000000-0000-4000-8000-000000000001\"}}"
            } else if request.url!.path == "/rest/v1/rpc/bitelens_is_approved",
                      request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access" {
                status = 200
                response = "true"
            } else if request.url!.path == "/auth/v1/logout", query?.first(where: { $0.name == "scope" })?.value == "local", request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-renewed" {
                status = 204
            }
        }
        let result = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: result, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor @Test func signOutWinsOverPendingSignIn() async throws {
    let storage = try TestStorage()
    let auth = SuspendedAuth()
    let workflow = MealWorkflow(auth: auth, sessionStore: storage, preferences: storage, approvedOwnerID: ownerID, now: { instant })
    let pending = Task { await workflow.signIn(email: "owner@example.com", password: "correct") }
    await auth.waitUntilSuspended()
    await workflow.signOut()
    await auth.complete()
    await pending.value
    #expect(workflow.access == .signedOut)
    let reopened = MealWorkflow(auth: OfflineAuth(), sessionStore: storage, preferences: storage, approvedOwnerID: ownerID)
    reopened.restoreSession()
    #expect(reopened.access == .signedOut)
}

/// Models a pending external Auth response with no scheduler delays or sleeps.
private actor SuspendedAuth: AuthenticationClient {
    var completion: CheckedContinuation<AuthSession, Never>?
    var started: CheckedContinuation<Void, Never>?
    var hasStarted = false
    func signIn(email: String, password: String) async throws -> AuthSession {
        await withCheckedContinuation { continuation in
            completion = continuation
            hasStarted = true
            started?.resume()
            started = nil
        }
    }
    func refresh(refreshToken: String) async throws -> AuthSession {
        guard completion == nil else { throw AuthenticationFailure.sessionExpired }
        return try await signIn(email: "", password: "")
    }
    func signOut(accessToken: String) async throws {}
    func waitUntilSuspended() async {
        if hasStarted { return }
        await withCheckedContinuation { started = $0 }
    }
    func complete() {
        completion?.resume(returning: session())
        completion = nil
    }
}

@MainActor @Test func signOutWinsOverPendingTokenRefresh() async throws {
    let storage = try TestStorage()
    let initial = MealWorkflow(auth: RefreshAuth(), sessionStore: storage, preferences: storage, approvedOwnerID: ownerID, now: { instant })
    await initial.signIn(email: "owner@example.com", password: "correct")
    let auth = SuspendedAuth()
    let workflow = MealWorkflow(auth: auth, sessionStore: storage, preferences: storage, approvedOwnerID: ownerID, now: { instant })
    workflow.restoreSession()
    let pending = Task { try? await workflow.accessToken() }
    await auth.waitUntilSuspended()
    await workflow.signOut()
    await auth.complete()
    #expect(await pending.value == nil)
    #expect(workflow.access == .signedOut)
    let reopened = MealWorkflow(auth: OfflineAuth(), sessionStore: storage, preferences: storage, approvedOwnerID: ownerID)
    reopened.restoreSession()
    #expect(reopened.access == .signedOut)
}

@MainActor @Test func concurrentCloudRequestsShareRefreshWithoutLosingSession() async throws {
    let storage = try TestStorage()
    let initial = MealWorkflow(auth: RefreshAuth(), sessionStore: storage, preferences: storage, approvedOwnerID: ownerID, now: { instant })
    await initial.signIn(email: "owner@example.com", password: "correct")
    let auth = SuspendedAuth()
    let workflow = MealWorkflow(auth: auth, sessionStore: storage, preferences: storage, approvedOwnerID: ownerID, now: { instant })
    workflow.restoreSession()
    let first = Task { try await workflow.accessToken() }
    await auth.waitUntilSuspended()
    let second = Task { try await workflow.accessToken() }
    await Task.yield()
    await auth.complete()
    #expect(try await first.value == "test-access")
    #expect(try await second.value == "test-access")
    #expect(workflow.cloudStatus == .ready)
}

@MainActor @Test func unapprovedSignInDeniesPriorOwnerEvenWhenSecureDeletionFails() async throws {
    let storage = try TestStorage()
    let workflow = MealWorkflow(auth: AccountAuth(), sessionStore: FailingDeletionStore(storage: storage),
                                preferences: storage, approvedOwnerID: ownerID, now: { instant })
    await workflow.signIn(email: "owner@example.com", password: "correct")
    #expect(workflow.access == .owner)
    await workflow.signIn(email: "unapproved@example.com", password: "correct")
    #expect(workflow.access == .denied)
    await #expect(throws: WorkflowIssue.signInRequired) { try await workflow.accessToken() }
}

private struct AccountAuth: AuthenticationClient {
    func signIn(email: String, password: String) async throws -> AuthSession {
        session(userID: email == "owner@example.com" ? ownerID : UUID())
    }
    func refresh(refreshToken: String) async throws -> AuthSession { session() }
    func signOut(accessToken: String) async throws {}
}

private struct FailingDeletionStore: SessionStore {
    let storage: TestStorage
    func load() throws -> AuthSession? { try storage.load() }
    func save(_ session: AuthSession) throws { try storage.save(session) }
    func clear() throws { throw SecureStorageFailure.unavailable }
}

@MainActor @Test func betaRequiresLiveApprovalAndReopensTheSameRecordOffline() async throws {
    let storage = try TestStorage()
    let secondID = UUID()
    let accounts = BetaAccountFixtures(first: ownerID, second: secondID)
    let defaultsName = "BiteLensBetaTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    var publishedAccount: UUID?
    func makeWorkflow() -> MealWorkflow {
        MealWorkflow(auth: accounts, sessionStore: storage,
                     betaApproval: accounts, accountDirectory: storage.directory.appendingPathComponent("accounts"),
                     accountPreferences: { UserDefaultsProviderPreferences(defaults: defaults, accountID: $0) },
                     activeAccountChanged: { publishedAccount = $0 }, now: { instant })
    }

    let workflow = makeWorkflow()
    await workflow.signIn(email: "first@example.com", password: "correct")
    #expect(workflow.activeAccountID == ownerID)
    #expect(publishedAccount == ownerID)
    workflow.selectProvider(.grok)
    let draft = try workflow.startManualDraft()
    try workflow.updateDraftNotes(draft.id, notes: "First account's draft")
    let image = Data("first-account-image".utf8)
    let imageDraft = try workflow.captureMeal(photoData: image)
    let meal = try workflow.startManualDraft()
    try workflow.updateDraftItems(meal.id, items: [
        MealItem(name: "Rice", portion: ConsumedPortion(grams: 100, servingDescription: "1 bowl"),
                 nutrients: NutrientAmounts(caloriesKcal: 130))
    ])
    try workflow.confirmMeal(meal.id)
    let urge = try workflow.logUrge(mealID: meal.id)

    await accounts.setApproved(false, for: ownerID)
    await accounts.setOnline(false)
    let reopened = makeWorkflow()
    reopened.restoreSession()
    #expect(reopened.activeAccountID == ownerID)
    #expect(reopened.selectedProvider == .grok)
    #expect(reopened.drafts.contains { $0.notes == "First account's draft" })
    #expect(try reopened.photoData(for: imageDraft.id) == image)
    #expect(reopened.loggedMeals.map(\.id) == [meal.id])
    #expect(reopened.pendingMealChanges.map(\.ownerID) == [ownerID])
    #expect(reopened.pendingObservationChanges.map(\.id) == [urge.id])
    let offlineDraft = try reopened.startManualDraft()
    await reopened.signOut()
    #expect(publishedAccount == nil)
    #expect(reopened.activeAccountID == nil)
    #expect(reopened.drafts.isEmpty)
    #expect(reopened.pendingMealChanges.isEmpty)
    #expect(reopened.pendingObservationChanges.isEmpty)

    await accounts.setOnline(true)
    await reopened.signIn(email: "first@example.com", password: "correct")
    #expect(reopened.issue == .accessDenied)
    #expect(reopened.activeAccountID == nil)
    await reopened.signIn(email: "second@example.com", password: "correct")
    #expect(reopened.activeAccountID == secondID)
    #expect(reopened.selectedProvider == .openAI)
    #expect(reopened.drafts.isEmpty)
    #expect(reopened.dailyHistory.isEmpty)
    #expect(throws: DraftIssue.draftNotFound) { try reopened.photoData(for: imageDraft.id) }
    #expect(reopened.pendingMealChanges.isEmpty)
    #expect(reopened.pendingObservationChanges.isEmpty)
    let secondDraft = try reopened.startManualDraft()
    await reopened.signOut()

    await accounts.setApproved(true, for: ownerID)
    await reopened.signIn(email: "first@example.com", password: "correct")
    #expect(reopened.activeAccountID == ownerID)
    #expect(reopened.selectedProvider == .grok)
    #expect(Set(reopened.drafts.map(\.id)) == [draft.id, imageDraft.id, offlineDraft.id])
    #expect(!reopened.drafts.contains { $0.id == secondDraft.id })
    #expect(reopened.pendingMealChanges.map(\.id) == [meal.id])
    #expect(reopened.pendingObservationChanges.map(\.id) == [urge.id])
}

@MainActor @Test func betaShareStaysWithTheAccountActiveBeforeTheImageFinishesLoading() async throws {
    let storage = try TestStorage()
    defer { try? FileManager.default.removeItem(at: storage.directory) }
    let accounts = BetaAccountFixtures(first: ownerID, second: UUID())
    let inbox = SharedMealImageInbox(directory: storage.directory.appendingPathComponent("Inbox"), requiresAccount: true)
    func openWorkflow() -> MealWorkflow {
        MealWorkflow(auth: accounts, sessionStore: storage,
                     betaApproval: accounts, accountDirectory: storage.directory.appendingPathComponent("Accounts"),
                     accountPreferences: { _ in storage }, now: { instant }, sharedImageInbox: inbox)
    }

    let workflow = openWorkflow()
    await workflow.signIn(email: "first@example.com", password: "correct")
    #expect(workflow.activeAccountID == ownerID)
    #expect(workflow.issue == nil)
    // The Share extension snapshots the account and time before asking its image provider for data.
    let sharedAt = instant.addingTimeInterval(-86_400)
    let share = try inbox.beginShare(at: sharedAt, timeZone: .gmt)
    await workflow.signOut()
    await workflow.signIn(email: "second@example.com", password: "correct")
    let id = try share.enqueue(fixturePhoto)

    let reopened = openWorkflow()
    reopened.restoreSession()
    #expect(reopened.drafts.isEmpty)
    #expect(reopened.sharedDraftToOpen == nil)
    #expect(throws: DraftIssue.draftNotFound) { try reopened.photoData(for: id) }
    await reopened.signOut()
    await reopened.signIn(email: "first@example.com", password: "correct")
    #expect(reopened.drafts.map(\.id) == [id])
    #expect(reopened.sharedDraftToOpen == id)
    #expect(try reopened.photoData(for: id) == fixturePhoto)
    #expect(reopened.drafts.first?.photo?.retentionStartedAt == sharedAt)
    #expect(reopened.drafts.first?.photo?.expiresAt == sharedAt.addingTimeInterval(604_800))
}

@MainActor @Test func betaShareWhileSignedOutCannotBecomeTheNextAccountsDraft() async throws {
    let storage = try TestStorage()
    defer { try? FileManager.default.removeItem(at: storage.directory) }
    let accounts = BetaAccountFixtures(first: ownerID, second: UUID())
    let inbox = SharedMealImageInbox(directory: storage.directory.appendingPathComponent("Inbox"), requiresAccount: true)
    let workflow = MealWorkflow(auth: accounts, sessionStore: storage,
                                betaApproval: accounts, accountDirectory: storage.directory.appendingPathComponent("Accounts"),
                                accountPreferences: { _ in storage }, now: { instant }, sharedImageInbox: inbox)

    #expect(throws: WorkflowIssue.signInRequired) { try inbox.beginShare(at: instant) }
    await workflow.signIn(email: "first@example.com", password: "correct")
    _ = try inbox.beginShare(at: instant)
    await workflow.signOut()
    #expect(throws: WorkflowIssue.signInRequired) { try inbox.enqueue(fixturePhoto, sharedAt: instant) }
    workflow.restoreSession()
    #expect(throws: WorkflowIssue.signInRequired) { try inbox.beginShare(at: instant) }
    await workflow.signIn(email: "second@example.com", password: "correct")
    let file = storage.directory.appendingPathComponent("image.jpg")
    try fixturePhoto.write(to: file)
    #expect(throws: DraftIssue.invalidPhoto) { try inbox.enqueueDocument(at: file, receivedAt: instant) }
    #expect(try Data(contentsOf: file) == fixturePhoto)
    workflow.resumeLocalWork()
    #expect(workflow.access == .owner)
    #expect(workflow.drafts.isEmpty)
    #expect(workflow.sharedDraftToOpen == nil)
}

@MainActor @Test func unclaimedBetaShareExpiresWhileAnotherAccountUsesBiteLens() async throws {
    let storage = try TestStorage()
    defer { try? FileManager.default.removeItem(at: storage.directory) }
    let accounts = BetaAccountFixtures(first: ownerID, second: UUID())
    let directory = storage.directory.appendingPathComponent("Inbox")
    let inbox = SharedMealImageInbox(directory: directory, requiresAccount: true)
    func openWorkflow(at time: Date) -> MealWorkflow {
        MealWorkflow(auth: accounts, sessionStore: storage,
                     betaApproval: accounts, accountDirectory: storage.directory.appendingPathComponent("Accounts"),
                     accountPreferences: { _ in storage }, now: { time }, sharedImageInbox: inbox)
    }

    let beforeExpiry = openWorkflow(at: instant)
    await beforeExpiry.signIn(email: "first@example.com", password: "correct")
    let cutoff = instant.addingTimeInterval(1)
    let id = try inbox.enqueue(fixturePhoto, sharedAt: cutoff.addingTimeInterval(-604_800), timeZone: .gmt)
    await beforeExpiry.signOut()
    await beforeExpiry.signIn(email: "second@example.com", password: "correct")
    #expect(beforeExpiry.drafts.isEmpty)
    #expect(beforeExpiry.nextPhotoExpiration == cutoff)

    let atExpiry = openWorkflow(at: cutoff)
    atExpiry.restoreSession()
    #expect(atExpiry.nextPhotoExpiration == nil)
    #expect(try !FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".plist") })
    await atExpiry.signOut()
    await atExpiry.signIn(email: "first@example.com", password: "correct")
    #expect(atExpiry.drafts.isEmpty)
    #expect(atExpiry.sharedDraftToOpen == nil)
    #expect(throws: DraftIssue.draftNotFound) { try atExpiry.photoData(for: id) }
}

private actor BetaAccountFixtures: AuthenticationClient, BetaAccountApproval {
    let first: UUID
    let second: UUID
    var approved: Set<UUID>
    var online = true

    init(first: UUID, second: UUID) {
        self.first = first
        self.second = second
        approved = [first, second]
    }

    func setOnline(_ online: Bool) { self.online = online }

    func setApproved(_ isApproved: Bool, for account: UUID) {
        if isApproved { approved.insert(account) }
        else { approved.remove(account) }
    }

    func signIn(email: String, password: String) async throws -> AuthSession {
        guard online else { throw AuthenticationFailure.unavailable }
        let account = email == "first@example.com" ? first : second
        return AuthSession(userID: account, accessToken: account.uuidString,
                           refreshToken: account.uuidString, expiresAt: instant.addingTimeInterval(3600))
    }

    func isApproved(accessToken: String) async throws -> Bool {
        guard online else { throw AuthenticationFailure.unavailable }
        guard let account = UUID(uuidString: accessToken) else { return false }
        return approved.contains(account)
    }

    func refresh(refreshToken: String) async throws -> AuthSession { throw AuthenticationFailure.unavailable }
    func signOut(accessToken: String) async throws {}
}

@MainActor @Test func betaAnalysisPermissionPersistsPerAccountAndProviderAndCanBeWithdrawn() async throws {
    let storage = try TestStorage()
    let accounts = BetaAccountFixtures(first: ownerID, second: UUID())
    let analysis = BetaAnalysisRecorder()
    let defaultsName = "BiteLensBetaAnalysisTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }

    func open() -> MealWorkflow {
        MealWorkflow(auth: accounts, sessionStore: storage, betaApproval: accounts,
                     accountDirectory: storage.directory.appendingPathComponent("accounts"),
                     accountPreferences: { UserDefaultsProviderPreferences(defaults: defaults, accountID: $0) },
                     now: { instant }, analysis: analysis)
    }

    let workflow = open()
    await workflow.signIn(email: "first@example.com", password: "correct")
    let draft = try workflow.startManualDraft()
    try workflow.updateDraftNotes(draft.id, notes: "Vegetable soup")
    await #expect(throws: AnalysisIssue.permissionRequired) { try await workflow.analyzeDraft(draft.id, provider: .openAI) }
    #expect(analysis.providers.isEmpty)

    workflow.setAnalysisPermission(for: .openAI, allowed: true)
    try await workflow.analyzeDraft(draft.id, provider: .openAI)
    await #expect(throws: AnalysisIssue.permissionRequired) { try await workflow.analyzeDraft(draft.id, provider: .grok) }
    #expect(analysis.providers == [.openAI])

    let reopened = open()
    reopened.restoreSession()
    #expect(reopened.hasAnalysisPermission(for: .openAI))
    #expect(!reopened.hasAnalysisPermission(for: .grok))

    await reopened.signOut()
    await reopened.signIn(email: "second@example.com", password: "correct")
    #expect(!reopened.hasAnalysisPermission(for: .openAI))
    reopened.setAnalysisPermission(for: .grok, allowed: true)

    await reopened.signOut()
    await reopened.signIn(email: "first@example.com", password: "correct")
    #expect(reopened.hasAnalysisPermission(for: .openAI))
    #expect(!reopened.hasAnalysisPermission(for: .grok))
    reopened.setAnalysisPermission(for: .openAI, allowed: false)
    await #expect(throws: AnalysisIssue.permissionRequired) { try await reopened.analyzeDraft(draft.id, provider: .openAI) }
    #expect(analysis.providers == [.openAI])

    let afterWithdrawal = open()
    afterWithdrawal.restoreSession()
    #expect(!afterWithdrawal.hasAnalysisPermission(for: .openAI))
    try afterWithdrawal.updateDraftItems(draft.id, items: [MealItem(name: "Vegetable soup")])
    let meal = try afterWithdrawal.confirmMeal(draft.id)
    #expect(afterWithdrawal.loggedMeals.map(\.id) == [meal.id])
    #expect(afterWithdrawal.pendingMealChanges.map(\.id) == [meal.id])
}

@MainActor private final class BetaAnalysisRecorder: MealAnalysisClient {
    private(set) var providers: [AIProvider] = []

    func estimate(provider: AIProvider, input: MealAnalysisInput, accessToken: String,
                  authorizeDispatch: @MainActor @Sendable () throws -> Void) async throws -> MealEstimate {
        try authorizeDispatch()
        providers.append(provider)
        return MealEstimate(items: [MealItem(name: "Vegetable soup")],
                            provenance: EstimateProvenance(provider: provider, model: "beta-fixture"))
    }
}

@MainActor @Test(arguments: [false, true])
func betaAnalysisCannotDispatchAfterPermissionWithdrawalOrAccountSwitch(switchAccount: Bool) async throws {
    let storage = try TestStorage()
    let accounts = BetaAccountFixtures(first: ownerID, second: UUID())
    let analysis = BetaAnalysisDispatchGate()
    let workflow = MealWorkflow(auth: accounts, sessionStore: storage, betaApproval: accounts,
                                accountDirectory: storage.directory.appendingPathComponent("accounts"),
                                accountPreferences: { _ in storage }, now: { instant }, analysis: analysis)
    await workflow.signIn(email: "first@example.com", password: "correct")
    workflow.setAnalysisPermission(for: .openAI, allowed: true)
    let draft = try workflow.startManualDraft()
    try workflow.updateDraftNotes(draft.id, notes: "Vegetable soup")
    let running = Task { try await workflow.analyzeDraft(draft.id) }
    await analysis.waitForPreparation()

    if switchAccount {
        await workflow.signIn(email: "second@example.com", password: "correct")
        workflow.setAnalysisPermission(for: .openAI, allowed: true)
    } else {
        workflow.setAnalysisPermission(for: .openAI, allowed: false)
    }
    analysis.finishPreparing()
    await #expect(throws: switchAccount ? AnalysisIssue.draftChanged : .permissionRequired) { try await running.value }
    #expect(!analysis.didDispatch)
}

@MainActor @Test func betaAnalysisResponseFromThePreviousAccountCannotModifyTheActiveDraft() async throws {
    let storage = try TestStorage()
    let accounts = BetaAccountFixtures(first: ownerID, second: UUID())
    let analysis = BetaAnalysisDispatchGate(prepare: false)
    let workflow = MealWorkflow(auth: accounts, sessionStore: storage, betaApproval: accounts,
                                accountDirectory: storage.directory.appendingPathComponent("accounts"),
                                accountPreferences: { _ in storage }, now: { instant }, analysis: analysis)
    await workflow.signIn(email: "first@example.com", password: "correct")
    workflow.setAnalysisPermission(for: .openAI, allowed: true)
    let firstDraft = try workflow.startManualDraft()
    try workflow.updateDraftNotes(firstDraft.id, notes: "Vegetable soup")
    let running = Task { try await workflow.analyzeDraft(firstDraft.id) }
    await analysis.waitForPreparation()
    #expect(analysis.didDispatch)

    await workflow.signIn(email: "second@example.com", password: "correct")
    let secondDraft = try workflow.startManualDraft()
    try workflow.updateDraftNotes(secondDraft.id, notes: "Rice bowl")
    analysis.finishPreparing()
    await #expect(throws: AnalysisIssue.draftChanged) { try await running.value }
    #expect(workflow.drafts.map(\.id) == [secondDraft.id])
    #expect(workflow.drafts.first?.review == nil)

    await workflow.signIn(email: "first@example.com", password: "correct")
    #expect(workflow.drafts.map(\.id) == [firstDraft.id])
    #expect(workflow.drafts.first?.review == nil)
}

@MainActor private final class BetaAnalysisDispatchGate: MealAnalysisClient {
    private let prepare: Bool
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var didDispatch = false

    init(prepare: Bool = true) { self.prepare = prepare }

    func estimate(provider: AIProvider, input: MealAnalysisInput, accessToken: String,
                  authorizeDispatch: @MainActor @Sendable () throws -> Void) async throws -> MealEstimate {
        if !prepare {
            try authorizeDispatch()
            didDispatch = true
        }
        await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
        if prepare {
            try authorizeDispatch()
            didDispatch = true
        }
        return MealEstimate(items: [MealItem(name: "Vegetable soup")],
                            provenance: EstimateProvenance(provider: provider, model: "beta-fixture"))
    }

    func waitForPreparation() async {
        if pending == nil { await withCheckedContinuation { started = $0 } }
    }

    func finishPreparing() {
        pending?.resume()
        pending = nil
    }
}

@MainActor @Test func betaSignInUsesSupabaseApprovalWithTheNewAccessToken() async throws {
    let config = try SupabaseConfiguration(url: URL(string: "https://auth.test.invalid")!, publishableKey: "sb_publishable_test")
    let network = URLSessionConfiguration.ephemeral
    network.protocolClasses = [SupabaseFixtureProtocol.self]
    let auth = SupabaseAuthenticationClient(configuration: config, session: URLSession(configuration: network), now: { instant })
    let storage = try TestStorage()
    let workflow = MealWorkflow(auth: auth, sessionStore: storage,
                                betaApproval: auth, accountDirectory: storage.directory.appendingPathComponent("accounts"),
                                accountPreferences: { _ in storage }, now: { instant })
    await workflow.signIn(email: "owner@example.com", password: "correct")
    #expect(workflow.activeAccountID == ownerID)
}

@MainActor @Test func betaAccountSwitchKeepsOfflineEditsAndLateAcknowledgementsWithTheirAccount() async throws {
    let storage = try TestStorage()
    let secondID = UUID()
    let accounts = BetaAccountFixtures(first: ownerID, second: secondID)
    let sync = BetaSuspendedSync(first: ownerID)
    func makeWorkflow(using localStorage: TestStorage) -> MealWorkflow {
        MealWorkflow(auth: accounts, sessionStore: localStorage,
                     betaApproval: accounts, accountDirectory: localStorage.directory.appendingPathComponent("accounts"),
                     accountPreferences: { _ in localStorage }, now: { instant }, mealSync: sync)
    }
    let workflow = makeWorkflow(using: storage)

    func logMeal() throws -> LoggedMeal {
        let draft = try workflow.startManualDraft()
        try workflow.updateDraftItems(draft.id, items: [
            MealItem(name: "Rice", portion: ConsumedPortion(grams: 100, servingDescription: "1 bowl"),
                     nutrients: NutrientAmounts(caloriesKcal: 130))
        ])
        return try workflow.confirmMeal(draft.id)
    }

    await workflow.signIn(email: "first@example.com", password: "correct")
    let firstMeal = try logMeal()
    let upload = Task { await workflow.syncPendingMealChanges() }
    await sync.waitForFirstUpload()

    var items = firstMeal.record.items
    items[0].portion.grams = 50
    let corrected = try workflow.updateLoggedMeal(firstMeal.id, mealTime: firstMeal.record.mealTime,
                                                   notes: "Half a bowl", items: items)
    let pendingEdit = PendingMealChange.save(corrected.record, revision: 2)
    #expect(workflow.pendingMealChanges == [pendingEdit])

    await workflow.signOut()
    await workflow.signIn(email: "second@example.com", password: "correct")
    #expect(workflow.loggedMeals.isEmpty)
    let secondMeal = try logMeal()
    await workflow.syncPendingMealChanges()
    #expect(workflow.pendingMealChanges.isEmpty)
    var secondItems = secondMeal.record.items
    secondItems[0].portion.grams = 75
    let secondCorrection = try workflow.updateLoggedMeal(secondMeal.id, mealTime: secondMeal.record.mealTime,
                                                          notes: "Three quarters of a bowl", items: secondItems)
    let pendingSecondEdit = PendingMealChange.save(secondCorrection.record, revision: 2)
    await sync.acknowledgeFirstUpload()
    await upload.value
    #expect(workflow.loggedMeals.map(\.record) == [secondCorrection.record])
    #expect(workflow.pendingMealChanges == [pendingSecondEdit])
    await workflow.syncPendingMealChanges()
    #expect(workflow.pendingMealChanges.isEmpty)

    let freshInstall = makeWorkflow(using: try TestStorage())
    await freshInstall.signIn(email: "second@example.com", password: "correct")
    #expect(freshInstall.activeAccountID == secondID)
    #expect(freshInstall.loggedMeals.isEmpty)
    #expect(freshInstall.pendingMealChanges.isEmpty)

    await workflow.signOut()
    await workflow.signIn(email: "first@example.com", password: "correct")
    #expect(workflow.loggedMeals.map(\.record) == [corrected.record])
    #expect(workflow.pendingMealChanges == [pendingEdit])
    await sync.setOnline(false)
    await workflow.syncPendingMealChanges()
    #expect(workflow.pendingMealChanges == [pendingEdit])
    await sync.setOnline(true)
    await workflow.syncPendingMealChanges()
    #expect(workflow.pendingMealChanges.isEmpty)

    await sync.setOnline(false)
    try workflow.deleteLoggedMeal(firstMeal.id)
    let pendingDeletion = PendingMealChange.delete(id: firstMeal.id, ownerID: ownerID, revision: 3)
    let reopened = makeWorkflow(using: storage)
    reopened.restoreSession()
    #expect(reopened.loggedMeals.isEmpty)
    #expect(reopened.pendingMealChanges == [pendingDeletion])
    await sync.setOnline(true)
    await reopened.syncPendingMealChanges()
    #expect(reopened.pendingMealChanges.isEmpty)
    #expect(await sync.sentChanges() == [
        .save(firstMeal.record, revision: 1),
        .save(secondMeal.record, revision: 1),
        pendingSecondEdit, pendingEdit, pendingDeletion,
    ])
}

private actor BetaSuspendedSync: MealSyncClient {
    let first: UUID
    var sent: [PendingMealChange] = []
    var online = true
    var arrival: CheckedContinuation<Void, Never>?
    var pending: CheckedContinuation<Void, Never>?

    init(first: UUID) { self.first = first }

    func sync(_ change: PendingMealChange, accessToken: String) async throws -> MealSyncAcknowledgement {
        #expect(accessToken == change.ownerID.uuidString)
        guard online else { throw URLError(.notConnectedToInternet) }
        sent.append(change)
        if change.ownerID == first && sent.count == 1 {
            await withCheckedContinuation { continuation in
                pending = continuation
                arrival?.resume()
                arrival = nil
            }
        }
        return MealSyncAcknowledgement(id: change.id, revision: change.revision)
    }

    func waitForFirstUpload() async {
        if pending == nil { await withCheckedContinuation { arrival = $0 } }
    }

    func setOnline(_ online: Bool) { self.online = online }

    func sentChanges() -> [PendingMealChange] { sent }

    func acknowledgeFirstUpload() {
        pending?.resume()
        pending = nil
    }
}

@MainActor @Test func betaObservationUploadsKeepOfflineChangesAndLateAcknowledgementsWithTheirAccount() async throws {
    let storage = try TestStorage()
    let secondID = UUID()
    let accounts = BetaAccountFixtures(first: ownerID, second: secondID)
    let sync = BetaSuspendedObservationSync()
    func makeWorkflow() -> MealWorkflow {
        MealWorkflow(auth: accounts, sessionStore: storage,
                     betaApproval: accounts, accountDirectory: storage.directory.appendingPathComponent("accounts"),
                     accountPreferences: { _ in storage }, now: { instant }, observationSync: sync)
    }

    let workflow = makeWorkflow()
    await workflow.signIn(email: "first@example.com", password: "correct")
    let symptom = try workflow.logSymptom(.headache)
    let firstSave = PendingObservationChange.save(symptom.record, revision: 1)
    await sync.setOnline(false)
    await workflow.syncPendingObservationChanges()
    #expect(workflow.pendingObservationChanges == [firstSave])

    await sync.setOnline(true)
    let firstUpload = Task { await workflow.syncPendingObservationChanges() }
    await sync.waitForFirstUpload()
    await workflow.signOut()
    await workflow.signIn(email: "second@example.com", password: "correct")
    #expect(workflow.loggedObservations.isEmpty)
    #expect(workflow.pendingObservationChanges.isEmpty)

    let urge = try workflow.logUrge()
    let secondSave = PendingObservationChange.save(urge.record, revision: 1)
    await sync.acknowledgeFirstUpload()
    await firstUpload.value
    #expect(workflow.loggedObservations == [urge])
    #expect(workflow.pendingObservationChanges == [secondSave])
    await workflow.syncPendingObservationChanges()
    #expect(workflow.pendingObservationChanges.isEmpty)

    await workflow.signOut()
    await workflow.signIn(email: "first@example.com", password: "correct")
    #expect(workflow.loggedObservations == [symptom])
    #expect(workflow.pendingObservationChanges == [firstSave])
    await workflow.syncPendingObservationChanges()
    #expect(workflow.pendingObservationChanges.isEmpty)

    await sync.setOnline(false)
    let edited = try workflow.updateObservation(symptom.id, time: symptom.record.time,
                                                severity: .severe, notes: "After lunch")
    let edit = PendingObservationChange.save(edited.record, revision: 2)
    let reopened = makeWorkflow()
    reopened.restoreSession()
    #expect(reopened.loggedObservations == [edited])
    #expect(reopened.pendingObservationChanges == [edit])

    await sync.setOnline(true)
    await reopened.syncPendingObservationChanges()
    #expect(reopened.pendingObservationChanges.isEmpty)
    try reopened.deleteObservation(symptom.id)
    await reopened.syncPendingObservationChanges()
    #expect(reopened.loggedObservations.isEmpty)
    #expect(reopened.pendingObservationChanges.isEmpty)
    #expect(await sync.sent == [
        firstSave, secondSave, firstSave, edit,
        .delete(id: symptom.id, ownerID: ownerID, revision: 3),
    ])
}

private actor BetaSuspendedObservationSync: ObservationSyncClient {
    private(set) var sent: [PendingObservationChange] = []
    private var online = true
    private var arrival: CheckedContinuation<Void, Never>?
    private var acknowledgement: CheckedContinuation<Void, Never>?

    func sync(_ change: PendingObservationChange, accessToken: String) async throws -> MealSyncAcknowledgement {
        #expect(accessToken == change.ownerID.uuidString)
        guard online else { throw URLError(.notConnectedToInternet) }
        sent.append(change)
        if sent.count == 1 {
            await withCheckedContinuation { continuation in
                acknowledgement = continuation
                arrival?.resume()
                arrival = nil
            }
        }
        return MealSyncAcknowledgement(id: change.id, revision: change.revision)
    }

    func waitForFirstUpload() async {
        if sent.isEmpty { await withCheckedContinuation { arrival = $0 } }
    }

    func acknowledgeFirstUpload() {
        acknowledgement?.resume()
        acknowledgement = nil
    }

    func setOnline(_ online: Bool) { self.online = online }
}
