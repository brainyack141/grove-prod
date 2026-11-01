import SwiftUI

// MARK: - The plant page: Flighty's board

// A plant's page reads like a flight's status page. The photo is the globe;
// the sheet opens on a three-letter code and the name, says how things stand in
// one coloured line, then shows the plant's progress through its watering gap
// the way Flighty shows a plane between two airports. Below: the numbers, the
// diagnosis, the timetable, and the ways out.

struct PlantBoardPage<Alerts: View>: View {
    @Environment(GroveStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    let plant: Plant
    @Binding var collapsed: Bool
    /// Logs a watering. The page owns the check-the-soil-first question a
    /// repeat watering raises, so the board only asks for it.
    let onWater: () -> Void
    /// The plants either side in the grove list, so a round of many plants is
    /// one pass rather than a push and pop per plant.
    var previous: Plant? = nil
    var next: Plant? = nil
    /// Cards that outrank the status block when they apply: a toxic plant,
    /// an unconfirmed species, a paused plant.
    @ViewBuilder var alerts: Alerts

    var body: some View {
        let facts = PlantPageFacts(plant: plant, store: store)
        PlantSheetFrame(collapsed: $collapsed) {
            PlantThumbnail(plant: plant, height: 340, maxDimension: 1400, breathes: true)
                .overlay { PhotoScrim() }
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 8) {
                        Circle().fill(facts.status.tone.tint).frame(width: 8, height: 8)
                        Caps("\(facts.room) · \(facts.code)", color: .white)
                    }
                    .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
                    .padding(.horizontal, GroveTheme.pagePadding)
                    .padding(.bottom, PlantSheetFrame<EmptyView, EmptyView>.overlap + 16)
                }
        } sheet: {
            VStack(alignment: .leading, spacing: 4) {
                Caps(facts.showsSpecies ? "\(facts.code) · \(plant.species)" : facts.code)
                Text(plant.nickname)
                    .font(GroveTheme.display(GroveDisplayStyle.hero.points))
                    .tracking(-0.4)
                    .foregroundStyle(GroveTheme.ink)
                if !PlantIdentityState.isPlaceholderName(plant.scientificName) {
                    Text(plant.scientificName)
                        .font(.subheadline.italic())
                        .foregroundStyle(GroveTheme.mutedInk)
                }
            }

            alerts

            VStack(alignment: .leading, spacing: 18) {
                BoardStatus(facts: facts)

                BoardJourney(facts: facts)

                Rectangle().fill(GroveTheme.separator).frame(height: 1)

                if typeSize.isAccessibilitySize {
                    // One column at accessibility sizes: two columns clipped every
                    // label to its first word, and the labels explain the numbers.
                    VStack(alignment: .leading, spacing: 18) {
                        nextCell(facts)
                        waterCell(facts)
                        sinceCell(facts)
                    }
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 18) {
                        GridRow {
                            nextCell(facts)
                            waterCell(facts)
                        }
                        GridRow {
                            sinceCell(facts)
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }

                BoardWaterAction(facts: facts, onWater: onWater)
            }

            AriVoiceCard(facts: facts)

            PlantTimetableCard(plant: plant)

            PlantBoardLinks(facts: facts)

            PlantNeighborCard(previous: previous, next: next)
        }
    }

    private func nextCell(_ facts: PlantPageFacts) -> some View {
        GroveStatCell(label: facts.entry.nextLabel, value: facts.entry.nextValue, tint: facts.entry.nextTint, large: true)
    }

    @ViewBuilder
    private func waterCell(_ facts: PlantPageFacts) -> some View {
        if facts.knowsWatering {
            PlantWateringCell(plant: plant, estimate: facts.watering)
        } else {
            // No species, no cadence. A number here would be
            // the guess the identity card says isn't made.
            GroveStatCell(label: "Water", value: "When it's dry", tint: GroveTheme.hydration, large: true)
        }
    }

