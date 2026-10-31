import SwiftUI

/// Grove's authored empty-state illustration system.
///
/// Every scene shares an open live ring, with a bespoke painted centrepiece
/// describing what is missing. The ring is deliberately unfinished except for
/// `allClear`, where a closed circle means nothing remains to do.
enum GroveEmptyScene: CaseIterable {
    case firstPlant
    case groveScore
    case restingCan
    case noMatches
    case emptyShelf
    case company
    case stillAir
    case activityAll
    case activityCare
    case activityFriends
    case vanished
    case viewfinder
    case allClear
    case severed
    case noPhoto
}

extension GroveEmptyScene {
    var artworkName: String {
        switch self {
        case .firstPlant: "FirstPlantBespoke"
        case .groveScore: "GroveScoreFirstPlant"
        case .restingCan: "EmptyRestingCan"
        case .noMatches: "EmptyNoMatches"
        case .emptyShelf: "EmptyShelf"
        case .company: "EmptyCompany"
        case .stillAir: "ActivityStillAir"
        case .activityAll: "ActivityAll"
        case .activityCare: "ActivityCare"
        case .activityFriends: "ActivityFriends"
        case .vanished: "EmptyVanished"
        case .viewfinder: "EmptyViewfinder"
        case .allClear: "EmptyAllClear"
        case .severed: "EmptySevered"
        case .noPhoto: "NoPhotoBespoke"
        }
    }

    var artworkFrameFraction: CGFloat {
        switch self {
        case .firstPlant: 0.76
        case .groveScore: 0.80
        case .stillAir, .activityAll, .activityCare, .activityFriends: 0.92
        case .noPhoto: 0.64
        default: 0.94
        }
    }

    /// Only "nothing is wrong" earns a finished circle.
    var ringIsClosed: Bool { self == .allClear }

    /// A dashed ring says the record itself has become provisional.
    var ringIsDashed: Bool { self == .vanished }

    /// Where the brand seed rests along the ring's gap. The planted and
    /// completed scenes do not need one.
    var seedRadius: CGFloat? {
        switch self {
        case .firstPlant, .allClear: nil
        case .noMatches: 52
        default: 41
        }
    }
}

struct GroveEmptyArt: View {
    let scene: GroveEmptyScene
    var size: CGFloat = 132
    /// Lets static renderers skip the entrance animation.
    var staticFrame: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var settled: Bool { appeared || staticFrame }
    private var scale: CGFloat { size / 100 }

    var body: some View {
        ZStack {
            ring
            seed
            subject
        }
        .frame(width: size, height: size)
        .onAppear { appeared = true }
        .accessibilityHidden(true)
    }

    private var ring: some View {
        GroveEmptyRing(closed: scene.ringIsClosed)
            .trim(from: 0, to: settled ? 1 : 0)
            .stroke(
                GroveTheme.accent.opacity(scene.ringIsClosed ? 0.38 : 0.28),
                style: StrokeStyle(
                    lineWidth: 3.2 * scale,
                    lineCap: .round,
                    dash: scene.ringIsDashed ? [7 * scale, 6 * scale] : []
                )
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.75), value: settled)
    }

    @ViewBuilder
    private var seed: some View {
        if let radius = scene.seedRadius {
            let bearing = GroveEmptyRing.gapBearing
            Circle()
                .fill(GroveTheme.accent.opacity(0.5))
                .frame(width: 6.2 * scale, height: 6.2 * scale)
                .offset(
                    x: radius * cos(bearing) * scale,
                    y: radius * sin(bearing) * scale
                )
                .opacity(settled ? 1 : 0)
                .animation(reduceMotion ? nil : GroveMotion.pop.delay(0.45), value: settled)
        }
    }

    private var subject: some View {
        Image(scene.artworkName)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(
                width: size * scene.artworkFrameFraction,
                height: size * scene.artworkFrameFraction
            )
            .opacity(settled ? 1 : 0)
            .scaleEffect(settled ? 1 : 0.9, anchor: .bottom)
            .animation(reduceMotion ? nil : GroveMotion.reveal.delay(0.1), value: settled)
    }
}

/// The animated brand frame remains code-native because its open/closed,
/// dashed, and draw-on states are semantic and live.
struct GroveEmptyRing: Shape {
    var closed: Bool

    static let centre = CGPoint(x: 50, y: 50)
    static let radius: CGFloat = 41
    static let start: CGFloat = -25
    static let sweep: CGFloat = 320
    static let gapBearing: CGFloat = -45 * .pi / 180

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 100
        return Path { path in
            path.addArc(
                center: CGPoint(x: Self.centre.x * s, y: Self.centre.y * s),
                radius: Self.radius * s,
                startAngle: .degrees(Self.start),
                endAngle: .degrees(closed ? Self.start + 360 : Self.start + Self.sweep),
                clockwise: false
            )
        }
    }
}

#Preview("Every scene") {
    ScrollView {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 24) {
            ForEach(Array(GroveEmptyScene.allCases.enumerated()), id: \.offset) { _, scene in
                GroveEmptyArt(scene: scene, size: 100)
            }
        }
        .padding(24)
    }
    .background(GroveTheme.background)
}
