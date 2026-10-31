import ObjectiveC
import SwiftUI
import UIKit

/// The back swipe, for pages that draw their own chrome.
///
/// A page with a full-bleed hero hides the navigation bar and draws its own
/// back chip (`PlantDetailView` gives the reason). UIKit takes the edge swipe
/// away with the bar, so those pages could only be left by reaching up for the
/// chip, while every other page in the app goes back with a thumb.
///
/// This puts the swipe back for the pages that ask for it. It stands in for the
/// stack's own gesture delegate: on an opted-in page it decides whether the
/// swipe may begin, and for every other page, and every other question the
/// gesture asks, it defers to the delegate UIKit installed.
@MainActor
final class GroveBackSwipe: NSObject, UIGestureRecognizerDelegate {
    private weak var navigation: UINavigationController?
    /// Read from the forwarding overrides below, which UIKit only calls on the
    /// main thread but which have to be declared nonisolated to override.
    nonisolated(unsafe) private weak var system: (any UIGestureRecognizerDelegate)?
    /// Markers placed by `groveHidesNavigationBar()`, one per opted-in page.
    private let markers = NSHashTable<UIView>.weakObjects()

    private static var key: UInt8 = 0

    private init(navigation: UINavigationController, system: UIGestureRecognizerDelegate?) {
        self.navigation = navigation
        self.system = system
    }

    /// Opts the page that holds `marker` in to the back swipe: the edge swipe,
    /// and on iOS 26 the swipe from anywhere on the page that every other
    /// screen in the app gets, which hiding the bar takes away too.
    fileprivate static func register(_ marker: UIView, in navigation: UINavigationController) {
        var recognizers = [navigation.interactivePopGestureRecognizer]
        if #available(iOS 26.0, *) {
            recognizers.append(navigation.interactiveContentPopGestureRecognizer)
        }
        for case let pop? in recognizers {
            install(on: pop, in: navigation).markers.add(marker)
        }
    }

    private static func install(on pop: UIGestureRecognizer, in navigation: UINavigationController) -> GroveBackSwipe {
        if let installed = pop.delegate as? GroveBackSwipe { return installed }
        let proxy = GroveBackSwipe(navigation: navigation, system: pop.delegate)
        // SwiftUI can hand the recognizer a fresh delegate after we took it.
        // Carry the pages already opted in over to the replacement proxy.
        if let previous = objc_getAssociatedObject(pop, &key) as? GroveBackSwipe {
            for marker in previous.markers.allObjects { proxy.markers.add(marker) }
        }
        // The recognizer holds its delegate weakly, so it also keeps this one
        // alive for as long as it exists.
        objc_setAssociatedObject(pop, &key, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        pop.delegate = proxy
        return proxy
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let navigation else { return false }
        guard let top = navigation.topViewController?.viewIfLoaded,
              markers.allObjects.contains(where: { $0.isDescendant(of: top) })
        else {
            return system?.gestureRecognizerShouldBegin?(gestureRecognizer) ?? true
        }
        // A swipe that starts mid-push would leave the stack half animated.
        guard navigation.viewControllers.count > 1, navigation.transitionCoordinator == nil else { return false }
        // The edge swipe can only go one way. The page-wide one is a plain pan,
        // so it must be heading back and mostly sideways, or reading the page
        // would pop it.
        guard !(gestureRecognizer is UIScreenEdgePanGestureRecognizer),
              let pan = gestureRecognizer as? UIPanGestureRecognizer
        else { return true }
        let velocity = pan.velocity(in: navigation.view)
        let back = navigation.view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -velocity.x : velocity.x
        return back > 0 && back > abs(velocity.y)
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || system?.responds(to: aSelector) == true
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        system?.responds(to: aSelector) == true ? system : super.forwardingTarget(for: aSelector)
    }
}

/// An invisible view whose only job is to find the stack its page sits in.
private struct GroveBackSwipeMarker: UIViewRepresentable {
    func makeUIView(context: Context) -> MarkerView {
        let view = MarkerView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: MarkerView, context: Context) {}

    final class MarkerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var responder = next
            while let current = responder, !(current is UINavigationController) {
                responder = current.next
            }
            guard let navigation = responder as? UINavigationController else { return }
            GroveBackSwipe.register(self, in: navigation)
            // The push is still running here, and SwiftUI settles the bar's
            // visibility as it lands, which can replace the delegate just
            // installed. Claim it again once the page is on screen.
            let claim = { [weak self, weak navigation] in
                guard let self, let navigation, self.window != nil else { return }
                GroveBackSwipe.register(self, in: navigation)
            }
            if let coordinator = navigation.transitionCoordinator {
                coordinator.animate(alongsideTransition: nil) { _ in claim() }
            } else {
                DispatchQueue.main.async(execute: claim)
            }
        }
    }
}

extension View {
    /// Hides the navigation bar for a page that draws its own chrome, and
    /// keeps the swipe back (edge and, on iOS 26, page-wide) that hiding it
    /// would otherwise take away.
    func groveHidesNavigationBar() -> some View {
        toolbar(.hidden, for: .navigationBar)
            .background(GroveBackSwipeMarker().accessibilityHidden(true))
    }
}