    private func sinceCell(_ facts: PlantPageFacts) -> some View {
        GroveStatCell(
            label: "In your grove",
            value: facts.since.map { $0.formatted(.dateTime.month(.abbreviated).year()) } ?? "New",
            large: true
        )
    }
}

/// The headline and the number behind it. "Urgent" alone says which way, not
/// how far; the score sits beside it in the band's colour so the word and its
/// severity read as one line. Tapping it opens the working: the trend, the
/// photos and what the last read said.
private struct BoardStatus: View {
    let facts: PlantPageFacts

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var isShowingWorking = false

    private var plant: Plant { facts.plant }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Haptics.tap()
                isShowingWorking = true
            } label: {
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
                layout {
                    VStack(alignment: .leading, spacing: 5) {
                        Caps("Status", color: facts.status.tone.tint)
                        Text(facts.status.text)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(facts.status.tone.tint)
                            .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .trailing, spacing: 5) {
                        Caps("Health")
                        if plant.hasHealthReading {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                trendMark
                                Text("\(plant.healthScore)")
                                    .font(.title2.weight(.bold))
                                    .monospacedDigit()
                                    .foregroundStyle(plant.healthBand.color)
                                Text("/100")
                                    .font(.footnote.weight(.medium))
                                    .monospacedDigit()
                                    .foregroundStyle(GroveTheme.subtleInk)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(GroveTheme.subtleInk)
                                    .padding(.leading, 3)
                            }
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text("No reading")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(GroveTheme.mutedInk)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(GroveTheme.subtleInk)
                                    .padding(.leading, 3)
                            }
                        }
                    }
                    .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(GrovePressStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                plant.hasHealthReading
                    ? "Status, \(facts.status.text). Health \(plant.healthScore) out of 100\(trendSpoken)"
                    : "Status, \(facts.status.text). No health reading yet."
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows the trend and the photos behind the score")
            .accessibilityIdentifier("plantHealthCell")
            .sheet(isPresented: $isShowingWorking) {
                PlantHealthSheet(plantID: plant.id, readAge: facts.readAge)
            }

            if !plant.hasHealthReading {
                NavigationLink(value: AppRoute.checkIn(plant.id)) {
                    Label("Retake photo", systemImage: "camera")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GroveTheme.accentStrong)
                }
                .accessibilityIdentifier("plantRetakeHealthPhoto")
            }
        }
    }

    @ViewBuilder
    private var trendMark: some View {
        switch plant.trend {
        case .improving:
            Image(systemName: "arrow.up")
                .font(.footnote.weight(.bold))
                .foregroundStyle(GroveTheme.healthThriving)
        case .declining:
            Image(systemName: "arrow.down")
                .font(.footnote.weight(.bold))
                .foregroundStyle(GroveTheme.danger)
        default:
            EmptyView()
        }
    }

    private var trendSpoken: String {
        switch plant.trend {
        case .improving: ", improving"
        case .declining: ", declining"
        default: ""
        }
    }
}

/// The plant between two airports: last water and when the next is due, or the
/// last check-in and the next one before any watering is logged.
private struct BoardJourney: View {
    let facts: PlantPageFacts

    @Environment(\.dynamicTypeSize) private var typeSize

    private struct Leg {
        let fromLabel: String
        let from: String
        let toLabel: String
        let to: String
        let progress: Double
        let symbol: String
        let tint: Color
        let late: Bool
    }

    private var leg: Leg? {
        // The same gap the Water-every cell shows, so the bar and the number
        // beside it can never disagree. "Due", not "Dry": the gap is an
        // estimate, and the sheet behind it says to feel the soil first.
        if let last = facts.lastWater, let since = facts.daysSinceWater, let typical = facts.waterDays {
            let due = Calendar.current.date(byAdding: .day, value: typical, to: last) ?? last
            return Leg(
                fromLabel: "Watered", from: PlantPageFacts.day(last),
                toLabel: since >= typical ? "Due since" : "Water around", to: PlantPageFacts.day(due),
                progress: Double(since) / Double(max(typical, 1)),
                symbol: "drop.fill", tint: GroveTheme.hydration, late: since >= typical
            )
        }
        let start = facts.observations.last?.createdAt ?? facts.since
        guard let start else { return nil }
        let next = facts.plant.nextCheckIn
        let total = max(1, PlantPageProgress.days(from: start, to: next))
        let elapsed = PlantPageProgress.days(from: start, to: .now)
        return Leg(
            fromLabel: "Last check-in", from: PlantPageFacts.day(start),
            toLabel: "Next check-in", to: PlantPageFacts.day(next),
            progress: Double(elapsed) / Double(total),
            symbol: "camera.fill", tint: GroveTheme.mutedInk, late: next < .now
        )
    }

