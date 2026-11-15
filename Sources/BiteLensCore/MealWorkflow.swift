import Foundation
import Observation

public enum AIProvider: String, CaseIterable, Codable, Sendable {
    case openAI = "openai"
    case grok
}

public struct AuthSession: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "AuthSession(<redacted>)" }
    public var debugDescription: String { description }
    public let userID: UUID
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date

    public init(userID: UUID, accessToken: String, refreshToken: String, expiresAt: Date) {
        self.userID = userID
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public protocol AuthenticationClient: Sendable {
    func signIn(email: String, password: String) async throws -> AuthSession
    func refresh(refreshToken: String) async throws -> AuthSession
    func signOut(accessToken: String) async throws
}

public protocol BetaAccountApproval: Sendable {
    func isApproved(accessToken: String) async throws -> Bool
}

public protocol SessionStore: Sendable {
    func load() throws -> AuthSession?
    func save(_ session: AuthSession) throws
    func clear() throws
}

public protocol ProviderPreferences: Sendable {
    func loadProvider() -> AIProvider?
    func saveProvider(_ provider: AIProvider)
    func loadAnalysisPermissions() -> Set<AIProvider>
    func saveAnalysisPermissions(_ providers: Set<AIProvider>)
}

public extension ProviderPreferences {
    func loadAnalysisPermissions() -> Set<AIProvider> { [] }
    func saveAnalysisPermissions(_ providers: Set<AIProvider>) {}
}

public enum AppAccess: Equatable, Sendable {
    case signedOut
    case owner
    case denied
}

public enum AuthenticationFailure: Error, Equatable, Sendable {
    case invalidCredentials
    case sessionExpired
    case unavailable
    case invalidResponse
}

public enum CloudStatus: Equatable, Sendable {
    case signedOut
    case ready
    case refreshRequired
    case offline
    case reauthenticationRequired
}

public enum WorkflowIssue: Error, Equatable, Sendable {
    case invalidCredentials
    case authenticationUnavailable
    case storageUnavailable
    case accessDenied
    case signInRequired
}

@MainActor @Observable public final class MealWorkflow {
    public private(set) var access: AppAccess = .signedOut
    public private(set) var cloudStatus: CloudStatus = .signedOut
    public internal(set) var issue: WorkflowIssue?
    public private(set) var isAuthenticating = false
    public private(set) var selectedProvider: AIProvider?
    private var analysisPermissions: Set<AIProvider> = []
    public internal(set) var sharedDraftToOpen: UUID?
    let auth: any AuthenticationClient
    let sessionStore: any SessionStore
    private let personalOwnerID: UUID?
    private let betaApproval: (any BetaAccountApproval)?
    let accountDirectory: URL?
    private let accountPreferences: (@MainActor (UUID) -> any ProviderPreferences)?
    private let activeAccountChanged: (@MainActor (UUID?) -> Void)?
    public var isBeta: Bool { betaApproval != nil }
    public var activeAccountID: UUID? { access == .owner ? session?.userID : nil }
    public private(set) var accountActivationID = UUID()
    private(set) var preferences: (any ProviderPreferences)?
    let now: @Sendable () -> Date
    var session: AuthSession?
    var authenticationGeneration = 0
    var refreshTask: Task<AuthSession, Error>?
    let analysis: (any MealAnalysisClient)?
    @ObservationIgnored var receiptEmailHeader: @Sendable (Data) async -> String? = ReceiptImageTime.emailHeader(in:)
    var analyzingDraftIDs = Set<UUID>()
    private(set) var draftStorage: LocalMealDraftStorage?
    let sharedImageInbox: SharedMealImageInbox?
    var localMeals = LocalMealLibrary()
    var localMealsLoaded = false
    var photoCleanupEvaluatedAt = Date.distantPast
    var scheduledPhotoExpiration: Date?
    var inactivePhotoExpiration: Date?
    var sharedImageExpiration: Date?
    let mealSync: (any MealSyncClient)?
    let observationAppleHealth: (any ObservationAppleHealthClient)?
    @ObservationIgnored var observationAppleHealthTask: Task<Void, Never>?
    @ObservationIgnored var needsObservationAppleHealthPass = false
    let observationSync: (any ObservationSyncClient)?
    @ObservationIgnored var observationSyncGeneration: Int?
    @ObservationIgnored var mealSyncGeneration: Int?
    let appleHealth: (any AppleHealthClient)?
    var betaAppleHealthAccount: BetaAppleHealthAccount = .unavailable
    var appleHealthWriteAccess: AppleHealthSyncStatus.WriteAccess = .checking
    @ObservationIgnored var appleHealthSyncTask: Task<Void, Never>?
    @ObservationIgnored var needsAppleHealthSyncPass = false
    @ObservationIgnored var shouldRequestAppleHealthAuthorization = false
    @ObservationIgnored var appleHealthAuthorizationActivation: UUID?

    public convenience init(auth: any AuthenticationClient, sessionStore: any SessionStore,
                            preferences: any ProviderPreferences, approvedOwnerID: UUID,
                            now: @escaping @Sendable () -> Date = Date.init,
                            analysis: (any MealAnalysisClient)? = nil,
                            draftStorage: LocalMealDraftStorage? = nil,
                            mealSync: (any MealSyncClient)? = nil,
                            sharedImageInbox: SharedMealImageInbox? = nil,
                            appleHealth: (any AppleHealthClient)? = nil,
                            observationSync: (any ObservationSyncClient)? = nil,
                            observationAppleHealth: (any ObservationAppleHealthClient)? = nil) {
        self.init(auth: auth, sessionStore: sessionStore, preferences: preferences,
                  personalOwnerID: approvedOwnerID, now: now, analysis: analysis,
                  draftStorage: draftStorage, mealSync: mealSync, sharedImageInbox: sharedImageInbox,
                  appleHealth: appleHealth, observationSync: observationSync,
                  observationAppleHealth: observationAppleHealth)
    }

    public convenience init(auth: any AuthenticationClient, sessionStore: any SessionStore,
                            betaApproval: any BetaAccountApproval, accountDirectory: URL,
                            accountPreferences: @escaping @MainActor (UUID) -> any ProviderPreferences,
                            activeAccountChanged: @escaping @MainActor (UUID?) -> Void = { _ in },
                            now: @escaping @Sendable () -> Date = Date.init,
                            analysis: (any MealAnalysisClient)? = nil,
                            mealSync: (any MealSyncClient)? = nil,
                            sharedImageInbox: SharedMealImageInbox? = nil,
                            appleHealth: (any AppleHealthClient)? = nil,
                            observationSync: (any ObservationSyncClient)? = nil,
                            observationAppleHealth: (any ObservationAppleHealthClient)? = nil) {
        self.init(auth: auth, sessionStore: sessionStore, preferences: nil, betaApproval: betaApproval,
                  accountDirectory: accountDirectory, accountPreferences: accountPreferences,
                  activeAccountChanged: activeAccountChanged, now: now, analysis: analysis,
                  mealSync: mealSync, sharedImageInbox: sharedImageInbox, appleHealth: appleHealth,
                  observationSync: observationSync, observationAppleHealth: observationAppleHealth)
    }

    private init(auth: any AuthenticationClient, sessionStore: any SessionStore,
                 preferences: (any ProviderPreferences)? = nil, personalOwnerID: UUID? = nil,
                 betaApproval: (any BetaAccountApproval)? = nil, accountDirectory: URL? = nil,
                 accountPreferences: (@MainActor (UUID) -> any ProviderPreferences)? = nil,
                 activeAccountChanged: (@MainActor (UUID?) -> Void)? = nil,
                 now: @escaping @Sendable () -> Date,
                 analysis: (any MealAnalysisClient)?, draftStorage: LocalMealDraftStorage? = nil,
                 mealSync: (any MealSyncClient)?, sharedImageInbox: SharedMealImageInbox?,
                 appleHealth: (any AppleHealthClient)? = nil,
                 observationSync: (any ObservationSyncClient)?,
                 observationAppleHealth: (any ObservationAppleHealthClient)? = nil) {
        self.auth = auth
        self.sessionStore = sessionStore
        self.preferences = preferences
        self.personalOwnerID = personalOwnerID
        self.betaApproval = betaApproval
        self.accountDirectory = accountDirectory
        self.accountPreferences = accountPreferences
        self.activeAccountChanged = activeAccountChanged
        self.now = now
        self.analysis = analysis
        self.draftStorage = draftStorage
        self.mealSync = mealSync
        self.observationSync = observationSync
        self.observationAppleHealth = observationAppleHealth
        self.sharedImageInbox = sharedImageInbox
        self.appleHealth = appleHealth
        self.selectedProvider = preferences?.loadProvider()
    }

    /// Restores only the Keychain-backed identity. No network is needed to use
    /// local work; cloud operations must obtain a refreshed token separately.
    public func restoreSession() {
        defer { resumeLocalWork() }
        do {
            guard session == nil, !isAuthenticating else { return }
            guard let saved = try sessionStore.load() else {
                try sharedImageInbox?.setActiveAccount(nil)
                activeAccountChanged?(nil)
                return
            }
            guard isBeta || saved.userID == personalOwnerID else {
                access = .denied
                try sessionStore.clear()
                return
            }
            activate(saved)
        } catch { issue = .storageUnavailable }
    }

    /// All later analysis/sync clients obtain a token here. Server interfaces
    /// must independently authorize the account; local UI gating is insufficient.
    public func accessToken() async throws -> String {
        try await accessToken(rejecting: nil)
    }

    func accessToken(rejecting rejectedToken: String?) async throws -> String {
        guard !isAuthenticating, let current = session, activeAccountID != nil else { throw WorkflowIssue.signInRequired }
        if hasFreshAccessToken(current), current.accessToken != rejectedToken { return current.accessToken }
        let generation = authenticationGeneration
        let task: Task<AuthSession, Error>
        if let active = refreshTask { task = active }
        else {
            let auth = self.auth
            task = Task { try await auth.refresh(refreshToken: current.refreshToken) }
            refreshTask = task
        }
        defer { if generation == authenticationGeneration { refreshTask = nil } }
        let refreshed: AuthSession
        do { refreshed = try await task.value }
        catch AuthenticationFailure.sessionExpired {
            guard generation == authenticationGeneration else { throw WorkflowIssue.signInRequired }
            requireCloudReauthentication()
            throw WorkflowIssue.signInRequired
        } catch {
            guard generation == authenticationGeneration else { throw WorkflowIssue.signInRequired }
            cloudStatus = .offline
            throw WorkflowIssue.authenticationUnavailable
        }
        guard generation == authenticationGeneration else { throw WorkflowIssue.signInRequired }
        guard refreshed.userID == current.userID else {
            if isBeta { requireCloudReauthentication() }
            else {
                session = nil
                access = .denied
                try sessionStore.clear()
            }
            throw WorkflowIssue.accessDenied
        }
        try sessionStore.save(refreshed)
        session = refreshed
        cloudStatus = .ready
        issue = nil
        return refreshed.accessToken
    }

    /// Clears only credentials. Meal data and the explicit provider choice are
    /// deliberately independent of reauthentication and sign-out.
    public func signOut() async {
        do {
            // Invalidate the shared identity before changing the durable session.
            try sharedImageInbox?.setActiveAccount(nil)
            try sessionStore.clear()
        }
        catch { issue = .storageUnavailable; return }
        invalidateInFlightAuthentication()
        isAuthenticating = false
        let oldToken = session?.accessToken
        session = nil
        access = .signedOut
        sharedDraftToOpen = nil
        accountActivationID = UUID()
        if isBeta {
            clearAccountState()
            activeAccountChanged?(nil)
        } else {
            resetAppleHealthWork()
        }
        cloudStatus = .signedOut
        issue = nil
        if isBeta { resumeLocalWork() }
        if let oldToken { try? await auth.signOut(accessToken: oldToken) }
    }

    public func selectProvider(_ provider: AIProvider) {
        guard access == .owner else { return }
        preferences?.saveProvider(provider)
        selectedProvider = provider
    }

    public func hasAnalysisPermission(for provider: AIProvider) -> Bool {
        !isBeta || analysisPermissions.contains(provider)
    }

    public func setAnalysisPermission(for provider: AIProvider, allowed: Bool) {
        guard isBeta, activeAccountID != nil, let preferences else { return }
        if allowed { analysisPermissions.insert(provider) }
        else { analysisPermissions.remove(provider) }
        preferences.saveAnalysisPermissions(analysisPermissions)
    }

    public func signIn(email: String, password: String) async {
        guard !isAuthenticating else { return }
        invalidateInFlightAuthentication()
        let generation = authenticationGeneration
        isAuthenticating = true
        issue = nil
        defer { if generation == authenticationGeneration { isAuthenticating = false } }
        do {
            let newSession = try await auth.signIn(email: email, password: password)
            guard generation == authenticationGeneration else { return }
            let approved: Bool
            if let betaApproval {
                approved = try await betaApproval.isApproved(accessToken: newSession.accessToken)
                guard generation == authenticationGeneration else { return }
            } else {
                approved = newSession.userID == personalOwnerID
            }
            guard approved else {
                if !isBeta || activeAccountID == nil {
                    session = nil
                    access = .denied
                    cloudStatus = .signedOut
                    try? sessionStore.clear()
                }
                issue = .accessDenied
                return
            }
            do {
                if isBeta, activeAccountID != newSession.userID {
                    try sharedImageInbox?.setActiveAccount(nil)
                }
                try sessionStore.save(newSession)
            }
            catch { issue = .storageUnavailable; return }
            activate(newSession)
            resumeLocalWork()
        } catch AuthenticationFailure.invalidCredentials {
            guard generation == authenticationGeneration else { return }
            issue = .invalidCredentials
        } catch {
            guard generation == authenticationGeneration else { return }
            issue = .authenticationUnavailable
        }
    }

    private func activate(_ newSession: AuthSession) {
        let changedAccount = activeAccountID != newSession.userID
        session = newSession
        access = .owner
        cloudStatus = hasFreshAccessToken(newSession) ? .ready : .refreshRequired
        guard changedAccount else { return }
        accountActivationID = UUID()
        if let accountDirectory, let accountPreferences {
            clearAccountState()
            draftStorage = LocalMealDraftStorage(
                directory: accountDirectory.appendingPathComponent(newSession.userID.uuidString, isDirectory: true))
            let newPreferences = accountPreferences(newSession.userID)
            preferences = newPreferences
            selectedProvider = newPreferences.loadProvider() ?? .openAI
            analysisPermissions = newPreferences.loadAnalysisPermissions()
            activeAccountChanged?(newSession.userID)
        }
    }

    private func clearAccountState() {
        resetAppleHealthWork()
        draftStorage = nil
        preferences = nil
        selectedProvider = nil
        analysisPermissions.removeAll()
        localMeals = LocalMealLibrary()
        localMealsLoaded = false
        sharedDraftToOpen = nil
        analyzingDraftIDs.removeAll()
        photoCleanupEvaluatedAt = .distantPast
        scheduledPhotoExpiration = nil
    }

    private func resetAppleHealthWork() {
        // An outstanding HealthKit operation can finish. Its pass checks the
        // activation before doing more work or saving a local acknowledgment.
        appleHealthWriteAccess = .checking
        needsAppleHealthSyncPass = false
        shouldRequestAppleHealthAuthorization = false
        needsObservationAppleHealthPass = false
    }

    func requireCloudReauthentication() {
        cloudStatus = .reauthenticationRequired
        issue = .signInRequired
    }

    private func hasFreshAccessToken(_ session: AuthSession) -> Bool {
        session.expiresAt > now().addingTimeInterval(60)
    }

    private func invalidateInFlightAuthentication() {
        authenticationGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
    }
}
