import Foundation

/// The one home for Grove's legal destinations.
///
/// Onboarding's "by continuing you agree…" footer links these destinations
/// from one home, so replacing a placeholder updates both.
/// App Review requires the privacy policy to be reachable from inside the app,
/// which onboarding provides before the person creates an account.
enum GroveLegal {
    /// Apple's standard EULA. UI copy names it exactly; it must never be
    /// presented as Grove-authored terms of service.
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    /// Grove's own policy on the public Grove site.
    ///
    /// Hard-coded rather than read from the configured base URL: App Review
    /// opens this from the App Store listing too, where no build setting
    /// applies, and the two must be the same page. The page is public, so it
    /// needs no key.
    static let privacyURL = URL(string: "https://www.downloadgrove.com/privacy")!

    /// The support mailbox used by Grove's support workflows and App Store
    /// listing.
    ///
    /// This must be a mailbox that actually receives before submission — App
    /// Review follows in-app support links, and the same address belongs in the
    /// App Store listing's support field. The privacy policy publishes
    /// `privacy@thinkingai.co.nz` separately (see the `legal` Edge Function);
    /// keeping support distinct means a bug report never lands in a queue meant
    /// for data requests.
    static let supportEmail = "support@thinkingai.co.nz"
}

/// Legal links moved to `GroveLegal` once Settings started showing them too;
/// the alias keeps onboarding's call sites reading naturally.
typealias OnboardingLegal = GroveLegal
