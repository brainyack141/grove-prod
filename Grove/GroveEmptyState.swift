import SwiftUI

/// The one empty state in Grove.
///
/// It replaces `EmptyStateView`, which was a wrapper around Apple's
/// `ContentUnavailableView`, which is a stock component with a stock SF Symbol
/// in it. Three things are different here, and only the first is visual:
///
/// 1. **The art is ours.** `GroveEmptyArt` draws the app's own mark with the
///    missing thing inside it, instead of borrowing a glyph.
/// 2. **The voice is the page's voice.** Serif display title over a muted line
///    of body copy — the same typesetting as every heading in the app, where
///    `ContentUnavailableView` used its own system-styled title and ignored
///    Grove's type scale entirely.
/// 3. **It isn't a dead end.** The `actions` builder is the point: an empty
///    screen should hand you the thing that fills it. A "no plants yet" state
///    with no way to add a plant is a sign, not a screen.
struct GroveEmptyState<Actions: View>: View {
    let scene: GroveEmptyScene
    /// The first-plant states show Sprout's windowsill from first run, so the
    /// grove a person lands in still looks like the one they set up.
    var customArt: AnyView? = nil
    let title: String
    let message: String
    /// Shrink for tight contexts — a list row, a small inset card. The geometry
    /// is vector, so it stays sharp all the way down.
    var artSize: CGFloat = 132
    @ViewBuilder var actions: Actions

    /// `actions` still occupies the stack when a caller supplies nothing, so
    /// without this every action-less state carried 20 pt of dead space under
    /// its last line of copy — enough to sit visibly off-centre in a card.
    private var hasActions: Bool { Actions.self != EmptyView.self }

    var body: some View {
        VStack(spacing: 0) {
            if let customArt {
                customArt
            } else {
                GroveEmptyArt(scene: scene, size: artSize)
            }

            GroveDisplayHeading(text: title, style: .section)
                .multilineTextAlignment(.center)
                .padding(.top, 16)

            Text(message)
                .font(.subheadline)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(GroveTheme.mutedInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                // Empty-state copy is read, not scanned. Measure holds it to a
                // comfortable line length instead of letting it run the full
                // width of an iPad or a landscape phone.
                .frame(maxWidth: 320)
                .padding(.top, 6)

            actions
                .padding(.top, hasActions ? 20 : 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
    }
}

extension GroveEmptyState where Actions == EmptyView {
    /// The stateless case: nothing here, and nothing the user can do about it
    /// from this screen. Rarer than it looks — reach for the `actions` form
    /// first and only fall back to this when there is genuinely no next step.
    init(scene: GroveEmptyScene, title: String, message: String, artSize: CGFloat = 132) {
        self.init(scene: scene, title: title, message: message, artSize: artSize) { EmptyView() }
    }
}

#Preview("With an action") {
    GroveEmptyState(
        scene: .firstPlant,
        title: "Add your first plant",
        message: "Scan a plant to identify it, check its health, and set up its care."
    ) {
        Button {} label: { GroveScanCTALabel() }
            .buttonStyle(GroveScanCTAStyle())
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .groveBackground()
}

#Preview("Without") {
    GroveEmptyState(
        scene: .stillAir,
        title: "Nothing new",
        message: "When a friend cares for your plants or answers a question, it shows up here."
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .groveBackground()
}
