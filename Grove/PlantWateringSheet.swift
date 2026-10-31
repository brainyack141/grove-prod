import SwiftUI

// MARK: - The board cell

/// "Water every · 9 days" on the plant board, and the tap that shows the working.
///
/// The value is drawn in the water colour, which is the cell's only sign that
/// it opens something: it is the one number on the board that is a judgement
/// rather than a fact, and the one a careful owner will want to check.
struct PlantWateringCell: View {
    let plant: Plant
    let estimate: PlantWateringEstimate

    @State private var isShowingWorking = false

    var body: some View {
        Button {
            Haptics.tap()
            isShowingWorking = true
        } label: {
            GroveStatCell(label: "Water every", value: estimate.value, tint: GroveTheme.hydration, large: true)
                .contentShape(Rectangle())
        }
        .buttonStyle(GrovePressStyle())
        .accessibilityHint("Shows how this was worked out")
        .accessibilityIdentifier("plantWaterEvery")
        .sheet(isPresented: $isShowingWorking) {
            PlantWateringSheet(plant: plant, estimate: estimate)
        }
    }
}

// MARK: - The working

/// The suggestion, read as a sentence: water every so often, because of what
/// the plant needs, the season where it lives, and what its pot and soil are
/// like. Each reason carries the days it added, so the lines visibly add up to
/// the number at the top. Below that, the one thing that would sharpen it, and
/// the rule that keeps any schedule honest: feel the soil first.
struct PlantWateringSheet: View {
    let plant: Plant
    let estimate: PlantWateringEstimate

    @Environment(IntentRouter.self) private var intentRouter
    @Environment(\.dismiss) private var dismiss

    /// Held until the sheet has gone, then pushed, so the destination never
    /// lands underneath a sheet that is still animating away.
    @State private var routeOnExit: AppRoute?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GroveTheme.sectionSpacing) {
                    headline
                    because
                    if let sharpen = sharpenAction {
                        sharpenRow(sharpen)
                    }
                    beforeYouWater
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, GroveTheme.pagePadding)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
            .groveBackground()
            .navigationTitle(plant.nickname)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.bold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onDisappear {
            guard let routeOnExit else { return }
            intentRouter.pushedRoute = routeOnExit
        }
    }

    // MARK: Headline

    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Watering suggestion")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GroveTheme.mutedInk)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Every")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
                Text("\(estimate.days)")
                    .font(GroveTheme.display(GroveDisplayStyle.hero.points))
                    .tracking(-0.4)
                    .monospacedDigit()
                    .foregroundStyle(GroveTheme.hydration)
                Text("days")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Watering suggestion: every \(estimate.value)")
    }

    // MARK: Because

    private var because: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Because")
                .font(.title3.weight(.semibold))
                .foregroundStyle(GroveTheme.ink)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                ForEach(Array(estimate.steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 {
                        Rectangle().fill(GroveTheme.separator).frame(height: 1).padding(.leading, 16)
                    }
                    PlantWateringStepRow(step: step)
                }
            }
            .groveCard(padding: 0)
        }
    }

    // MARK: Sharpen it

    private struct Sharpen {
        let symbol: String
        let title: String
        let note: String
        let route: AppRoute
    }

    /// Only when one step would make the number firmer. A firm estimate gets
    /// nothing here: there is nothing left to do but feel the soil.
    private var sharpenAction: Sharpen? {
        switch estimate.sharpen {
        case .showPot:
            Sharpen(
                symbol: "camera.fill",
                title: "Show the pot in a check-in",
                note: "Its size and material change this most",
                route: .checkIn(plant.id)
            )
        case .setLight:
            Sharpen(
                symbol: "sun.max.fill",
                title: "Set its light",
                note: "It's counted as near a bright window for now",
                route: .editPlant(plant.id)
            )
        case nil:
            nil
        }
    }

    private func sharpenRow(_ sharpen: Sharpen) -> some View {
        Button {
            Haptics.tap()
            routeOnExit = sharpen.route
            dismiss()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: sharpen.symbol)
                    .font(.title3)
                    .foregroundStyle(GroveTheme.hydration)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sharpen.title)
                        .font(.headline)
                        .foregroundStyle(GroveTheme.ink)
                    Text(sharpen.note)
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(GroveTheme.subtleInk)
                    .accessibilityHidden(true)
            }
            .groveCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(GrovePressStyle())
        .accessibilityHint("Makes this suggestion more accurate")
    }

    // MARK: Before you water

    /// The number is a gap, not an instruction. Grove's watering rule is check,
    /// then act, and the sheet that hands out a schedule is where it has to be
    /// said.
    private var beforeYouWater: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Before you water")
                .font(.title3.weight(.semibold))
                .foregroundStyle(GroveTheme.ink)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 14) {
                tip(
                    symbol: "hand.point.down.fill",
                    tint: GroveTheme.hydration,
                    text: "Feel the soil first. When it's dry two knuckles down, water until it runs out the bottom."
                )
                if let warning = estimate.drainageWarning {
                    Rectangle().fill(GroveTheme.separator).frame(height: 1)
                    tip(symbol: "exclamationmark.triangle.fill", tint: GroveTheme.warning, text: warning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .groveCard()
        }
    }

    private func tip(symbol: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(GroveTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One reason: a plain fact about the plant, and the days it added.
private struct PlantWateringStepRow: View {
    let step: PlantWateringEstimate.Step

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.body)
                    .foregroundStyle(GroveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = step.note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let effectText {
                Text(effectText)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(GroveTheme.hydration)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// The baseline's figure is already in its sentence, and a reason that
    /// moved nothing has no figure to show.
    private var effectText: String? {
        switch step.effect {
        case .start, .change(days: 0): nil
        case let .change(days) where days > 0: "+\(Self.days(days))"
        case let .change(days): "\u{2212}\(Self.days(-days))"
        }
    }

    private var spoken: String {
        let effect: String?
        switch step.effect {
        case .start, .change(days: 0): effect = nil
        case let .change(days) where days > 0: effect = "adds \(Self.days(days))"
        case let .change(days): effect = "takes off \(Self.days(-days))"
        }
        return [step.title, step.note, effect].compactMap { $0 }.joined(separator: ", ")
    }

    private static func days(_ count: Int) -> String {
        count == 1 ? "1 day" : "\(count) days"
    }
}
