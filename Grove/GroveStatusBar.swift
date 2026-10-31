import ObjectiveC
import SwiftUI
import UIKit

/// Who decides whether the status bar is light or dark.
///
/// Grove runs in the light appearance (`RootView` pins it), so the system
/// draws a dark status bar everywhere, including over the night-green and
/// photographic heroes every tab now opens on, where dark text on a dark
/// ground is unreadable. `toolbarColorScheme` cannot override a pinned
/// appearance, so this asks the window's root view controller directly.
///
/// Screens *claim* a style while they are on screen and release it when they
/// leave. The most recent claim wins; with no claims the bar is dark, which is
/// right for every paper page.
@MainActor
enum GroveStatusBar {
    private static var claims: [(id: UUID, style: UIStatusBarStyle)] = []

    static var current: UIStatusBarStyle { claims.last?.style ?? .darkContent }

    static func claim(_ id: UUID, _ style: UIStatusBarStyle) {
        if let index = claims.firstIndex(where: { $0.id == id }) {
            guard claims[index].style != style else { return }
            claims[index].style = style
        } else {
            claims.append((id, style))
        }
        refresh()
    }

    static func release(_ id: UUID) {
        let before = claims.count
        claims.removeAll { $0.id == id }
        if claims.count != before { refresh() }
    }

    private static func refresh() {
        for scene in UIApplication.shared.connectedScenes {
            guard let scene = scene as? UIWindowScene else { continue }
            for window in scene.windows {
                guard let root = window.rootViewController else { continue }
                adopt(root)
                root.setNeedsStatusBarAppearanceUpdate()
            }
        }
    }

    /// Gives the root controller a runtime subclass whose status bar style is
    /// `current` and which stops deferring to its children for it: the same
    /// technique key-value observing uses, applied once per class.
    private static func adopt(_ controller: UIViewController) {
        guard let base = object_getClass(controller) else { return }
        let baseName = NSStringFromClass(base)
        guard !baseName.hasPrefix("GroveStatusBar_") else { return }

        let name = "GroveStatusBar_\(baseName)"
        var subclass: AnyClass? = NSClassFromString(name)
        if subclass == nil, let created = objc_allocateClassPair(base, name, 0) {
            let style: @convention(block) (AnyObject) -> Int = { _ in
                MainActor.assumeIsolated { GroveStatusBar.current.rawValue }
            }
            class_addMethod(
                created,
                #selector(getter: UIViewController.preferredStatusBarStyle),
                imp_implementationWithBlock(style),
                "q@:"
            )
            let noChild: @convention(block) (AnyObject) -> AnyObject? = { _ in nil }
            class_addMethod(
                created,
                #selector(getter: UIViewController.childForStatusBarStyle),
                imp_implementationWithBlock(noChild),
                "@@:"
            )
            objc_registerClassPair(created)
            subclass = created
        }
        if let subclass { object_setClass(controller, subclass) }
    }
}

private struct GroveStatusBarClaim: ViewModifier {
    let style: UIStatusBarStyle
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { GroveStatusBar.claim(id, style) }
            .onChange(of: style) { _, newStyle in GroveStatusBar.claim(id, newStyle) }
            .onDisappear { GroveStatusBar.release(id) }
    }
}

extension View {
    /// Holds the status bar at `style` while this view is on screen.
    func groveStatusBar(_ style: UIStatusBarStyle) -> some View {
        modifier(GroveStatusBarClaim(style: style))
    }
}
