import SwiftUI

/// Whether the person has agreed to Grove sending their photos to a
/// third-party AI, and the version of that agreement they gave.
///
/// App Review 5.1.2(i) requires the disclosure and the permission to happen
/// before any photo leaves the phone. The version means a stricter disclosure
/// can ask once more without a new defaults key; the same key is catalogued in
/// `GroveDefaults`, so "Delete everything on this iPhone" clears it too.
enum AIProcessingConsent {
    static let currentVersion = 2

    static func isGranted(in defaults: UserDefaults = .standard) -> Bool {
#if DEBUG
        // Physical-device UI tests cannot complete a new sheet in every flow.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(where: { $0.hasPrefix("-GroveUITest") }) {
            return true
        }
#endif
        return defaults.integer(forKey: GroveDefaults.photoProcessingDisclosureVersion) >= currentVersion
    }

    static func grant(in defaults: UserDefaults = .standard) {
        defaults.set(currentVersion, forKey: GroveDefaults.photoProcessingDisclosureVersion)
    }
}

/// What a person is told before a photo is sent to Google's Gemini AI.
///
/// The wording is drawn from the hosted policy's Gemini section: the same
/// photos, scan answers and Ask messages travel through Grove's server, and
/// the photo is neither kept there nor used for training.
struct AIProcessingConsentView: View {
    @Environment(\.dismiss) private var dismiss
    let onAgree: () -> Void
    let onDecline: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                GroveDisplayHeading(text: "Before Grove reads your photo", style: .title)

                Text("Grove sends the photos you choose, plus your scan answers, to Google's Gemini AI through Grove's server, to identify the plant and read its health. Ari's answers in Ask are written the same way. Photos are not kept on Grove's server and are not used to train anyone's models.")
                    .font(.body)
                    .foregroundStyle(GroveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Link("Read the privacy policy", destination: GroveLegal.privacyURL)
                    .font(.subheadline.weight(.semibold))
                    .tint(GroveTheme.accentStrong)

                VStack(spacing: 8) {
                    Button(action: agree) {
                        GroveCTALabel(title: "Agree and continue")
                    }
                    .buttonStyle(GrovePressStyle())
                    .accessibilityIdentifier("aiConsentAgree")

                    Button("Not now", action: decline)
                        .font(.subheadline.weight(.semibold))
                        .tint(GroveTheme.mutedInk)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("aiConsentDecline")
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .groveBackground()
        .interactiveDismissDisabled()
    }

    private func agree() {
        AIProcessingConsent.grant()
        onAgree()
        dismiss()
    }

    private func decline() {
        onDecline()
        dismiss()
    }
}
