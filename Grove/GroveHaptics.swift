import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Grove's haptic voice.
///
/// Haptics used to be three functions that existed for the Journey's
/// celebrations, with the rest of the app spelling feedback inline —
/// `UIImpactFeedbackGenerator(style: .medium).impactOccurred()` at the call
/// site, a fresh generator every time. That has two costs. The first is
/// physical: the Taptic Engine needs warming, so a generator that is created
/// and fired in the same instant produces a late or dropped tap. The second is
/// editorial: the same kind of moment spoke with a different voice on every
/// screen, and most moments said nothing at all.
///
/// This is the whole vocabulary, named for *what happened* rather than for a
/// waveform. Screens ask for `Haptics.complete()`, not for a rigid impact at
/// 0.8, so the feel of "something finished" can be tuned in one place and every
/// screen moves with it.
///
/// Three rules hold the vocabulary together:
///
/// - **Generators are pooled and pre-armed.** One selection generator, one
///   notification generator, one impact generator per style, all kept warm.
/// - **Celebrations are rhythms, not buzzes.** The moments that matter play a
///   short sequence with rising intensity. A single thud reads as a
///   notification; a rise reads as an event.
/// - **The user can switch it off.** Everything routes through `isEnabled`,
///   mirrored into the same defaults key the settings toggle writes.
@MainActor
enum Haptics {

    // MARK: - Preference

    /// The defaults key behind the "Haptics" switch in settings. Sourced from
    /// `GroveDefaults` so the engine, the toggle and the delete path can never
    /// drift apart — a key only this type knew about was one the "delete
    /// everything on this iPhone" promise could not reach.
    static let preferenceKey = GroveDefaults.hapticsEnabled

    /// Cached so the hot path (a tap during a scroll) never touches
    /// `UserDefaults`.
    private static var cachedPreference: Bool?

    /// Whether Grove speaks through the Taptic Engine at all. Defaults to on.
    static var isEnabled: Bool {
        get {
            if let cachedPreference { return cachedPreference }
            let stored = UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true
            cachedPreference = stored
            return stored
        }
        set {
            cachedPreference = newValue
            UserDefaults.standard.set(newValue, forKey: preferenceKey)
        }
    }

    /// Re-reads the preference after something other than this type wrote it —
    /// the settings toggle binds through `@AppStorage`, which does not go
    /// through the setter above.
    static func refreshPreference() {
        cachedPreference = nil
    }

    // MARK: - Warming

    /// Arms the engine ahead of a moment that is about to need it: the frame a
    /// pressable surface receives touch-down, the moment an analysis starts,
    /// the appearance of a screen that ends in a celebration. Cheap, idempotent,
    /// and the difference between a tap that lands with the pixel and one that
    /// trails it.
    static func prepare() {
        guard isEnabled else { return }
        #if canImport(UIKit)
        Pool.shared.selection.prepare()
        Pool.shared.notification.prepare()
        Pool.shared.impact(.light).prepare()
        #endif
    }

    // MARK: - Primitives

    /// Moving between discrete options: a tab, a filter, a segment, a picker
    /// row, a step in a flow.
    static func selection() {
        guard isEnabled else { return }
        #if canImport(UIKit)
        let generator = Pool.shared.selection
        generator.selectionChanged()
        generator.prepare()
        #endif
    }

    /// The lightest acknowledgement: a chip, a disclosure, a minor tap.
    static func tap() {
        impact(.light, intensity: 0.7)
    }

    /// Touch-*down* on a pressable card or tile. Deliberately the faintest
    /// thing in the vocabulary — it is felt under a fingertip that is still
    /// moving, so anything stronger reads as a click the user did not make.
    static func press() {
        impact(.soft, intensity: 0.45)
    }

    /// A committing tap: the button that saves, sends, or moves you on.
    static func commit() {
        impact(.medium, intensity: 0.85)
    }

    /// A switch, checkbox, or any binary state landing. On is firmer than off,
    /// which is how physical switches feel.
    static func toggle(on: Bool) {
        impact(on ? .rigid : .soft, intensity: on ? 0.8 : 0.55)
    }

    /// Content arriving — a result revealed, a sheet settling, a page landing.
    static func arrive() {
        impact(.soft, intensity: 0.6)
    }

