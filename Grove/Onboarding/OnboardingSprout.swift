import SwiftUI

// MARK: - Palette

/// The illustration palette for first run: the windowsill, the six rooms, the
/// sky over home, and the tinted room tags. Governed here, like `JourneyWorld`
/// for the map, so no drawing mints colours inline.
///
/// Fixed in both appearances: onboarding renders in the light appearance (see
/// `OnboardingContainerView`), and the outline is Sprout's own artwork ink.
enum SproutWorld {
    /// The dark green Sprout's artwork is outlined in. Every drawn shape uses
    /// it, so the scenery and the character read as one hand.
    static let outline = Color(red: 0.184, green: 0.353, blue: 0.165)        // #2F5A2A
    static let skyTop = Color(red: 0.749, green: 0.878, blue: 0.933)         // #BFE0EE
    static let skyBottom = Color(red: 0.918, green: 0.961, blue: 0.941)      // #EAF5F0
    static let sun = Color(red: 0.965, green: 0.788, blue: 0.271)            // #F6C945
    static let moon = Color(red: 0.965, green: 0.906, blue: 0.690)           // #F6E7B0
    static let white = Color.white
    static let leafLight = Color(red: 0.490, green: 0.733, blue: 0.306)      // #7DBB4E
    static let leaf = Color(red: 0.435, green: 0.682, blue: 0.271)           // #6FAE45
    static let leafDeep = Color(red: 0.361, green: 0.604, blue: 0.216)       // #5C9A37
    static let terracotta = Color(red: 0.851, green: 0.510, blue: 0.357)     // #D9825B
    static let terracottaRim = Color(red: 0.906, green: 0.604, blue: 0.447)  // #E79A72
    static let ceramic = Color(red: 0.902, green: 0.882, blue: 0.827)        // #E6E1D3
    static let ceramicRim = Color(red: 0.945, green: 0.929, blue: 0.886)     // #F1EDE2
    static let wood = Color(red: 0.788, green: 0.627, blue: 0.435)           // #C9A06F
    static let sill = Color(red: 0.922, green: 0.827, blue: 0.682)           // #EBD3AE

    // Rooms: a wall, a floor, and one signature colour each.
    static let livingWall = Color(red: 0.965, green: 0.922, blue: 0.867)     // #F6EBDD
    static let bedroomWall = Color(red: 0.910, green: 0.922, blue: 0.973)    // #E8EBF8
    static let bedroomFloor = Color(red: 0.863, green: 0.839, blue: 0.918)   // #DCD6EA
    static let bedLinen = Color(red: 0.714, green: 0.757, blue: 0.933)       // #B6C1EE
    static let bedFrame = Color(red: 0.549, green: 0.608, blue: 0.839)       // #8C9BD6
    static let nightGlass = Color(red: 0.227, green: 0.290, blue: 0.478)     // #3A4A7A
    static let kitchenWall = Color(red: 0.984, green: 0.945, blue: 0.839)    // #FBF1D6
    static let kitchenTile = Color(red: 0.937, green: 0.867, blue: 0.682)    // #EFDDAE
    static let kettle = Color(red: 0.561, green: 0.725, blue: 0.659)         // #8FB9A8
    static let bathWall = Color(red: 0.890, green: 0.949, blue: 0.969)       // #E3F2F7
    static let bathTile = Color(red: 0.749, green: 0.863, blue: 0.902)       // #BFDCE6
    static let bathFloor = Color(red: 0.831, green: 0.906, blue: 0.933)      // #D4E7EE
    static let steam = Color(red: 0.616, green: 0.780, blue: 0.839)          // #9DC7D6
    static let frosted = Color(red: 0.949, green: 0.969, blue: 0.976)        // #F2F7F9
    static let officeWall = Color(red: 0.941, green: 0.910, blue: 0.969)     // #F0E8F7
    static let officeFloor = Color(red: 0.851, green: 0.812, blue: 0.902)    // #D9CFE6
    static let screen = Color(red: 0.180, green: 0.227, blue: 0.306)         // #2E3A4E
    static let book = Color(red: 0.502, green: 0.345, blue: 0.682)           // #8058AE
    static let grass = Color(red: 0.612, green: 0.796, blue: 0.420)          // #9CCB6B
    static let flower = Color(red: 0.937, green: 0.553, blue: 0.592)         // #EF8D97

    /// The accent word in a title set over the sky, where the leaf green would
    /// sink into the blues.
    static let skyAccent = Color(red: 0.965, green: 0.816, blue: 0.541)      // #F6D08A
    static let onSky = Color(red: 0.957, green: 0.949, blue: 0.925)          // #F4F2EC

