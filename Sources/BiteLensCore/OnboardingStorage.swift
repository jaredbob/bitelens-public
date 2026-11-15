import Foundation
import Security

public enum SecureStorageFailure: Error, Sendable { case unavailable }

/// Session tokens stay in the app's private Keychain, unavailable while locked,
/// excluded from migration to another device. No shared Keychain access group.
public struct KeychainSessionStore: SessionStore {
    private let service: String
    private let account = "supabase-owner-session"

    public init(service: String = "com.example.BiteLens.auth") { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    public func load() throws -> AuthSession? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let session = try? JSONDecoder().decode(AuthSession.self, from: data) else {
            throw SecureStorageFailure.unavailable
        }
        return session
    }

    public func save(_ session: AuthSession) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(session),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let addition = query.merging(attributes) { _, value in value }
            guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else { throw SecureStorageFailure.unavailable }
        } else if status != errSecSuccess { throw SecureStorageFailure.unavailable }
    }

    public func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecureStorageFailure.unavailable }
    }
}

public struct UserDefaultsProviderPreferences: ProviderPreferences, @unchecked Sendable {
    private let defaults: UserDefaults
    private let namespace: String

    public init(defaults: UserDefaults = .standard, accountID: UUID? = nil) {
        self.defaults = defaults
        self.namespace = accountID.map { "bitelens.account.\($0.uuidString)" } ?? "bitelens"
    }

    private var key: String { "\(namespace).selected-ai-provider" }
    public func loadProvider() -> AIProvider? {
        defaults.string(forKey: key).flatMap(AIProvider.init(rawValue:))
    }
    public func saveProvider(_ provider: AIProvider) { defaults.set(provider.rawValue, forKey: key) }

    private var permissionsKey: String { "\(namespace).ai-analysis-permissions" }
    public func loadAnalysisPermissions() -> Set<AIProvider> {
        Set((defaults.stringArray(forKey: permissionsKey) ?? []).compactMap(AIProvider.init(rawValue:)))
    }

    public func saveAnalysisPermissions(_ providers: Set<AIProvider>) {
        defaults.set(providers.map(\.rawValue).sorted(), forKey: permissionsKey)
    }
}
