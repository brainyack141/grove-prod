import SwiftUI

/// How much of its title an unselected tab keeps. See `GroveSwipeTabs`.
enum GroveSwipeTabTitles {
    /// Every title stays set, with colour and the rule carrying selection. For
    /// strips whose titles already fit side by side.
    case always
    /// Only the arriving tab spells its title out; the rest stand as their icon
    /// alone. The leaving title is clipped away from its leading edge rather
    /// than faded, so the word reads as crowded out by the one arriving instead
    /// of cross-dissolved with it. Reclaiming the width of the other titles is
    /// also what keeps the strip from overflowing at accessibility text sizes.
    /// An item with no icon keeps its title whatever the mode, since collapsing
    /// it would leave nothing to tap.
    case selectedOnly
}

/// A tab strip and the pages beneath it, both driven by one number: how far the
/// pages have been dragged.
///
/// The usual way to build this is two animations pointed at the same state — a
/// strip that animates on tap, and a paged container that slides on its own
/// clock. They agree only when the gesture is a clean flick, and disagree the
/// moment a drag is slow, interrupted or reversed; the eye catches that even
/// when it cannot name it. Here the horizontal scroll's live offset is the only
/// clock. `progress` is a fractional page index, and the rule's position and
/// width, each title's visible width and each title's colour are all functions
/// of it. Let go halfway and the strip sits halfway, because there is no
/// separate animation to finish.
///
/// This view owns the horizontal axis only. Each page brings its own vertical
/// scrolling, which is what lets a page keep its own scroll position while its
/// neighbours keep theirs.
struct GroveSwipeTabs<Item: Hashable, Content: View>: View {
    let items: [Item]
    let title: (Item) -> String
    var icon: (Item) -> String? = { _ in nil }
    @Binding var selection: Item
    var titles: GroveSwipeTabTitles = .always
    /// Inset for the strip alone. The pages run full width so a card's shadow
    /// is not shaved off at the page edge; their content carries its own
    /// padding, and this lines the strip up with it.
    var stripInset: CGFloat = GroveTheme.pagePadding
    @ViewBuilder let content: (Item) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Held in a reference type rather than `@State` on purpose. A drag moves
    /// this value every frame, and if the enclosing view read it, every frame
    /// would also rebuild the pages — the whole feed underneath, mid-swipe.
    /// Only the strip reads it, so only the strip redraws.
    @State private var drag = GroveSwipeTabsDrag()
    @State private var scrolledIndex: Int?

    var body: some View {
        VStack(spacing: 0) {
            GroveSwipeTabsStrip(
                items: items,
                title: title,
                icon: icon,
                titles: titles,
                selectedIndex: selectionIndex,
                drag: drag,
                select: select
            )
            .padding(.horizontal, stripInset)

            pages
        }
        .onAppear {
            let index = selectionIndex
            scrolledIndex = index
            drag.progress = Double(index)
            drag.lastCrossed = index
        }
        .onChange(of: scrolledIndex) { _, index in
            guard let index, items.indices.contains(index), items[index] != selection else { return }
            selection = items[index]
        }
        // Selection also arrives from outside — a deep link, a reset, a sibling
        // control — and the pages have to follow it.
        .onChange(of: selection) { _, item in
            guard let index = items.firstIndex(of: item), index != scrolledIndex else { return }
            select(index)
        }
    }

    private var pages: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { index in
                    content(items[index])
                        .containerRelativeFrame(.horizontal)
                        .id(index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrolledIndex)
        .scrollIndicators(.hidden)
        // Reading the scroll rather than tracking a gesture: this follows
        // deceleration, rubber-banding and a programmatic tap alike, none of
        // which a `DragGesture` sees.
        .onScrollGeometryChange(for: Double.self) { geometry in
            let width = geometry.containerSize.width
            guard width > 0 else { return 0 }
            return (geometry.contentOffset.x + geometry.contentInsets.leading) / width
        } action: { _, page in
            drag.progress = min(max(page, 0), Double(max(0, items.count - 1)))
            reportCrossing()
        }
    }

    private var selectionIndex: Int {
        items.firstIndex(of: selection) ?? 0
    }