    /// Room tags and tiles: a pale wash with a deeper glyph, one family per
    /// room so a list of six reads at a glance. Glyph on wash is above 3:1.
    static func roomTint(_ room: OnboardingRoom) -> (wash: Color, glyph: Color) {
        switch room {
        case .livingRoom: (Color(red: 0.984, green: 0.890, blue: 0.831), Color(red: 0.753, green: 0.392, blue: 0.235))
        case .bedroom: (Color(red: 0.886, green: 0.902, blue: 0.980), Color(red: 0.329, green: 0.388, blue: 0.722))
        case .kitchen: (Color(red: 0.988, green: 0.937, blue: 0.780), Color(red: 0.580, green: 0.420, blue: 0.035))
        case .bathroom: (Color(red: 0.851, green: 0.933, blue: 0.969), Color(red: 0.200, green: 0.471, blue: 0.592))
        case .office: (Color(red: 0.929, green: 0.890, blue: 0.965), Color(red: 0.502, green: 0.345, blue: 0.682))
        case .garden: (Color(red: 0.882, green: 0.945, blue: 0.839), Color(red: 0.306, green: 0.541, blue: 0.173))
        }
    }

    /// The sky over the grove at a given hour, top to bottom. Every stop is
    /// dark enough to carry light type: this sky is a page, not a picture.
    static func sky(hour: Int) -> (colors: [Color], isNight: Bool) {
        switch hour {
        case 5..<8:
            ([Color(red: 0.239, green: 0.310, blue: 0.486), Color(red: 0.545, green: 0.420, blue: 0.557), Color(red: 0.851, green: 0.557, blue: 0.459)], false)
        case 8..<17:
            ([Color(red: 0.122, green: 0.302, blue: 0.494), Color(red: 0.153, green: 0.353, blue: 0.553), Color(red: 0.180, green: 0.392, blue: 0.588)], false)
        case 17..<20:
            ([Color(red: 0.180, green: 0.243, blue: 0.420), Color(red: 0.420, green: 0.353, blue: 0.557), Color(red: 0.788, green: 0.533, blue: 0.431)], false)
        default:
            ([Color(red: 0.059, green: 0.102, blue: 0.200), Color(red: 0.122, green: 0.180, blue: 0.318), Color(red: 0.192, green: 0.255, blue: 0.408)], true)
        }
    }
}

// MARK: - Sprout

/// The three poses drawn in Sprout's bright style. The olive, sketchier Journey
/// poses are a different hand and stay out of first run. Sprout is a character
/// in the pictures, never a voice: Grove narrates (VOICE.md).
enum SproutPose: String {
    case idle = "JourneySproutIdle"
    case happy = "JourneySproutHappy"
    case cheer = "JourneySproutCheer"
}