    var body: some View {
        if let leg {
            let progress = min(1, max(0.04, leg.progress))
            // Labels first, so the bar reads as a timeline before it can be
            // mistaken for a health meter sitting under the status.
            VStack(alignment: .leading, spacing: 10) {
                let labelsLayout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(alignment: .top))
                labelsLayout {
                    GroveStatCell(label: leg.fromLabel, value: leg.from)
                    VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 5) {
                        Caps(leg.toLabel)
                        Text(leg.to)
                            .font(.body.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(leg.late ? GroveTheme.warning : GroveTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(GroveTheme.separator).frame(height: 4)
                        Capsule().fill(leg.tint).frame(width: proxy.size.width * progress, height: 4)
                        Image(systemName: leg.symbol)
                            .font(.footnote)
                            .foregroundStyle(leg.tint)
                            .frame(width: 32, height: 32)
                            .background(GroveTheme.surface, in: Circle())
                            .groveShadow(.resting)
                            .offset(x: max(0, min(proxy.size.width - 32, proxy.size.width * progress - 16)))
                    }
                    .frame(height: 32)
                }
                .frame(height: 32)
                .accessibilityHidden(true)
            }
        }
    }
}

/// Everything the board reads, worked out once per render.
struct PlantPageFacts {
    let plant: Plant
    let entry: TodayBoardEntry
    /// Oldest first.
    let observations: [PlantObservation]
    let copy: PlantAriReadCopy
    let safety: PlantSafety
    let readAt: Date?
    /// How often to water, worked out from the pot, the light, the season and
    /// the last diagnosis. The board's one watering number: the Water-every
    /// cell and the journey bar both read it, so they always agree.
    let watering: PlantWateringEstimate

    @MainActor
    init(plant: Plant, store: GroveStore) {
        self.plant = plant
        let observations = store.observations(for: plant.id)
        let diagnosis = store.currentDiagnosis(for: plant.id)
        let hasEvidence = PlantDetailView.hasCurrentEvidence(plant: plant, observations: observations)
        let takeaway = AriScanTakeaway.make(
            plant: plant,
            diagnoses: store.diagnoses(for: plant.id),
            scans: store.scanHistory,
            observations: observations
        )
        let read = PlantStateRead.strongest(
            for: plant,
            latest: PlantDetailView.liveObservation(in: observations),
            diagnosis: diagnosis,
            hasCurrentEvidence: hasEvidence
        )
        // Siblings, so the code here is the one Today's map prints.
        self.entry = TodayBoardEntry(
            plant: plant,
            nextTask: store.nextPendingTask(for: plant.id),
            tasks: store.tasks,
            siblings: store.plants
        )
        self.observations = observations.sorted { $0.createdAt < $1.createdAt }
        self.copy = PlantAriReadCopy.make(plant: plant, read: read, hasCurrentEvidence: hasEvidence, takeaway: takeaway)
        self.safety = PlantSafety(plant: plant)
        let readAt = takeaway?.scanDate ?? plant.assessmentDate
        self.readAt = readAt
        self.watering = PlantWateringEstimate(
            plant: plant,
            read: read,
            readAge: readAt.map { PlantPageProgress.ageLabel($0) },
            location: store.profile.location
        )
    }