    private func select(_ index: Int) {
        guard index != scrolledIndex else { return }
        // Driving the scroll rather than the strip: the strip is a function of
        // the scroll, so a tap and a drag arrive down the same path and cannot
        // look like two different transitions.
        if reduceMotion {
            scrolledIndex = index
        } else {
            withAnimation(GroveMotion.snap) { scrolledIndex = index }
        }
    }

    /// The tick lands as the halfway line is crossed — the moment selection
    /// actually changes hands, and the moment the finger is still there to feel
    /// it. On release it would arrive after the fact.
    private func reportCrossing() {
        let nearest = Int(drag.progress.rounded())
        guard nearest != drag.lastCrossed else { return }
        drag.lastCrossed = nearest
        Haptics.selection()
    }
}

/// The one number the strip is a function of.
@Observable
final class GroveSwipeTabsDrag {
    /// Fractional page index. 1.5 means the strip is exactly between the second
    /// and third tabs, with both titles half set.
    var progress: Double = 0
    /// Nothing draws from this, so it stays out of the observation graph.
    @ObservationIgnored var lastCrossed = 0
}

// MARK: - Strip

private struct GroveSwipeTabsStrip<Item: Hashable>: View {
    let items: [Item]
    let title: (Item) -> String
    let icon: (Item) -> String?
    let titles: GroveSwipeTabTitles
    let selectedIndex: Int
    let drag: GroveSwipeTabsDrag
    let select: (Int) -> Void

    @State private var titleWidths: [Int: CGFloat] = [:]
    @State private var rowWidth: CGFloat = 0

    /// One width for every symbol, so a wide glyph cannot push the row off its
    /// rhythm the way its optical width would if each icon sized itself.
    private let iconSlot: CGFloat = 24
    private let titleGap: CGFloat = 6
    private let minimumGap: CGFloat = 18
    private let ruleHeight: CGFloat = 3
    private let titleFont = Font.headline.weight(.bold)

