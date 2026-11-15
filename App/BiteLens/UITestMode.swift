import BiteLensCore
import Foundation
import SwiftUI
#if DEBUG
import UIKit
#endif

/// Debug-only launch gate for the simulator smoke suite.
/// Release builds compile `isEnabled` to false and omit the stub workflow.
enum UITestMode {
    static let launchArgument = "-BiteLensUITesting"

    static var isEnabled: Bool {
        #if DEBUG
        let process = ProcessInfo.processInfo
        return process.arguments.contains(launchArgument) || process.environment["BITELENS_UI_TESTING"] == "1"
        #else
        false
        #endif
    }

    #if DEBUG
    static let ownerID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    @MainActor static func prepareLaunch(workflow: MealWorkflow) {
        UIView.setAnimationsEnabled(false)
        workflow.restoreSession()
        guard ProcessInfo.processInfo.arguments.contains("-BiteLensUITestPhotoDraft") else { return }

        let size = CGSize(width: 120, height: 90)
        let photoData = UIGraphicsImageRenderer(size: size).pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        do {
            let draft = try workflow.captureMeal(photoData: photoData)
            try workflow.updateDraftItems(draft.id, items: [MealItem(name: "Toast")])
        } catch {
            assertionFailure("Couldn't seed the UI test photo draft: \(error)")
        }
    }

    /// Owner session, fixture analysis, and local storage. No Keychain, camera,
    /// HealthKit, Supabase, or AI provider calls.
    @MainActor static func makeWorkflow() -> MealWorkflow {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BiteLensUITests", isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
        }
        return MealWorkflow(auth: UITestAuthenticationClient(),
                            sessionStore: UITestSessionStore(),
                            preferences: UITestProviderPreferences(),
                            approvedOwnerID: UITestMode.ownerID,
                            analysis: UITestAnalysisClient(),
                            draftStorage: LocalMealDraftStorage(directory: directory),
                            mealSync: UITestMealSyncClient(),
                            observationSync: UITestObservationSyncClient())
    }
    #endif
}

extension View {
    /// Keyboard dismiss control used only while UI-test mode is on.
    @ViewBuilder func uiTestKeyboardDismiss(perform dismiss: @escaping () -> Void) -> some View {
        #if DEBUG
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if UITestMode.isEnabled {
                    Button("Hide keyboard", action: dismiss)
                        .accessibilityIdentifier("hide-keyboard")
                }
            }
        }
        #else
        self
        #endif
    }
}

#if DEBUG
private enum UITestSession {
    static func owner() -> AuthSession {
        AuthSession(userID: UITestMode.ownerID,
                    accessToken: "uitest-access-token",
                    refreshToken: "uitest-refresh-token",
                    expiresAt: .distantFuture)
    }
}

private struct UITestAuthenticationClient: AuthenticationClient {
    func signIn(email: String, password: String) async throws -> AuthSession {
        throw AuthenticationFailure.unavailable
    }

    func refresh(refreshToken: String) async throws -> AuthSession { UITestSession.owner() }

    func signOut(accessToken: String) async throws {}
}

private struct UITestSessionStore: SessionStore {
    func load() throws -> AuthSession? { UITestSession.owner() }
    func save(_ session: AuthSession) throws {}
    func clear() throws {}
}

private struct UITestProviderPreferences: ProviderPreferences {
    func loadProvider() -> AIProvider? { .openAI }
    func saveProvider(_ provider: AIProvider) {}
}

private struct UITestAnalysisClient: MealAnalysisClient {
    func estimate(provider: AIProvider, input: MealAnalysisInput,
                  accessToken: String,
                  authorizeDispatch: @MainActor @Sendable () throws -> Void) async throws -> MealEstimate {
        try await authorizeDispatch()
        let item = MealItem(name: "Scrambled eggs",
                            portion: ConsumedPortion(grams: 100, servingDescription: "2 eggs"),
                            nutrients: NutrientAmounts(caloriesKcal: 180, proteinGrams: 12))
        return MealEstimate(items: [item],
                            provenance: EstimateProvenance(provider: provider, model: "ui-test-fixture"))
    }
}

private struct UITestMealSyncClient: MealSyncClient {
    func sync(_ change: PendingMealChange, accessToken: String) async throws -> MealSyncAcknowledgement {
        MealSyncAcknowledgement(id: change.id, revision: change.revision)
    }
}

private struct UITestObservationSyncClient: ObservationSyncClient {
    func sync(_ change: PendingObservationChange, accessToken: String) async throws -> MealSyncAcknowledgement {
        MealSyncAcknowledgement(id: change.id, revision: change.revision)
    }
}
#endif