    var status: GroveStatus { entry.status }
    var code: String { entry.code }
    var room: String { entry.room }
    var lastWater: Date? { entry.rhythm.waterings.last?.date }
    var daysSinceWater: Int? { entry.rhythm.daysSinceLast }
    /// Whether the page may give a watering cadence at all. Not for a plant
    /// it can't name: the identity card says no care guide is guessed.
    var knowsWatering: Bool { !PlantIdentityState.needsResolving(plant) }
    /// The gap the journey bar runs on: the estimate, never a second number.
    var waterDays: Int? { knowsWatering ? watering.days : nil }
    var since: Date? { plant.acquiredAt ?? observations.first?.createdAt }

    var showsSpecies: Bool {
        !PlantIdentityState.isPlaceholderName(plant.species)
            && plant.species.caseInsensitiveCompare(plant.nickname) != .orderedSame
    }

    var readAge: String? {
        readAt.map { PlantPageProgress.ageLabel($0) }
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

}

// MARK: - Pieces

/// The photo-and-sheet frame (DESIGN.md §16 rule 9): a hero that runs under
/// the status bar and a sheet with a grabber riding over it.
private struct PlantSheetFrame<Hero: View, Sheet: View>: View {
    var heroGround: Color = GroveTheme.mapGround
    @Binding var collapsed: Bool
    @ViewBuilder var hero: Hero
    @ViewBuilder var sheet: Sheet

    @State private var heroHeight: CGFloat = 340
    static var overlap: CGFloat { GroveTheme.heroRadius + 6 }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                    .frame(maxWidth: .infinity)
                    .background(heroGround)
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [.black.opacity(0.42), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 130)
                            .allowsHitTesting(false)
                    }
                    .clipped()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heroHeight = $0 }
                    .visualEffect { content, proxy in
                        let minY = proxy.frame(in: .scrollView).minY
                        return content.offset(y: minY < 0 ? -minY * 0.66 : 0)
                    }

                VStack(alignment: .leading, spacing: GroveTheme.sectionSpacing) {
                    sheet
                }
                .padding(.horizontal, GroveTheme.pagePadding)
                .padding(.top, 26)
                .padding(.bottom, GroveTheme.pageBottomPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .top) {
                    Capsule()
                        .fill(GroveTheme.separator)
                        .frame(width: 38, height: 5)
                        .padding(.top, 8)
                        .accessibilityHidden(true)
                }
                .background(
                    GroveTheme.surface,
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: Self.overlap,
                        topTrailingRadius: Self.overlap,
                        style: .continuous
                    )
                )
                .padding(.top, -Self.overlap)
                .zIndex(1)
            }
        }
        .ignoresSafeArea(edges: .top)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y > heroHeight - Self.overlap - 110
        } action: { _, atTop in
            guard atTop != collapsed else { return }
            withAnimation(.easeInOut(duration: 0.22)) { collapsed = atTop }
        }
        .background {
            VStack(spacing: 0) {
                heroGround.frame(height: 420)
                GroveTheme.surface
            }
            .ignoresSafeArea()
        }
    }
}

/// The scrim every photo hero carries so white type holds on a bright leaf.
private struct PhotoScrim: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.55), location: 0),
                .init(color: .black.opacity(0.22), location: 0.22),
                .init(color: .black.opacity(0), location: 0.42),
                .init(color: .black.opacity(0.45), location: 0.68),
                .init(color: .black.opacity(0.78), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
}

/// Small caps, the one label (§16 rule 2).
private struct Caps: View {
    let text: String
    var color: Color = GroveTheme.subtleInk

