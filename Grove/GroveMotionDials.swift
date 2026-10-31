#if GROVE_DIALS
import Combine
import DialKit
import SwiftUI
import UIKit
import os

/// Live tuning for `GroveMotion`, on the phone, in a real Release build.
///
/// Only compiled when `GROVE_DIALS=1 scripts/prod-phone.sh` sets the flag.
/// Shake the phone on any screen to open the drawer: one spring dial per
/// motion token. A change applies to the next animation that reads the token,
/// so swipe the drawer away and trigger the moment you are tuning. Tuned values
/// survive a relaunch; "Copy as Swift" puts a ready-to-paste
/// `GroveMotion.Token.shipped` switch on the clipboard.
@MainActor
final class GroveMotionDials {
    static let shared = GroveMotionDials()

    /// Read from `GroveMotion.animation(_:)`, which any thread may call, so the
    /// overrides sit behind a lock rather than on the main actor. A token only
    /// appears here once it differs from what ships.
    private nonisolated static let overrides = OSAllocatedUnfairLock<[GroveMotion.Token: TunedSpring]>(
        initialState: GroveMotionDialValues.saved.map(\.overrides) ?? [:]
    )

    nonisolated static func tuned(_ token: GroveMotion.Token) -> Animation? {
        overrides.withLock { $0[token] }?.animation
    }

    private let panel: DialPanelState<GroveMotionDialValues>
    private let presentation = Presentation()
    private var window: UIWindow?
    private var subscriptions: Set<AnyCancellable> = []

    private init() {
        let shipped = GroveMotionDialValues.shipped
        // Set after init because the action closure needs `self`.
        var resetAction: () -> Void = {}
        var copyAction: () -> Void = {}
        panel = DialPanelState(
            name: "GroveMotion",
            initial: GroveMotionDialValues.saved ?? shipped,
            controls: GroveMotion.Token.allCases.map { .spring($0.rawValue, keyPath: GroveMotionDialValues.keyPath($0)) }
                + [.action("copySwift", label: "Copy as Swift"), .action("reset", label: "Reset to shipped")],
            onAction: { path in
                switch path {
                case "reset": resetAction()
                case "copySwift": copyAction()
                default: break
                }
            }
        )
        resetAction = { [weak self] in self?.panel.values = shipped }
        copyAction = { [weak self] in
            guard let self else { return }
            UIPasteboard.general.string = panel.values.swiftSource
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }

        panel.$values
            .dropFirst()
            .sink { values in
                Self.overrides.withLock { $0 = values.overrides }
                values.save()
            }
            .store(in: &subscriptions)

        presentation.$isPresented
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in
                // Let the drawer finish sliding away before the window goes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard let self, !self.presentation.isPresented else { return }
                    self.window?.isHidden = true
                    self.window = nil
                }
            }
            .store(in: &subscriptions)
    }

    /// The drawer gets its own window above everything, sheets and full-screen
    /// covers included, and only exists while it is open, so it never sits
    /// between a finger and the app.
    func toggle(in scene: UIWindowScene?) {
        if presentation.isPresented {
            presentation.isPresented = false
            return
        }
        guard let scene = scene ?? UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }

        presentation.isPresented = true
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        // A fresh host per opening: DialKit's README warns a reused one can
        // carry stale drawer state across open/close cycles.
        let host = UIHostingController(rootView: DrawerHost(presentation: presentation))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        self.window = window
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private final class Presentation: ObservableObject {
        @Published var isPresented = false
    }

    private struct DrawerHost: View {
        @ObservedObject var presentation: Presentation

        var body: some View {
            DialRoot(position: .bottomRight, storageID: "grove-motion", isPresented: $presentation.isPresented)
        }
    }
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        guard motion == .motionShake else { return }
        GroveMotionDials.shared.toggle(in: windowScene)
    }
}

/// One spring per `GroveMotion.Token`, in DialKit's duration/bounce terms.
/// SwiftUI treats `spring(duration: d, bounce: b)` and
/// `spring(response: d, dampingFraction: 1 - b)` as the same spring, so the
/// conversion is exact in both directions.
///
/// `@unchecked Sendable` only because DialKit does not mark `DialSpring`
/// Sendable; it is an enum of Doubles, so there is no shared state to guard.
private struct GroveMotionDialValues: Codable, Equatable, @unchecked Sendable {
    var press, snap, settle, reveal, celebrate, drift, pop: DialSpring

    static let shipped: GroveMotionDialValues = {
        func dial(_ token: GroveMotion.Token) -> DialSpring {
            let spring = token.shipped
            return .time(duration: spring.response, bounce: ((1 - spring.dampingFraction) * 100).rounded() / 100)
        }
        return GroveMotionDialValues(
            press: dial(.press), snap: dial(.snap), settle: dial(.settle), reveal: dial(.reveal),
            celebrate: dial(.celebrate), drift: dial(.drift), pop: dial(.pop)
        )
    }()

    static func keyPath(_ token: GroveMotion.Token) -> WritableKeyPath<Self, DialSpring> {
        switch token {
        case .press: \.press
        case .snap: \.snap
        case .settle: \.settle
        case .reveal: \.reveal
        case .celebrate: \.celebrate
        case .drift: \.drift
        case .pop: \.pop
        }
    }

    var overrides: [GroveMotion.Token: TunedSpring] {
        var result: [GroveMotion.Token: TunedSpring] = [:]
        for token in GroveMotion.Token.allCases {
            let spring = self[keyPath: Self.keyPath(token)]
            guard spring != Self.shipped[keyPath: Self.keyPath(token)] else { continue }
            result[token] = TunedSpring(spring)
        }
        return result
    }

    var swiftSource: String {
        let cases = GroveMotion.Token.allCases.map { token -> String in
            switch self[keyPath: Self.keyPath(token)] {
            case let .time(duration, bounce):
                return "case .\(token.rawValue): (\(Self.format(duration)), \(Self.format(1 - bounce)))"
            case let .physics(stiffness, damping, mass):
                return "case .\(token.rawValue): // physics: stiffness \(Self.format(stiffness)), damping \(Self.format(damping)), mass \(Self.format(mass))"
            }
        }
        return """
        // GroveMotion.Token.shipped — (response, dampingFraction)
        \(cases.joined(separator: "\n"))
        """
    }

    private static func format(_ value: Double) -> String {
        String(format: "%g", (value * 1000).rounded() / 1000)
    }

    private static let defaultsKey = "grove.motionDials.values"

    static var saved: GroveMotionDialValues? {
        UserDefaults.standard.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode(GroveMotionDialValues.self, from: $0) }
    }

    func save() {
        if self == Self.shipped {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// A Sendable copy of `DialSpring`, which DialKit does not mark Sendable.
private enum TunedSpring: Sendable {
    case time(duration: Double, bounce: Double)
    case physics(stiffness: Double, damping: Double, mass: Double)

    init(_ spring: DialSpring) {
        switch spring {
        case let .time(duration, bounce): self = .time(duration: duration, bounce: bounce)
        case let .physics(stiffness, damping, mass): self = .physics(stiffness: stiffness, damping: damping, mass: mass)
        }
    }

    var animation: Animation {
        switch self {
        case let .time(duration, bounce): .spring(duration: duration, bounce: bounce)
        case let .physics(stiffness, damping, mass): .interpolatingSpring(mass: mass, stiffness: stiffness, damping: damping)
        }
    }
}
#endif