    var body: some View {
        ScrollView(.horizontal) {
            VStack(spacing: 0) {
                HStack(spacing: gap) {
                    ForEach(items.indices, id: \.self) { index in
                        Button {
                            select(index)
                        } label: {
                            tab(index)
                        }
                        .buttonStyle(.plain)
                        .frame(width: slotWidth(index), alignment: .leading)
                        .accessibilityLabel(title(items[index]))
                        .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                rule
            }
            .frame(width: max(rowWidth, contentWidth), alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            rowWidth = width
        }
        .background(alignment: .topLeading) { measurement }
    }

    private func tab(_ index: Int) -> some View {
        let item = items[index]
        let symbol = icon(item)
        let reveal = revealed(index)
        return HStack(spacing: 0) {
            if let symbol {
                Image(systemName: symbol)
                    .font(titleFont)
                    .frame(width: iconSlot)
            }
            Text(title(item))
                .font(titleFont)
                // Trailing alignment inside a shrinking frame is what eats the
                // word from its leading edge. Anchored the other way it would
                // look like the letters were being deleted one by one.
                .fixedSize()
                .frame(width: titleWidth(index) * reveal, alignment: .trailing)
                .clipped()
                .padding(.leading, symbol == nil ? 0 : titleGap * reveal)
                // The word is decoration once the button carries the label; a
                // half-clipped title read aloud is noise.
                .accessibilityHidden(true)
        }
        // `mutedInk`, not `subtleInk`: an unselected tab is still a label
        // someone has to read to choose it.
        .foregroundStyle(GroveTheme.mutedInk.mix(with: GroveTheme.ink, by: reveal))
        .scaleEffect(1 + 0.02 * reveal, anchor: .bottomLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A title and a 3pt rule are barely 33pt tall, which leaves every
        // near-miss to whatever sits above or below the strip.
        .frame(minHeight: 44)
        .contentShape(.rect)
    }

    private var rule: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(GroveTheme.separator)
                .frame(height: 1)
            Capsule()
                .fill(GroveTheme.ink)
                .frame(width: indicator.width, height: ruleHeight)
                .offset(x: indicator.x)
        }
        .frame(height: ruleHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Every title laid out at full size and never drawn. The clip has to know
    /// how wide the word *would* be before it can decide how much of it to
    /// show, and asking the renderer is the only way to be right at every
    /// Dynamic Type size and in every locale.
    private var measurement: some View {
        VStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                Text(title(items[index]))
                    .font(titleFont)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.width
                    } action: { width in
                        titleWidths[index] = width
                    }
            }
        }
        .hidden()
    }

    // MARK: - Geometry

    /// How much of tab `index` is set, from 0 (icon alone) to 1 (icon and
    /// title). Two neighbours are each half set in the middle of a swipe, which
    /// is the whole effect.
    private func revealed(_ index: Int) -> Double {
        switch titles {
        case .always:
            return 1
        case .selectedOnly:
            guard icon(items[index]) != nil else { return 1 }
            return max(0, 1 - abs(drag.progress - Double(index)))
        }
    }

    private func titleWidth(_ index: Int) -> CGFloat {
        titleWidths[index] ?? 0
    }

    /// What the tab occupies right now, mid-morph.
    private func slotWidth(_ index: Int) -> CGFloat {
        let hasIcon = icon(items[index]) != nil
        let reveal = CGFloat(revealed(index))
        return (hasIcon ? iconSlot : 0) + ((hasIcon ? titleGap : 0) + titleWidth(index)) * reveal
    }

    /// What the tab occupies once it is fully set.
    private func expandedWidth(_ index: Int) -> CGFloat {
        let hasIcon = icon(items[index]) != nil
        return (hasIcon ? iconSlot + titleGap : 0) + titleWidth(index)
    }

    /// Free width shared out between the tabs. It shrinks as the arriving title
    /// unwraps, which is why the untouched icons drift as you swipe.
    private var gap: CGFloat {
        guard items.count > 1 else { return 0 }
        let occupied = items.indices.reduce(CGFloat.zero) { $0 + slotWidth($1) }
        return max(minimumGap, (rowWidth - occupied) / CGFloat(items.count - 1))
    }

    private var contentWidth: CGFloat {
        items.indices.reduce(CGFloat.zero) { $0 + slotWidth($1) } + gap * CGFloat(max(0, items.count - 1))
    }

    private func leadingEdge(_ index: Int) -> CGFloat {
        let before = (0..<index).reduce(CGFloat.zero) { $0 + slotWidth($1) }
        return before + gap * CGFloat(index)
    }

    private var indicator: (x: CGFloat, width: CGFloat) {
        guard items.count > 1 else { return (0, expandedWidth(0)) }
        let clamped = min(max(drag.progress, 0), Double(items.count - 1))
        let lower = Int(clamped.rounded(.down))
        let upper = min(lower + 1, items.count - 1)
        let fraction = CGFloat(clamped - Double(lower))
        let x = leadingEdge(lower) + (leadingEdge(upper) - leadingEdge(lower)) * fraction
        // Width interpolates between what the two tabs measure *set*, not what
        // they measure right now: mid-drag both are half collapsed, and a rule
        // sized to those would pinch in the middle of every swipe.
        let width = expandedWidth(lower) + (expandedWidth(upper) - expandedWidth(lower)) * fraction
        return (x, width)
    }
}

#Preview("Titles always") {
    @Previewable @State var selection = "All"
    let items = ["All", "Care", "Friends"]
    return GroveSwipeTabs(items: items, title: { $0 }, selection: $selection) { item in
        ScrollView {
            VStack(spacing: 12) {
                ForEach(0..<12, id: \.self) { index in
                    Text("\(item) \(index + 1)")
                        .frame(maxWidth: .infinity)
                        .groveCard()
                }
            }
            .padding(GroveTheme.pagePadding)
        }
    }
    .groveBackground()
}

#Preview("Titles on the selected tab") {
    @Previewable @State var selection = "Badges"
    let items = ["Badges", "Keepsakes", "Chapters"]
    let icons = ["Badges": "rosette", "Keepsakes": "sparkle", "Chapters": "book.closed.fill"]
    return GroveSwipeTabs(
        items: items,
        title: { $0 },
        icon: { icons[$0] },
        selection: $selection,
        titles: .selectedOnly
    ) { item in
        ScrollView {
            VStack(spacing: 12) {
                ForEach(0..<12, id: \.self) { index in
                    Text("\(item) \(index + 1)")
                        .frame(maxWidth: .infinity)
                        .groveCard()
                }
            }
            .padding(GroveTheme.pagePadding)
        }
    }
    .groveBackground()
}