    init(_ text: String, color: Color = GroveTheme.subtleInk) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// Ari speaking, on night green. Ari sits in the corner in person, large and
/// cropped by the card's edge, so the read has someone behind it; the 26pt
/// glyph it replaced disappeared into the ground. The words keep a column to
/// the seed's left, and at accessibility sizes the seed steps aside so they get
/// the whole card.
private struct AriVoiceCard: View {
    let facts: PlantPageFacts
    @Environment(GroveStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The seed's drawn size and how far it hangs off the card's corner.
    private static let seed: CGFloat = 140
    private static let overhang = CGSize(width: 24, height: 28)
    /// Room the words leave on the right so they never run under the seed.
    private static let seedColumn: CGFloat = 72
    /// How tall the button row stands when steps sit above it, so the steps
    /// end above the seed's head rather than running behind it: the seed's
    /// visible height, less the card's own bottom padding.
    private static let seedClearance: CGFloat = seed - overhang.height - 20

    private var showsSeed: Bool { !typeSize.isAccessibilitySize }

    /// The status line above already says how the plant is. When Ari's
    /// headline would repeat it word for word ("Needs attention", twice, a
    /// screen apart), the card opens on what the photo found instead.
    private var repeatsStatus: Bool {
        facts.copy.headline.caseInsensitiveCompare(facts.status.text) == .orderedSame
    }

    /// The steps the last assessment left. None when the read itself is too
    /// old to speak for the plant: a plan for a month-old photo is history.
    private var plan: PlantPlanSteps {
        guard PlantDetailView.hasCurrentEvidence(plant: facts.plant, observations: facts.observations) else {
            return PlantPlanSteps(steps: [])
        }
        return PlantPlanSteps.make(plant: facts.plant)
    }

    /// A diagnosis with a recovery plan worth opening, by the same rule the
    /// plant page has always used to put one first.
    private var recoveryDiagnosisID: UUID? {
        guard let diagnosis = store.currentDiagnosis(for: facts.plant.id),
              diagnosis.healthBand.needsAttention,
              diagnosis.actionability == nil || diagnosis.actionability == .actionable,
              !diagnosis.actionsToTake.isEmpty else { return nil }
        return diagnosis.id
    }

    /// Names the photo behind the diagnosis. Ari speaks only inside Ask, so
    /// the label is the diagnosis and when its photo was taken.
    private var byline: String {
        guard let readAt = facts.readAt else { return "Diagnosis" }
        return switch PlantPageProgress.days(from: readAt, to: .now) {
        case ...0: "Diagnosis · today's photo"
        case 1: "Diagnosis · yesterday's photo"
        case let days: "Diagnosis · photo from \(days) days ago"
        }
    }

    var body: some View {
        let plan = plan
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Caps(byline, color: GroveTheme.mapCaption)
                    .padding(.bottom, 10)
                if repeatsStatus {
                    Text(facts.copy.finding)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    if let explanation = facts.copy.explanation {
                        Text(explanation)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 6)
                    }
                } else {
                    GroveDisplayHeading(text: facts.copy.headline, style: .heading, color: .white)
                        .padding(.bottom, 10)
                    // What the photo showed, then what to do about it: Ari notices
                    // before advising, and the advice was being dropped here.
                    Text([facts.copy.finding, facts.copy.explanation].compactMap { $0 }.joined(separator: " "))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.trailing, showsSeed ? Self.seedColumn : 0)

            // The plan runs the card's full width: it is the part people act
            // on, and a 70-point gutter turned every step into three lines.
            if !plan.isEmpty {
                AriPlanSteps(plant: facts.plant, plan: plan)
                    .padding(.top, 18)
            }

            HStack(spacing: 18) {
                // Finished checks turn Ask Ari into the way to report them:
                // the draft lists each check with a blank for what it showed,
                // and Ari answers with what to do about it.
                if let findings = plan.findingsDraft(nickname: facts.plant.nickname) {
                    NavigationLink(value: AppRoute.askAboutLatestScan(facts.plant.id, initialDraft: findings)) {
                        Text("Tell Ari what you found")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(GroveTheme.inkOnLight)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 44)
                            .background(.white, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(GrovePressStyle())
                    .accessibilityIdentifier("plantTellAriFindings")
                } else {
                    NavigationLink(value: AppRoute.askAbout(facts.plant.id)) {
                        GroveOutlineLabel(title: "Ask Ari", size: .compact, onDark: true)
                    }
                    .buttonStyle(GrovePressStyle())
                    .accessibilityLabel("Ask Ari about \(facts.plant.nickname)")
                }

                if let recoveryDiagnosisID {
                    NavigationLink(value: AppRoute.plantDiagnosis(recoveryDiagnosisID)) {
                        Text("Recovery plan")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.82))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(GrovePressStyle())
                    .accessibilityIdentifier("plantRecoveryPlan")
                }
            }
            .padding(.trailing, showsSeed ? Self.seedColumn : 0)
            .frame(minHeight: showsSeed && !plan.isEmpty ? Self.seedClearance : nil, alignment: .bottomLeading)
            .padding(.top, 18)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: showsSeed ? 220 : nil, alignment: .topLeading)
        .background(alignment: .bottomTrailing) {
            if showsSeed {
                Image("GroveBotanist")
                    .resizable()
                    .scaledToFit()
                    .frame(width: Self.seed, height: Self.seed)
                    .offset(Self.overhang)
                    .accessibilityHidden(true)
            }
        }
        .groveAriSurface()
        .clipShape(RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
    }
}

/// The page's way out to everything that isn't the plant right now.
private struct PlantBoardLinks: View {
    let facts: PlantPageFacts