    /// The camera shutter. Short and hard, like a mechanism closing.
    static func shutter() {
        impact(.rigid, intensity: 1.0)
    }

    /// A boundary: the end of a carousel, a limit reached, a refused gesture.
    static func bump() {
        impact(.rigid, intensity: 0.5)
    }

    /// Raw access, for the rare case the vocabulary has no word yet.
    static func impact(_ style: GroveImpact, intensity: CGFloat = 1.0) {
        guard isEnabled else { return }
        #if canImport(UIKit)
        let generator = Pool.shared.impact(style)
        generator.impactOccurred(intensity: max(0, min(1, intensity)))
        generator.prepare()
        #endif
    }

    // MARK: - Outcomes

    /// Something worked. Reserve it for outcomes the user was waiting on —
    /// a save that completed, an analysis that returned.
    static func success() {
        guard isEnabled else { return }
        #if canImport(UIKit)
        Pool.shared.notification.notificationOccurred(.success)
        Pool.shared.notification.prepare()
        #endif
    }

    /// Something needs attention but nothing was lost.
    static func warning() {
        guard isEnabled else { return }
        #if canImport(UIKit)
        Pool.shared.notification.notificationOccurred(.warning)
        Pool.shared.notification.prepare()
        #endif
    }

    /// Something failed. Never fire this for validation the user has not
    /// submitted yet — it reads as an accusation.
    static func error() {
        guard isEnabled else { return }
        #if canImport(UIKit)
        Pool.shared.notification.notificationOccurred(.error)
        Pool.shared.notification.prepare()
        #endif
    }

    // MARK: - Rhythms

    /// A task ticked off. The satisfying part of a checkbox is not the buzz,
    /// it is the two-part *tick-thunk*: a light contact, then the weight
    /// settling. Two beats, 60 ms apart.
    static func complete() {
        play([
            Beat(delay: 0, style: .light, intensity: 0.6),
            Beat(delay: 0.06, style: .rigid, intensity: 0.9)
        ])
    }

    /// The check-in landed, the milestone unlocked, the plant was added: a
    /// rising three-beat that resolves into the success notification. This is
    /// the app's signature celebration and should stay rare enough to keep
    /// meaning something.
    static func celebrate() {
        play([
            Beat(delay: 0, style: .soft, intensity: 0.5),
            Beat(delay: 0.09, style: .medium, intensity: 0.75),
            Beat(delay: 0.18, style: .heavy, intensity: 1.0)
        ], then: .success, after: 0.30)
    }

    /// A medallion spinning into the hand. The beats are timed to the edge-on
    /// crossings of ``JourneyBadgeReveal``'s two turns, so the coin is felt
    /// passing rather than heard as a generic fanfare, and it resolves into
    /// success as the badge lands flat. Change one and the other has to move.
    static func medallionLanding() {
        play([
            Beat(delay: 0.10, style: .light, intensity: 0.4),
            Beat(delay: 0.30, style: .light, intensity: 0.6),
            Beat(delay: 0.55, style: .medium, intensity: 0.8),
            Beat(delay: 0.80, style: .rigid, intensity: 1.0)
        ], then: .success, after: 0.98)
    }

    /// The same coin turned over by hand. No resolution: nothing was earned by
    /// tapping it, so nothing announces itself.
    static func medallionSpin() {
        play([
            Beat(delay: 0, style: .soft, intensity: 0.4),
            Beat(delay: 0.30, style: .light, intensity: 0.5),
            Beat(delay: 0.55, style: .light, intensity: 0.65),
            Beat(delay: 0.80, style: .soft, intensity: 0.45)
        ])
    }

    /// A rank or level opening up: heavier and slower than `celebrate`, so the
    /// two are distinguishable with the phone in a pocket.
    static func levelUp() {
        play([
            Beat(delay: 0, style: .medium, intensity: 0.6),
            Beat(delay: 0.12, style: .heavy, intensity: 0.85),
            Beat(delay: 0.26, style: .heavy, intensity: 1.0)
        ], then: .success, after: 0.42)
    }

    /// The streak advancing. A quick double-tick, like a flame catching.
    static func streak() {
        play([
            Beat(delay: 0, style: .light, intensity: 0.7),
            Beat(delay: 0.07, style: .medium, intensity: 0.9)
        ])
    }