struct SproutImage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let pose: SproutPose
    var size: CGFloat
    /// A small rise when Sprout first appears, the one bounce in first run.
    var entrance: Bool = true
    @State private var isShown = false

    var body: some View {
        Image(pose.rawValue)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .scaleEffect(isShown || reduceMotion || !entrance ? 1 : 0.86, anchor: .bottom)
            .opacity(isShown || reduceMotion || !entrance ? 1 : 0)
            .onAppear {
                guard entrance, !reduceMotion else { isShown = true; return }
                withAnimation(GroveMotion.pop.delay(0.08)) { isShown = true }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Question title

/// Every first-run question in one form: a large left-aligned title with the
/// one word that matters set in the accent, and a plain line under it.
struct OnboardingQuestionTitle: View {
    let lead: String
    let accent: String
    var trail: String = ""
    var subtitle: String?
    var onSky: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            (Text(lead) + Text(accent).foregroundStyle(onSky ? SproutWorld.skyAccent : GroveTheme.accent) + Text(trail))
                .font(GroveTheme.display(30, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(onSky ? SproutWorld.onSky : GroveTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(onSky ? SproutWorld.onSky.opacity(0.82) : GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Step bar

/// How far through first run the person is, in Speechify's form: a plain back
/// chevron and a short centred row of thin segments, one per question.
enum OnboardingFlowProgress {
    /// Plant, room, home, account, name.
    static let total = 5
}

struct OnboardingSegmentBar: View {
    /// Nil on screens outside the counted questions (returning sign-in, the
    /// no-plant path): the back chevron alone.
    let step: Int?
    var total: Int = OnboardingFlowProgress.total
    var isBackEnabled: Bool = true
    var onSky: Bool = false
    var onBack: (() -> Void)?
    var trailing: (title: String, action: () -> Void)?

    var body: some View {
        ZStack {
            if let step {
                HStack(spacing: 6) {
                    ForEach(0..<total, id: \.self) { index in
                        Capsule()
                            .fill(segmentColor(filled: index < step))
                            .frame(width: 34, height: 5)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(step) of \(total)")
            }

            HStack {
                if let onBack {
                    Button {
                        Haptics.tap()
                        onBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(onSky ? SproutWorld.onSky : GroveTheme.ink)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(!isBackEnabled)
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("onboardingBack")
                }
                Spacer()
                if let trailing {
                    Button(trailing.title, action: trailing.action)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(onSky ? SproutWorld.onSky.opacity(0.8) : GroveTheme.mutedInk)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
    }

    private func segmentColor(filled: Bool) -> Color {
        if onSky { return filled ? SproutWorld.onSky : SproutWorld.onSky.opacity(0.25) }
        return filled ? GroveTheme.accent : GroveTheme.secondarySurface
    }
}

// MARK: - Raised surfaces

/// The pressable plate first run is built from: a 2pt rim with a deeper lip
/// along the bottom, so a choice looks like something you can push. Pressing
/// sinks the plate onto its lip.
struct RaisedPlate<Content: View>: View {
    var isSelected: Bool = false
    var isPressed: Bool = false
    var radius: CGFloat = GroveTheme.insetRadius
    var selectedRim: Color = GroveTheme.accent
    var selectedFill: Color = GroveTheme.softAccent
    @ViewBuilder let content: () -> Content

    private let lip: CGFloat = 3

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let rim = isSelected ? selectedRim : GroveTheme.separator
        content()
            .background { shape.fill(isSelected ? selectedFill : GroveTheme.surface) }
            .overlay { shape.strokeBorder(rim, lineWidth: 2) }
            .offset(y: isPressed ? lip : 0)
            .background {
                shape.fill(rim).offset(y: lip)
            }
            .padding(.bottom, lip)
    }
}

/// A button style that hands its pressed state to a `RaisedPlate`.
struct RaisedPlateButtonStyle: ButtonStyle {
    var isSelected: Bool = false
    var radius: CGFloat = GroveTheme.insetRadius
    var selectedRim: Color = GroveTheme.accent
    var selectedFill: Color = GroveTheme.softAccent

    func makeBody(configuration: Configuration) -> some View {
        RaisedPlate(
            isSelected: isSelected,
            isPressed: configuration.isPressed,
            radius: radius,
            selectedRim: selectedRim,
            selectedFill: selectedFill
        ) {
            configuration.label
        }
        .animation(GroveMotion.press, value: configuration.isPressed)
    }
}

// MARK: - Page

/// One first-run question on the canvas: the step bar, a scrolling body, and
/// the committing action docked at the foot. Scrolls on a 4.7" screen and at
/// accessibility sizes rather than clipping.
struct OnboardingSproutPage<Content: View, Footer: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var step: Int?
    var isBackEnabled: Bool = true
    var onBack: (() -> Void)?
    var trailing: (title: String, action: () -> Void)?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            if step != nil || onBack != nil {
                OnboardingSegmentBar(step: step, isBackEnabled: isBackEnabled, onBack: onBack, trailing: trailing)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                        .padding(.horizontal, GroveTheme.pagePadding + 4)
                        .padding(.top, 14)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if dynamicTypeSize.isAccessibilitySize {
                        footer()
                            .padding(.horizontal, GroveTheme.pagePadding + 4)
                            .padding(.top, 12)
                            .padding(.bottom, 8)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !dynamicTypeSize.isAccessibilitySize {
                footer()
                    .padding(.horizontal, GroveTheme.pagePadding + 4)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .background(GroveTheme.background)
            }
        }
        .background(GroveTheme.background.ignoresSafeArea())
    }
}

/// The quiet tertiary action under the primary capsule.
struct OnboardingQuietButton: View {
    let title: String
    var color: Color = GroveTheme.mutedInk
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: 44)
    }
}

/// Small caps over a value, inside a raised plate.
struct OnboardingFactTile: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let label: String
    let value: String
    var valueColor: Color = GroveTheme.ink

    var body: some View {
        RaisedPlate {
            VStack(alignment: .leading, spacing: 4) {
                GroveEyebrow(text: label)
                Text(value)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(valueColor)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The plant card

/// The object first run builds. It appears with the scan and gains a tag with
/// every answer, so each question visibly adds something to the plant.
struct OnboardingPlantCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let plant: OnboardingFirstPlantPresentation?
    var detail: String?
    var room: OnboardingRoom?
    var home: String?

    var body: some View {
        RaisedPlate(radius: GroveTheme.cardRadius - 4) {
            HStack(alignment: .center, spacing: 12) {
                Color.clear
                    .frame(width: 52, height: 52)
                    .overlay {
                        if let image = plant?.image {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            PlantArtwork(symbol: "leaf.fill", palette: .fern, height: 52)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(plant?.displayName.capitalizedFirst ?? "Your plant")
                            .font(.headline)
                            .foregroundStyle(GroveTheme.ink)
                        if let line = detail ?? plant?.cardLine {
                            Text(line)
                                .font(.footnote)
                                .foregroundStyle(GroveTheme.mutedInk)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if room != nil || home != nil {
                        GroveFlowLayout(spacing: 6) {
                            if let room {
                                let tint = SproutWorld.roomTint(room)
                                OnboardingTag(symbol: room.symbol, title: room.title, wash: tint.wash, glyph: tint.glyph)
                                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                            }
                            if let home {
                                OnboardingTag(symbol: "house.fill", title: home, wash: GroveTheme.softAccent, glyph: GroveTheme.accentStrong)
                                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
        }
        .animation(GroveMotion.pop, value: room)
        .animation(GroveMotion.pop, value: home)
        .accessibilityElement(children: .combine)
    }
}

struct OnboardingTag: View {
    let symbol: String
    let title: String
    let wash: Color
    let glyph: Color

    var body: some View {
        Label {
            Text(title).lineLimit(1)
        } icon: {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(glyph)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(wash, in: RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
    }
}

extension OnboardingFirstPlantPresentation {
    /// The card's second line: the scientific name and how sure the scan was.
    var cardLine: String? {
        var parts: [String] = []
        if showsScientificName { parts.append(scientificName) }
        if !isUnknownIdentity, !identificationIsProvisional, let identificationConfidence {
            parts.append("\(identificationConfidence)% ID match")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

fileprivate extension String {
    /// "your plant" opens a sentence but heads a card.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

// MARK: - Drawing

private let sceneLine = StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)

private extension GraphicsContext {
    mutating func outlined(_ path: Path, _ fill: Color) {
        self.fill(path, with: .color(fill))
        stroke(path, with: .color(SproutWorld.outline), style: sceneLine)
    }

    mutating func line(_ points: [CGPoint], width: CGFloat = 3, color: Color = SproutWorld.outline) {
        var path = Path()
        path.addLines(points)
        stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}

private func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
    Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r, style: .continuous)
}

private func pot(x: CGFloat, top: CGFloat, width: CGFloat, bottom: CGFloat) -> Path {
    var path = Path()
    path.addLines([
        CGPoint(x: x, y: top),
        CGPoint(x: x + width, y: top),
        CGPoint(x: x + width - width * 0.1, y: bottom),
        CGPoint(x: x + width * 0.1, y: bottom)
    ])
    path.closeSubpath()
    return path
}

private func cloud(at origin: CGPoint, scale s: CGFloat) -> Path {
    let puffs = [
        CGRect(x: 0, y: 18 * s, width: 34 * s, height: 26 * s),
        CGRect(x: 18 * s, y: 0, width: 40 * s, height: 40 * s),
        CGRect(x: 46 * s, y: 12 * s, width: 34 * s, height: 30 * s),
        CGRect(x: 12 * s, y: 24 * s, width: 60 * s, height: 20 * s)
    ].map { $0.offsetBy(dx: origin.x, dy: origin.y) }
    var merged = Path(ellipseIn: puffs[0])
    for puff in puffs.dropFirst() {
        merged = merged.union(Path(roundedRect: puff, cornerRadius: min(puff.width, puff.height) / 2))
    }
    return merged
}

/// Sprout potted inside a scene: the art behind, Sprout, then the pot's front
/// over Sprout's base so it stands in the soil rather than floating on it.
private struct PottedScene: View {
    let design: CGSize
    let sprout: CGRect
    let pose: SproutPose
    let back: (inout GraphicsContext) -> Void
    let front: (inout GraphicsContext) -> Void

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / design.width
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    context.scaleBy(x: scale, y: scale)
                    back(&context)
                }
                SproutImage(pose: pose, size: sprout.width * scale)
                    .offset(x: sprout.minX * scale, y: sprout.minY * scale)
                Canvas { context, _ in
                    context.scaleBy(x: scale, y: scale)
                    front(&context)
                }
            }
        }
        .aspectRatio(design, contentMode: .fit)
    }
}

// MARK: - The windowsill

/// The welcome scene: Sprout potted on a sunny windowsill between two
/// houseplants. Drawn in the artwork's own outline so the character and its
/// world are one illustration, and free of asset weight.
struct WindowsillScene: View {
    static let designSize = CGSize(width: 390, height: 470)

    var body: some View {
        PottedScene(
            design: Self.designSize,
            sprout: CGRect(x: 110, y: 214, width: 170, height: 170),
            pose: .happy,
            back: Self.drawBack,
            front: { context in
                context.outlined(pot(x: 140, top: 372, width: 110, bottom: 436), SproutWorld.terracotta)
                context.outlined(rounded(132, 360, 126, 18, 6), SproutWorld.terracottaRim)
            }
        )
        .accessibilityElement()
        .accessibilityLabel("Sprout, Grove's seedling, in a pot on a sunny windowsill")
    }

    private static func drawBack(_ context: inout GraphicsContext) {
        var window = Path()
        window.move(to: CGPoint(x: 40, y: 430))
        window.addLine(to: CGPoint(x: 40, y: 230))
        window.addArc(center: CGPoint(x: 195, y: 230), radius: 155, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        window.addLine(to: CGPoint(x: 350, y: 430))
        window.closeSubpath()
        context.fill(window, with: .linearGradient(
            Gradient(colors: [SproutWorld.skyTop, SproutWorld.skyBottom]),
            startPoint: CGPoint(x: 195, y: 75),
            endPoint: CGPoint(x: 195, y: 430)
        ))
        context.outlined(Path(ellipseIn: CGRect(x: 246, y: 138, width: 60, height: 60)), SproutWorld.sun)
        context.outlined(cloud(at: CGPoint(x: 80, y: 168), scale: 1), SproutWorld.white)
        context.outlined(cloud(at: CGPoint(x: 258, y: 250), scale: 0.7), SproutWorld.white)

        var rays = Path()
        rays.addLines([CGPoint(x: 60, y: 330), CGPoint(x: 150, y: 240), CGPoint(x: 178, y: 240), CGPoint(x: 88, y: 330)])
        rays.closeSubpath()
        rays.addLines([CGPoint(x: 70, y: 384), CGPoint(x: 170, y: 284), CGPoint(x: 186, y: 284), CGPoint(x: 86, y: 384)])
        rays.closeSubpath()
        context.fill(rays, with: .color(.white.opacity(0.35)))

        context.line([CGPoint(x: 195, y: 76), CGPoint(x: 195, y: 430)], width: 8, color: SproutWorld.white)
        context.line([CGPoint(x: 40, y: 268), CGPoint(x: 350, y: 268)], width: 8, color: SproutWorld.white)
        context.stroke(window, with: .color(SproutWorld.outline), style: sceneLine)

        context.outlined(snakeLeaf(base: 58, 70, tip: CGPoint(x: 56, y: 310)), SproutWorld.leafLight)
        context.outlined(snakeLeaf(base: 68, 82, tip: CGPoint(x: 76, y: 266)), SproutWorld.leaf)
        context.outlined(snakeLeaf(base: 82, 96, tip: CGPoint(x: 104, y: 286)), SproutWorld.leafDeep)
        context.outlined(pot(x: 50, top: 398, width: 62, bottom: 436), SproutWorld.terracotta)
        context.outlined(rounded(46, 392, 70, 12, 4), SproutWorld.terracottaRim)

        context.outlined(roundLeaf(from: CGPoint(x: 300, y: 394), to: CGPoint(x: 312, y: 360), bulge: 14), SproutWorld.leafLight)
        context.outlined(roundLeaf(from: CGPoint(x: 318, y: 392), to: CGPoint(x: 346, y: 366), bulge: 12), SproutWorld.leaf)
        context.outlined(pot(x: 284, top: 398, width: 62, bottom: 436), SproutWorld.ceramic)
        context.outlined(rounded(280, 392, 70, 12, 4), SproutWorld.ceramicRim)

        context.outlined(rounded(16, 434, 358, 22, 8), SproutWorld.sill)
    }

    static func snakeLeaf(base left: CGFloat, _ right: CGFloat, tip: CGPoint) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: left, y: 404))
        path.addCurve(to: tip, control1: CGPoint(x: left - 6, y: 350), control2: CGPoint(x: tip.x - 6, y: tip.y + 40))
        path.addCurve(to: CGPoint(x: right, y: 404), control1: CGPoint(x: tip.x + 8, y: tip.y + 44), control2: CGPoint(x: right + 4, y: 350))
        path.closeSubpath()
        return path
    }

    static func roundLeaf(from start: CGPoint, to end: CGPoint, bulge: CGFloat) -> Path {
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: CGPoint(x: start.x - bulge, y: start.y - bulge), control2: CGPoint(x: end.x - bulge, y: end.y + 2))
        path.addCurve(to: start, control1: CGPoint(x: end.x + bulge, y: end.y + bulge * 0.4), control2: CGPoint(x: start.x + bulge, y: start.y - 4))
        path.closeSubpath()
        return path
    }
}

// MARK: - Rooms

/// The rooms first run offers. Titles match the room names the rest of Grove
/// already files plants under (`EditPlantView`), so the plant lands in the
/// same room on Today's map that it was given here.
enum OnboardingRoom: String, CaseIterable, Identifiable {
    case livingRoom = "Living room"
    case bedroom = "Bedroom"
    case kitchen = "Kitchen"
    case bathroom = "Bathroom"
    case office = "Office"
    case garden = "Garden"

    var id: String { rawValue }
    var title: String { rawValue }

    var symbol: String {
        switch self {
        case .livingRoom: "sofa.fill"
        case .bedroom: "bed.double.fill"
        case .kitchen: "fork.knife"
        case .bathroom: "bathtub.fill"
        case .office: "desktopcomputer"
        case .garden: "sun.max.fill"
        }
    }
}

extension OnboardingRoom {
    /// The standard room a free-text room name belongs to, if any. "Lounge"
    /// reads as the living room and "Balcony" as outdoors, so rooms named
    /// before the six existed still get their colour.
    init?(matching name: String) {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, key != "unassigned", key != "elsewhere" else { return nil }
        if let exact = OnboardingRoom.allCases.first(where: { $0.title.lowercased() == key }) {
            self = exact
            return
        }
        let table: [(OnboardingRoom, [String])] = [
            (.livingRoom, ["living", "lounge", "sitting", "front room", "family room"]),
            (.bedroom, ["bed", "nursery"]),
            (.kitchen, ["kitchen", "dining"]),
            (.bathroom, ["bath", "shower", "toilet", "loo", "washroom"]),
            (.office, ["office", "study", "desk", "work"]),
            (.garden, ["garden", "balcony", "patio", "porch", "yard", "terrace", "outside", "outdoor", "deck", "greenhouse"])
        ]
        guard let match = table.first(where: { $0.1.contains { key.contains($0) } }) else { return nil }
        self = match.0
    }
}

/// How any room name is drawn: its glyph and colour family. One of the six
/// standard rooms gets its own; anything else is a neutral house.
struct GroveRoomTheme {
    let room: OnboardingRoom?
    let symbol: String
    let wash: Color
    let glyph: Color

    init(name: String) {
        room = OnboardingRoom(matching: name)
        if let room {
            let tint = SproutWorld.roomTint(room)
            symbol = room.symbol
            wash = tint.wash
            glyph = tint.glyph
        } else {
            symbol = "house.fill"
            wash = GroveTheme.secondarySurface
            glyph = GroveTheme.mutedInk
        }
    }
}

/// The room's glyph in its tinted circle: the mark a room carries wherever it
/// is named, from the room question in first run to My Grove's sections.
struct GroveRoomBadge: View {
    let name: String
    var size: CGFloat = 28

    var body: some View {
        let theme = GroveRoomTheme(name: name)
        Image(systemName: theme.symbol)
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(theme.glyph)
            .frame(width: size, height: size)
            .background(theme.wash, in: Circle())
            .accessibilityHidden(true)
    }
}

/// A room as a choice: badge and name on a raised capsule that takes the
/// room's colour when chosen. The same chip wherever a plant is given a room.
struct GroveRoomChip: View {
    let title: String
    var symbolOverride: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let theme = GroveRoomTheme(name: title)
        Button {
            Haptics.selection()
            withAnimation(GroveMotion.snap) { action() }
        } label: {
            HStack(spacing: 8) {
                if let symbolOverride {
                    Image(systemName: symbolOverride)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(GroveTheme.mutedInk)
                        .frame(width: 28, height: 28)
                        .background(GroveTheme.secondarySurface, in: Circle())
                } else {
                    GroveRoomBadge(name: title)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? theme.glyph : GroveTheme.ink)
                    .lineLimit(1)
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(RaisedPlateButtonStyle(
            isSelected: isSelected,
            radius: 22,
            selectedRim: theme.glyph,
            selectedFill: theme.wash
        ))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Sprout in the room the person just picked. The picture changes with the
/// answer, so choosing a room feels like putting the plant somewhere.
struct RoomScene: View {
    let room: OnboardingRoom
    static let design = CGSize(width: 350, height: 250)

    var body: some View {
        Group {
            switch room {
            case .livingRoom: living
            case .bedroom: bedroom
            case .kitchen: kitchen
            case .bathroom: bathroom
            case .office: office
            case .garden: garden
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Sprout in the \(room.title.lowercased())")
    }

    private static func room(_ context: inout GraphicsContext, wall: Color, floor: Color) {
        context.fill(Path(CGRect(origin: .zero, size: design)), with: .color(wall))
        context.fill(Path(CGRect(x: 0, y: 196, width: 350, height: 54)), with: .color(floor))
        context.line([CGPoint(x: 0, y: 196), CGPoint(x: 350, y: 196)])
    }

    private static func window(_ context: inout GraphicsContext, _ rect: CGRect, glass: Color, night: Bool = false) {
        context.outlined(Path(roundedRect: rect, cornerRadius: 10, style: .continuous), glass)
        if night {
            context.outlined(Path(ellipseIn: CGRect(x: rect.maxX - 34, y: rect.minY + 12, width: 18, height: 18)), SproutWorld.moon)
        } else {
            context.outlined(Path(ellipseIn: CGRect(x: rect.maxX - 36, y: rect.minY + 12, width: 22, height: 22)), SproutWorld.sun)
        }
        context.line([CGPoint(x: rect.midX, y: rect.minY + 2), CGPoint(x: rect.midX, y: rect.maxY - 2)], width: 6, color: SproutWorld.white)
        context.line([CGPoint(x: rect.minX + 2, y: rect.midY), CGPoint(x: rect.maxX - 2, y: rect.midY)], width: 6, color: SproutWorld.white)
        context.stroke(Path(roundedRect: rect, cornerRadius: 10, style: .continuous), with: .color(SproutWorld.outline), style: sceneLine)
    }

    private static func smallPot(_ context: inout GraphicsContext, x: CGFloat, top: CGFloat, ceramic: Bool = false) {
        context.outlined(pot(x: x, top: top + 6, width: 40, bottom: top + 30), ceramic ? SproutWorld.ceramic : SproutWorld.terracotta)
        context.outlined(rounded(x - 4, top, 48, 10, 4), ceramic ? SproutWorld.ceramicRim : SproutWorld.terracottaRim)
    }

    private var living: some View {
        PottedScene(design: Self.design, sprout: CGRect(x: 216, y: 52, width: 88, height: 88), pose: .happy, back: { c in
            Self.room(&c, wall: SproutWorld.livingWall, floor: SproutWorld.sill)
            Self.window(&c, CGRect(x: 196, y: 24, width: 122, height: 96), glass: SproutWorld.skyTop)
            c.outlined(rounded(22, 132, 148, 52, 14), SproutWorld.terracotta)
            c.outlined(rounded(14, 158, 164, 30, 12), SproutWorld.terracottaRim)
            c.line([CGPoint(x: 30, y: 188), CGPoint(x: 30, y: 202)])
            c.line([CGPoint(x: 162, y: 188), CGPoint(x: 162, y: 202)])
            c.outlined(rounded(206, 152, 100, 12, 4), SproutWorld.wood)
            c.line([CGPoint(x: 216, y: 164), CGPoint(x: 216, y: 200)])
            c.line([CGPoint(x: 296, y: 164), CGPoint(x: 296, y: 200)])
        }, front: { c in
            Self.smallPot(&c, x: 240, top: 122, ceramic: true)
        })
    }

    private var bedroom: some View {
        PottedScene(design: Self.design, sprout: CGRect(x: 66, y: 52, width: 76, height: 76), pose: .idle, back: { c in
            Self.room(&c, wall: SproutWorld.bedroomWall, floor: SproutWorld.bedroomFloor)
            Self.window(&c, CGRect(x: 30, y: 22, width: 84, height: 70), glass: SproutWorld.nightGlass, night: true)
            c.outlined(rounded(170, 84, 160, 76, 14), SproutWorld.bedFrame)
            c.outlined(rounded(156, 140, 182, 42, 10), SproutWorld.white)
            c.outlined(rounded(206, 134, 132, 52, 10), SproutWorld.bedLinen)
            c.outlined(rounded(166, 126, 42, 20, 8), SproutWorld.white)
            c.line([CGPoint(x: 166, y: 182), CGPoint(x: 166, y: 200)])
            c.line([CGPoint(x: 328, y: 182), CGPoint(x: 328, y: 200)])
            c.outlined(rounded(36, 150, 104, 46, 8), SproutWorld.wood)
            c.line([CGPoint(x: 36, y: 172), CGPoint(x: 140, y: 172)], width: 2)
            var shade = Path()
            shade.addLines([CGPoint(x: 46, y: 104), CGPoint(x: 70, y: 104), CGPoint(x: 76, y: 124), CGPoint(x: 40, y: 124)])
            shade.closeSubpath()
            c.line([CGPoint(x: 58, y: 124), CGPoint(x: 58, y: 150)])
            c.outlined(shade, SproutWorld.sun)
        }, front: { c in
            Self.smallPot(&c, x: 84, top: 120)
        })
    }

    private var kitchen: some View {
        PottedScene(design: Self.design, sprout: CGRect(x: 202, y: 40, width: 88, height: 88), pose: .happy, back: { c in
            Self.room(&c, wall: SproutWorld.kitchenWall, floor: SproutWorld.sill)
            for y in stride(from: CGFloat(96), through: 136, by: 20) {
                c.line([CGPoint(x: 0, y: y), CGPoint(x: 350, y: y)], width: 2, color: SproutWorld.kitchenTile)
            }
            for x in stride(from: CGFloat(20), through: 340, by: 30) {
                c.line([CGPoint(x: x, y: 86), CGPoint(x: x, y: 150)], width: 2, color: SproutWorld.kitchenTile)
            }
            Self.window(&c, CGRect(x: 40, y: 16, width: 110, height: 60), glass: SproutWorld.skyTop)
            c.outlined(rounded(0, 150, 350, 14, 2), SproutWorld.wood)
            c.outlined(Path(CGRect(x: -4, y: 164, width: 358, height: 90)), SproutWorld.sill)
            for x in [CGFloat(88), 176, 264] {
                c.line([CGPoint(x: x, y: 164), CGPoint(x: x, y: 250)], width: 2)
            }
            c.outlined(Path(ellipseIn: CGRect(x: 60, y: 106, width: 52, height: 44)), SproutWorld.kettle)
            c.outlined(rounded(78, 98, 16, 10, 4), SproutWorld.kettle)
        }, front: { c in
            Self.smallPot(&c, x: 226, top: 120)
        })
    }

    private var bathroom: some View {
        PottedScene(design: Self.design, sprout: CGRect(x: 44, y: 30, width: 76, height: 76), pose: .happy, back: { c in
            c.fill(Path(CGRect(origin: .zero, size: Self.design)), with: .color(SproutWorld.bathWall))
            for y in stride(from: CGFloat(30), through: 190, by: 34) {
                c.line([CGPoint(x: 0, y: y), CGPoint(x: 350, y: y)], width: 2, color: SproutWorld.bathTile)
            }
            for x in stride(from: CGFloat(34), through: 340, by: 34) {
                c.line([CGPoint(x: x, y: 0), CGPoint(x: x, y: 196)], width: 2, color: SproutWorld.bathTile)
            }
            c.fill(Path(CGRect(x: 0, y: 196, width: 350, height: 54)), with: .color(SproutWorld.bathFloor))
            c.line([CGPoint(x: 0, y: 196), CGPoint(x: 350, y: 196)])
            c.outlined(rounded(38, 16, 88, 64, 10), SproutWorld.frosted)
            var bath = Path()
            bath.move(to: CGPoint(x: 150, y: 140))
            bath.addLine(to: CGPoint(x: 330, y: 140))
            bath.addLine(to: CGPoint(x: 330, y: 162))
            bath.addQuadCurve(to: CGPoint(x: 300, y: 192), control: CGPoint(x: 330, y: 192))
            bath.addLine(to: CGPoint(x: 180, y: 192))
            bath.addQuadCurve(to: CGPoint(x: 150, y: 162), control: CGPoint(x: 150, y: 192))
            bath.closeSubpath()
            c.outlined(bath, SproutWorld.white)
            c.line([CGPoint(x: 146, y: 140), CGPoint(x: 334, y: 140)])
            c.line([CGPoint(x: 176, y: 192), CGPoint(x: 176, y: 202)])
            c.line([CGPoint(x: 304, y: 192), CGPoint(x: 304, y: 202)])
            for x in [CGFloat(200), 236, 272] {
                var steam = Path()
                steam.move(to: CGPoint(x: x, y: 124))
                steam.addCurve(to: CGPoint(x: x, y: 96), control1: CGPoint(x: x - 10, y: 114), control2: CGPoint(x: x + 10, y: 106))
                c.stroke(steam, with: .color(SproutWorld.steam), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            c.outlined(rounded(32, 122, 100, 10, 4), SproutWorld.white)
        }, front: { c in
            Self.smallPot(&c, x: 62, top: 96, ceramic: true)
        })
    }

    private var office: some View {
        PottedScene(design: Self.design, sprout: CGRect(x: 214, y: 44, width: 76, height: 76), pose: .idle, back: { c in
            Self.room(&c, wall: SproutWorld.officeWall, floor: SproutWorld.officeFloor)
            c.outlined(rounded(232, 40, 96, 8, 3), SproutWorld.wood)
            for (index, x) in [CGFloat(240), 254, 268].enumerated() {
                c.outlined(rounded(x, 14 + CGFloat(index % 2) * 4, 12, 26 - CGFloat(index % 2) * 4, 2), index == 1 ? SproutWorld.sun : SproutWorld.book)
            }
            c.outlined(rounded(70, 56, 128, 76, 10), SproutWorld.screen)
            c.fill(rounded(78, 64, 112, 60, 6), with: .color(SproutWorld.steam))
            c.line([CGPoint(x: 134, y: 132), CGPoint(x: 134, y: 146)])
            c.outlined(rounded(30, 146, 290, 12, 4), SproutWorld.wood)
            c.line([CGPoint(x: 44, y: 158), CGPoint(x: 44, y: 200)])
            c.line([CGPoint(x: 306, y: 158), CGPoint(x: 306, y: 200)])
            c.outlined(rounded(172, 122, 18, 24, 4), SproutWorld.white)
        }, front: { c in
            Self.smallPot(&c, x: 232, top: 116, ceramic: true)
        })
    }

    private var garden: some View {
        PottedScene(design: Self.design, sprout: CGRect(x: 124, y: 52, width: 102, height: 102), pose: .happy, back: { c in
            c.fill(Path(CGRect(origin: .zero, size: Self.design)), with: .linearGradient(
                Gradient(colors: [SproutWorld.skyTop, SproutWorld.skyBottom]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: 200)
            ))
            c.outlined(Path(ellipseIn: CGRect(x: 270, y: 20, width: 44, height: 44)), SproutWorld.sun)
            c.outlined(cloud(at: CGPoint(x: 40, y: 30), scale: 0.8), SproutWorld.white)
            for x in stride(from: CGFloat(-6), through: 350, by: 30) {
                var picket = Path()
                picket.addLines([CGPoint(x: x, y: 196), CGPoint(x: x, y: 130), CGPoint(x: x + 10, y: 118), CGPoint(x: x + 20, y: 130), CGPoint(x: x + 20, y: 196)])
                picket.closeSubpath()
                c.outlined(picket, SproutWorld.ceramicRim)
            }
            c.outlined(rounded(-4, 146, 358, 10, 2), SproutWorld.ceramic)
            c.outlined(Path(CGRect(x: -4, y: 180, width: 358, height: 74)), SproutWorld.grass)
            for (x, color) in [(CGFloat(48), SproutWorld.flower), (300, SproutWorld.sun), (86, SproutWorld.sun), (262, SproutWorld.flower)] {
                c.line([CGPoint(x: x, y: 196), CGPoint(x: x, y: 168)], width: 3)
                c.outlined(Path(ellipseIn: CGRect(x: x - 8, y: 156, width: 16, height: 16)), color)
            }
        }, front: { c in
            c.outlined(pot(x: 146, top: 150, width: 58, bottom: 196), SproutWorld.terracotta)
            c.outlined(rounded(140, 142, 70, 14, 5), SproutWorld.terracottaRim)
        })
    }
}
