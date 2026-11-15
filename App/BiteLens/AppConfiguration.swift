import BiteLensCore
import Foundation

enum AppConfiguration {
    private static let supabase: SupabaseConfiguration? = {
        guard let host = setting("BiteLensSupabaseHost"),
              let key = setting("BiteLensSupabasePublishableKey") else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        guard let url = components.url else { return nil }
        return try? SupabaseConfiguration(url: url, publishableKey: key)
    }()

    private static func setting(_ name: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: name) as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    static var betaPrivacyPolicyURL: URL? {
        supabase?.url.appending(path: "functions/v1/beta-privacy")
    }

    static var betaSupportEmail: String? {
        setting("BiteLensBetaSupportEmail")
    }

    @MainActor static func makeWorkflow() -> MealWorkflow? {
        #if DEBUG
        if UITestMode.isEnabled { return UITestMode.makeWorkflow() }
        #endif
        guard let supabase else { return nil }
        let service = (Bundle.main.bundleIdentifier ?? "com.example.BiteLens") + ".auth"
        let auth = SupabaseAuthenticationClient(configuration: supabase)
        #if BITELENS_BETA
        return MealWorkflow(auth: auth,
                            sessionStore: KeychainSessionStore(service: service),
                            betaApproval: auth,
                            accountDirectory: URL.applicationSupportDirectory.appendingPathComponent("Accounts", isDirectory: true),
                            accountPreferences: { UserDefaultsProviderPreferences(accountID: $0) },
                            analysis: SupabaseMealAnalysisClient(configuration: supabase),
                            mealSync: SupabaseMealSyncClient(configuration: supabase),
                            sharedImageInbox: .appGroup(requiresAccount: true),
                            observationSync: SupabaseObservationSyncClient(configuration: supabase))
        #else
        guard let owner = setting("BiteLensOwnerID"),
              let approvedOwnerID = UUID(uuidString: owner) else { return nil }
        let healthKit = HealthKitClient()
        return MealWorkflow(auth: auth,
                     sessionStore: KeychainSessionStore(service: service),
                     preferences: UserDefaultsProviderPreferences(),
                     approvedOwnerID: approvedOwnerID,
                     analysis: SupabaseMealAnalysisClient(configuration: supabase),
                     draftStorage: LocalMealDraftStorage(directory: URL.applicationSupportDirectory.appendingPathComponent("BiteLens", isDirectory: true)),
                     mealSync: SupabaseMealSyncClient(configuration: supabase),
                     sharedImageInbox: .appGroup(),
                     appleHealth: healthKit,
                     observationSync: SupabaseObservationSyncClient(configuration: supabase),
                     observationAppleHealth: healthKit)
        #endif
    }
}
