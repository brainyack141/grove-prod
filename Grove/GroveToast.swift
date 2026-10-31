import SwiftUI

/// A brief confirmation that dismisses itself, carrying at most one action.
///
/// Grove's quick actions — ticking a care task off a list, logging watering from
/// a long-press menu — are single taps with no confirmation dialog in front of
/// them, because asking "are you sure?" before every routine act is the thing
/// that makes a care app tiring. That trade is only fair if the tap is
/// reversible, so the safety net moves *after* the action: do the thing
/// immediately, say what happened, and offer the way back for a few seconds.
struct GroveToast: Identifiable {
    let id = UUID()
    var message: String
    var symbol: String = "checkmark.circle.fill"
    /// Title of the single trailing action, e.g. "Undo". Omit for a pure
    /// confirmation.
    var actionTitle: String?
    var action: (() -> Void)?
}

extension GroveToast: Equatable {
    /// Identity is the only thing the view layer needs to compare — the payload
    /// carries a closure and never changes in place.
    static func == (lhs: GroveToast, rhs: GroveToast) -> Bool { lhs.id == rhs.id }
}

/// Holds the one toast on screen. A second toast replaces the first rather than
/// queuing: the newest action is the one the user is looking at, and a backlog
/// of stale undo offers would be worse than none.
@MainActor
@Observable
final class GroveToastCenter {
    private(set) var current: GroveToast?

    func show(_ toast: GroveToast) {
        current = toast
    }

    /// The common shape: a confirmation with an optional way back.
    func show(
        _ message: String,
        symbol: String = "checkmark.circle.fill",
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        show(GroveToast(message: message, symbol: symbol, actionTitle: actionTitle, action: action))
    }

    func dismiss() {
        current = nil
    }
}

// MARK: - Presentation

/// How long an undo stays on offer. Long enough to notice and reach, short
/// enough that it is gone before it becomes furniture.
private let groveToastDuration: Duration = .seconds(4.5)

private struct GroveToastView: View {
    @Environment(GroveToastCenter.self) private var toasts: GroveToastCenter?
    let toast: GroveToast

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.symbol)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(GroveTheme.onCanvasButtonLabel)
                .accessibilityHidden(true)

            Text(toast.message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GroveTheme.onCanvasButtonLabel)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if let actionTitle = toast.actionTitle, let action = toast.action {
                Button {
                    Haptics.tap()
                    action()
                    toasts?.dismiss()
                } label: {
                    Text(actionTitle)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(GroveTheme.onCanvasButtonLabel)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(GroveTheme.onCanvasButtonLabel.opacity(0.16), in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(GrovePressStyle())
                .accessibilityLabel("\(actionTitle). \(toast.message)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            GroveTheme.onCanvasButton,
            in: RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
        )
        .groveShadow(.floating)
        .accessibilityElement(children: .contain)
    }
}

private struct GroveToastLayer: ViewModifier {
    @Environment(GroveToastCenter.self) private var toasts: GroveToastCenter?
    /// How far above the bottom of the host the toast sits. The tab bar floats
    /// over the pages rather than ending them, so at a tab root the shell passes
    /// the bar's reserved height — otherwise the undo button lands underneath
    /// the glass, which is exactly the reach this layer exists to protect.
    let bottomInset: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toasts, let toast = toasts.current {
                    GroveToastView(toast: toast)
                        .padding(.horizontal, GroveTheme.pagePadding)
                        .padding(.bottom, bottomInset)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        // Keyed on the toast, so replacing one restarts the
                        // clock instead of inheriting the old one's remaining
                        // time.
                        .task(id: toast.id) {
                            try? await Task.sleep(for: groveToastDuration)
                            guard !Task.isCancelled else { return }
                            withAnimation(GroveMotion.settle) { toasts.dismiss() }
                        }
                }
            }
            .groveAnimation(GroveMotion.settle, value: toasts?.current)
    }
}

extension View {
    /// Hosts the app's toast layer. Applied once, at the app shell, so a toast
    /// raised from any screen lands in the same place and outlives the row,
    /// sheet or menu that raised it.
    func groveToastLayer(bottomInset: CGFloat = 10) -> some View {
        modifier(GroveToastLayer(bottomInset: bottomInset))
    }
}
