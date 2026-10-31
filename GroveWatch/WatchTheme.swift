import SwiftUI

/// Grove's palette, translated to the wrist.
///
/// The watch draws on the OS's true-black canvas — on an always-on OLED that
/// is the honest ground, not a styling choice — so every value here is the
/// *dark-appearance* half of the corresponding `GroveTheme` token, verbatim.
/// One meaning keeps one hue across pocket and wrist: the streak flame on the
/// watch is the same orange as the streak flame on the phone.
///
/// Type stays SF. DESIGN.md keeps native controls in native contexts, and the
/// whole watch app is one: Fraunces is the phone's editorial voice, not a
/// glanceable one.
enum WatchTheme {
    private static func fixed(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    // Ink — GroveTheme's dark-canvas text family.
    static let ink = fixed(0xF4F2EC)
    static let mutedInk = fixed(0xA6A296)
    static let subtleInk = fixed(0x726E63)

    // Life and action.
    static let accent = fixed(0x76B47B)
    static let accentStrong = fixed(0x95CA98)

    // Signals — same meanings, same hues as the phone.
    static let warning = fixed(0xE0A94C)
    static let danger = fixed(0xE8695A)
    static let streak = fixed(0xF08A2E)
    static let hydration = fixed(0x6FA8E0)
    static let sitting = fixed(0xB49BEE)

    static var actionGradient: LinearGradient {
        LinearGradient(
            colors: [accentStrong, accent],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // Health bands, dark variants.
    static let healthThriving = fixed(0x3CD79A)
    static let healthHealthy = fixed(0x96BC68)
    static let healthAttention = fixed(0xE0873D)
}

/// The wrist-sized counterpart to Grove's primary action capsule.
struct WatchPrimaryButtonLabel: View {
    let title: String
    var systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(WatchTheme.actionGradient, in: Capsule())
            .contentShape(Capsule())
    }
}

struct WatchPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension WatchHealthBand {
    /// Mirrors `HealthBand.color` in `DesignSystem.swift`: monitor borrows
    /// caution amber, urgent borrows danger — the bands and the signals may
    /// never disagree between devices.
    var color: Color {
        switch self {
        case .thriving: WatchTheme.healthThriving
        case .healthy: WatchTheme.healthHealthy
        case .monitor: WatchTheme.warning
        case .attention: WatchTheme.healthAttention
        case .urgent: WatchTheme.danger
        }
    }
}

extension WatchHealthTrend {
    /// Mirrors `HealthTrend.color`.
    var color: Color {
        switch self {
        case .improving: WatchTheme.accent
        case .stable, .baseline: WatchTheme.mutedInk
        case .declining: WatchTheme.warning
        }
    }
}

extension WatchCareKind {
    /// Restrained on purpose: act-here green for every care act, except the
    /// two kinds that already own a signal hue everywhere else in Grove —
    /// water is hydration blue, treatment is caution amber.
    var tint: Color {
        switch self {
        case .water: WatchTheme.hydration
        case .treat: WatchTheme.warning
        default: WatchTheme.accent
        }
    }
}
