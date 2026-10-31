import Foundation
import GoogleSignIn
import UIKit

/// Presents Google Sign-In and returns the OpenID identity token that
/// `SupabaseAuthClient` exchanges for a Supabase session.
///
/// Google, unlike Apple, has no OS-native sign-in button, so obtaining the
/// identity token requires the GoogleSignIn SDK and a presenting view
/// controller. The SDK reads the iOS OAuth client id from the `GIDClientID`
/// Info.plist key (baked in from the `GOOGLE_IOS_CLIENT_ID` build setting).
@MainActor
enum GoogleAuthenticator {
    struct Credential {
        /// Google's stable subject id for this account.
        ///
        /// Retained for account-provider diagnostics and parity with Apple's
        /// credential. Optional because the SDK declares it so; Grove relies on
        /// the verified OpenID token—not this value—to establish the account.
        let userID: String?
        let idToken: String
        let displayName: String?
    }

    enum GoogleAuthError: LocalizedError {
        case notConfigured
        case noPresenter
        case noIdentityToken
        case cancelled
        case invalidCallbackConfiguration

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Google sign-in is not configured for this build."
            case .noPresenter: "Grove couldn't open the Google sign-in screen. Try again."
            case .noIdentityToken: "Google did not return a usable sign-in token."
            case .cancelled: "Sign-in was cancelled."
            case .invalidCallbackConfiguration: "Google sign-in's client ID and callback URL do not match."
            }
        }
    }

    /// True only when both the Google iOS client id and its exact reversed
    /// callback scheme are present in this build.
    static var isConfigured: Bool {
        guard let clientID else { return false }
        return registeredSchemes.contains(expectedReversedClientID(for: clientID))
    }

    private static var clientID: String? {
        configuredClientID
    }

    private static var configuredClientID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              !value.isEmpty,
              !value.contains("$(") else { return nil }
        return value
    }

    /// Presents the Google sign-in flow and returns the identity token.
    /// Throws `.cancelled` when the user backs out, so callers can no-op.
    static func signIn() async throws -> Credential {
        guard let clientID else { throw GoogleAuthError.notConfigured }
        guard registeredSchemes.contains(expectedReversedClientID(for: clientID)) else {
            throw GoogleAuthError.invalidCallbackConfiguration
        }
        guard let presenter = topViewController() else { throw GoogleAuthError.noPresenter }

        // The SDK auto-reads GIDClientID from Info.plist, but set the
        // configuration defensively so a fresh instance is never unconfigured.
        if GIDSignIn.sharedInstance.configuration == nil {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let idToken = result.user.idToken?.tokenString else {
                throw GoogleAuthError.noIdentityToken
            }
            return Credential(
                userID: result.user.userID,
                idToken: idToken,
                displayName: result.user.profile?.name
            )
        } catch let error as NSError
            where error.domain == kGIDSignInErrorDomain
            && error.code == GIDSignInError.canceled.rawValue {
            throw GoogleAuthError.cancelled
        }
    }

    /// Forwards a Google OAuth callback URL to the SDK. Wired from the app's
    /// `.onOpenURL`.
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    static func expectedReversedClientID(for clientID: String) -> String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    private static var registeredSchemes: Set<String> {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        return Set(schemes.filter { !$0.isEmpty && !$0.contains("$(") })
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController
            ?? scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