    @State private var showingSafety = false
    @State private var showingCareGuide = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                showingCareGuide = true
            } label: {
                row("Care guide", detail: PlantCareGuideSheet.rowDetail(for: facts.plant), symbol: "book.closed")
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the species care guide")
            .accessibilityIdentifier("plantCareGuideRow")
            divider
            Button {
                showingSafety = true
            } label: {
                row("Pets and children", detail: safetyWord, symbol: "pawprint")
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the household safety findings")
            divider
            NavigationLink(value: AppRoute.plantHistory(facts.plant.id)) {
                row(
                    "Full history",
                    detail: facts.observations.isEmpty
                        ? nil
                        : facts.observations.count == 1 ? "1 check-in" : "\(facts.observations.count) check-ins",
                    symbol: "clock.arrow.circlepath"
                )
            }
            .buttonStyle(.plain)
        }
        .groveCard(padding: 0)
        .sheet(isPresented: $showingSafety) {
            PlantSafetySheet(plant: facts.plant, safety: facts.safety)
        }
        .sheet(isPresented: $showingCareGuide) {
            PlantCareGuideSheet(plant: facts.plant)
        }
    }

    private var safetyWord: String { facts.safety.shortLabel }

    private var divider: some View {
        Rectangle().fill(GroveTheme.separator).frame(height: 1).padding(.leading, 52)
    }

    private func row(_ title: String, detail: String?, symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(GroveTheme.mutedInk)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(title)
                .font(.body)
                .foregroundStyle(GroveTheme.ink)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(detail == "Toxic" ? GroveTheme.danger : GroveTheme.mutedInk)
                    .multilineTextAlignment(.trailing)
            }
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GroveTheme.subtleInk)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 54)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The one care the board records by hand. Every watering number on the page
/// runs from the last logged watering, so the way to log one sits right under
/// them. After a watering today it says so, and stays tappable: a second tap
/// is the page's check-the-soil question, not a dead button.
private struct BoardWaterAction: View {
    let facts: PlantPageFacts
    let onWater: () -> Void

    private var wateredToday: Bool {
        facts.lastWater.map { Calendar.current.isDateInToday($0) } ?? false
    }

    var body: some View {
        Button {
            onWater()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: wateredToday ? "checkmark" : "drop.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(GroveTheme.hydration)
                    .contentTransition(.symbolEffect(.replace))
                Text(wateredToday ? "Watered today" : "Log watering")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(GroveTheme.surface, in: Capsule())
            .overlay { Capsule().stroke(GroveTheme.separator, lineWidth: 1.5) }
            .contentShape(Capsule())
        }
        .buttonStyle(GrovePressStyle())
        .animation(GroveMotion.settle, value: wateredToday)
        .accessibilityLabel(wateredToday ? "Watered today. Log another watering" : "Log watering")
        .accessibilityIdentifier("plantLogWatering")
    }
}