    /// A score or count rolling upward, felt as texture under the numerals.
    /// `steps` is clamped so a large jump does not turn into a massage.
    static func climb(steps: Int) {
        let count = max(1, min(6, steps))
        let beats = (0..<count).map { index in
            Beat(
                delay: Double(index) * 0.055,
                style: .soft,
                intensity: 0.35 + (CGFloat(index) / CGFloat(max(1, count - 1))) * 0.4
            )
        }
        play(beats)
    }

    // MARK: - Sequencer

    /// One tap in a rhythm.
    private struct Beat {
        let delay: Double
        let style: GroveImpact
        let intensity: CGFloat
    }

    /// What a rhythm resolves into, if anything.
    private enum Resolution {
        case success
        case warning
    }

    /// Plays a rhythm on the main actor. Beats are scheduled from a single
    /// task, so a view that disappears mid-celebration simply stops feeling
    /// the rest of it rather than leaving timers behind.
    private static func play(_ beats: [Beat], then resolution: Resolution? = nil, after resolutionDelay: Double = 0) {
        guard isEnabled, !beats.isEmpty else { return }
        prepare()
        Task { @MainActor in
            var elapsed: Double = 0
            for beat in beats {
                let wait = beat.delay - elapsed
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    elapsed = beat.delay
                }
                impact(beat.style, intensity: beat.intensity)
            }
            guard let resolution else { return }
            let wait = resolutionDelay - elapsed
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            switch resolution {
            case .success: success()
            case .warning: warning()
            }
        }
    }
}

// MARK: - Styles

/// Grove's own impact styles, so callers never import UIKit just to name a
/// weight and the vocabulary stays available to non-UIKit builds.
enum GroveImpact: Int, Sendable {
    case light
    case medium
    case heavy
    case soft
    case rigid
}

#if canImport(UIKit)
private extension GroveImpact {
    var uiStyle: UIImpactFeedbackGenerator.FeedbackStyle {
        switch self {
        case .light: .light
        case .medium: .medium
        case .heavy: .heavy
        case .soft: .soft
        case .rigid: .rigid
        }
    }
}

/// Keeps one generator per kind alive and warm for the life of the process.
/// Generators are cheap to hold and expensive to cold-start, which is exactly
/// backwards from how they were being used.
@MainActor
private final class Pool {
    static let shared = Pool()

    let selection = UISelectionFeedbackGenerator()
    let notification = UINotificationFeedbackGenerator()

    /// Keyed by raw value rather than by the imported enum so the cache does
    /// not depend on how UIKit's style type bridges.
    private var impacts: [Int: UIImpactFeedbackGenerator] = [:]

    func impact(_ style: GroveImpact) -> UIImpactFeedbackGenerator {
        if let existing = impacts[style.rawValue] { return existing }
        let generator = UIImpactFeedbackGenerator(style: style.uiStyle)
        generator.prepare()
        impacts[style.rawValue] = generator
        return generator
    }
}
#endif

// MARK: - SwiftUI plumbing

/// Fires a haptic when a value changes.
///
/// SwiftUI's own `sensoryFeedback` would be the obvious tool, but it cannot see
/// Grove's on/off preference and it has no vocabulary for the rhythms above.
/// This modifier keeps both.
private struct HapticOnChange<Value: Equatable>: ViewModifier {
    let value: Value
    /// Explicitly `@MainActor`: the closure is stored rather than passed
    /// straight through, so it does not inherit the isolation of the view body
    /// that formed it, and every rhythm it could call is main-actor bound.
    let feedback: @MainActor (Value) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: value) { _, newValue in
            feedback(newValue)
        }
    }
}

extension View {
    /// Plays `feedback` whenever `value` changes. The closure receives the new
    /// value so a single call site can pick its rhythm — firmer for a state
    /// that turned on than one that turned off, say.
    func groveHaptic<Value: Equatable>(
        _ value: Value,
        perform feedback: @MainActor @escaping (Value) -> Void
    ) -> some View {
        modifier(HapticOnChange(value: value, feedback: feedback))
    }

    /// Arms the Taptic Engine while this view is on screen, so the first tap
    /// on it lands with the pixel instead of trailing it.
    func grovePreparesHaptics() -> some View {
        onAppear { Haptics.prepare() }
    }
}
