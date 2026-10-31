import Foundation
import Security

/// The persisted Supabase Auth session for the current account: both tokens and
/// enough metadata to know when a refresh is due and who the tokens belong to.
///
/// The refresh token is what lets a provider-backed account come back after
/// relaunch as a *provider* account rather than silently degrading to a local
/// one — which matters now that the sync backend authenticates with that
/// bearer. Storing the access token and its expiry alongside means a session
/// that outlives the access token refreshes on demand mid-session, instead of
/// 401ing until the next launch.
struct SupabaseTokenSet: Codable, Equatable {
    var userID: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    /// Refresh slightly early so an in-flight request never carries a token
    /// that expires mid-request.
    var needsRefresh: Bool {
        Date.now >= expiresAt.addingTimeInterval(-60)
    }

    var isStructurallyValid: Bool {
        UUID(uuidString: userID) != nil
            && !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && expiresAt.timeIntervalSinceReferenceDate.isFinite
    }
}

/// Keychain-backed storage for the Supabase session. Tokens are credentials, so
/// they live in the Keychain rather than UserDefaults.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` keeps the credential off
/// backups and off other devices, while still allowing a background refresh
/// after the first unlock following a reboot.
enum SupabaseSessionStore {
    private static let service = "nz.co.thinkingai.Grove.supabase-session"
    private static let account = "current"

    static func load() -> SupabaseTokenSet? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        guard let tokens = try? JSONDecoder().decode(SupabaseTokenSet.self, from: data),
              tokens.isStructurallyValid else {
            clear()
            return nil
        }
        return tokens
    }

    @discardableResult
    static func save(_ tokens: SupabaseTokenSet) -> Bool {
        guard tokens.isStructurallyValid,
              let data = try? JSONEncoder().encode(tokens) else { return false }
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess { return true }
        if status == errSecDuplicateItem {
            return SecItemUpdate(
                baseQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            ) == errSecSuccess
        }
        return false
    }

    /// Removes the credential. Called on sign-out and on local-data deletion —
    /// a signed-out device must not keep a token that can mint new sessions.
    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// Device-bound storage for the bearer URLs that open public sitting sheets.
///
/// The URL is a credential: anybody holding it can see the scoped plant brief
/// and may record care. Invite metadata belongs in the ordinary account
/// snapshot, but the bearer itself must not be copied into UserDefaults,
/// backups, logs, or data-export JSON.
enum SittingInviteURLStore {
    private static let servicePrefix = "nz.co.thinkingai.Grove.sitting-invite"

    static func load(accountID: String, inviteID: UUID) -> URL? {
        var query = baseQuery(accountID: accountID, inviteID: inviteID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              let url = URL(string: value),
              url.scheme == "https"
        else { return nil }
        return url
    }

    @discardableResult
    static func save(_ url: URL, accountID: String, inviteID: UUID) -> Bool {
        guard url.scheme == "https",
              let data = url.absoluteString.data(using: .utf8) else { return false }
        let query = baseQuery(accountID: accountID, inviteID: inviteID)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess { return true }
        if status == errSecDuplicateItem {
            return SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            ) == errSecSuccess
        }
        return false
    }

    static func remove(accountID: String, inviteID: UUID) {
        SecItemDelete(baseQuery(accountID: accountID, inviteID: inviteID) as CFDictionary)
    }

    static func removeAll(accountID: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(accountID: accountID)
        ] as CFDictionary)
    }

    private static func service(accountID: String) -> String {
        servicePrefix + "." + accountID.lowercased()
    }

    private static func baseQuery(accountID: String, inviteID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(accountID: accountID),
            kSecAttrAccount as String: inviteID.uuidString.lowercased()
        ]
    }
}

/// A legacy-named Supabase Auth session used to give a device-only Grove an
/// unforgeable, guest-limited analysis identity. `ownerAccountID` is the
/// local/demo account this credential belongs to; `userID` is the anonymous
/// `auth.users` UUID the analysis Edge Function verifies for quota and retry
/// memory. Anonymous identities never authorize Botanist.
struct BotanistTokenSet: Codable, Equatable {
    var ownerAccountID: String
    var userID: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    var needsRefresh: Bool {
        Date.now >= expiresAt.addingTimeInterval(-60)
    }
}

enum BotanistSessionStore {
    private static let service = "nz.co.thinkingai.Grove.botanist-session"
    private static let account = "current"

    static func load() -> BotanistTokenSet? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(BotanistTokenSet.self, from: data)
    }

    static func save(_ tokens: BotanistTokenSet) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            _ = SecItemUpdate(
                baseQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        }
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// A Supabase Auth session created before Grove has an account to attach it to.
///
/// This credential is deliberately separate from both `SupabaseTokenSet` and
/// `BotanistTokenSet`: a pre-account scan must survive an authentication sheet
/// or app relaunch, but it must never be mistaken for the provider credential
/// that owns a synced Grove or for the anonymous identity attached to an
/// existing device-only Grove.
struct OnboardingGuestTokenSet: Codable, Equatable {
    var userID: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    var needsRefresh: Bool {
        Date.now >= expiresAt.addingTimeInterval(-60)
    }
}

enum OnboardingGuestSessionStore {
    private static let service = "nz.co.thinkingai.Grove.onboarding-guest-session"
    private static let account = "current"

    static func load() -> OnboardingGuestTokenSet? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(OnboardingGuestTokenSet.self, from: data)
    }

    static func save(_ tokens: OnboardingGuestTokenSet) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            _ = SecItemUpdate(
                baseQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        }
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
