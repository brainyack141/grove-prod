import SwiftUI

/// The compact weather affordance beside Today's grove location.
///
/// The live temperature makes the control legible before anyone knows Grove's
/// "seasonal" language, while the advisory tone quietly carries urgency. The
/// pill opens a separate layer; it does not also edit the location beside it.
///
/// The temperature is the second-largest number on the masthead and the pill
/// is lit like every other Grove surface, so the sky reads as a small object
/// sitting on the card rather than a flat tint that looks switched off.
struct SeasonalWeatherButton: View {
    let phase: WeatherService.Phase
    let usesMetric: Bool
    let primaryAdvisory: GroveSkyAdvisory?
    /// Drawn as a bar item beside the bell: no capsule of its own, because
    /// the bar's glass already is one.
    var bare: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: bare ? 5 : 8) {
                mark

                if let temperature {
                    Text(temperature)
                        .font(bare ? .body.weight(.semibold) : .system(.title3, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(GroveTheme.ink)
                }
            }
            .padding(.horizontal, bare ? 4 : (temperature == nil ? 12 : 14))
            .frame(minWidth: 44, minHeight: 44)
            .background { if !bare { capsuleWash } }
            .overlay {
                if !bare { Capsule().strokeBorder(tint.opacity(0.20), lineWidth: 1) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(GrovePressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Shows seasonal plant advice, weather and recent light")
        .accessibilityIdentifier("todaySeasonalButton")
    }

    /// Light arrives at the top-left in Grove, so the same tone that carries
    /// urgency is brightest at the top of the capsule and settles toward the
    /// bottom, giving the pill a lit surface instead of a flat fill.
    private var capsuleWash: some View {
        Capsule().fill(
            LinearGradient(
                colors: [tint.opacity(0.22), tint.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    @ViewBuilder
    private var mark: some View {
        switch phase {
        case .idle, .loading:
            ProgressView()
                .controlSize(.small)
                .tint(tint)
                .frame(width: 22, height: 22)
        case .loaded(let forecast):
            Image(systemName: forecast.current?.symbol ?? primaryAdvisory?.symbol ?? "cloud.sun.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
        case .failed:
            Image(systemName: "wifi.slash")
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
        }
    }

    private var temperature: String? {
        guard case .loaded(let forecast) = phase, let current = forecast.current else { return nil }
        return "\(current.temperature(metric: usesMetric))°"
    }

    private var tint: Color {
        if case .failed = phase { return GroveTheme.subtleInk }
        guard let tone = primaryAdvisory?.tone else { return GroveTheme.accent }
        return switch tone {
        case .caution: GroveTheme.warning
        case .notable: GroveTheme.accent
        // Gold is for celebrations; calm weather is just quiet.
        case .calm: GroveTheme.mutedInk
        }
    }

    private var accessibilityLabel: String {
        switch phase {
        case .idle, .loading:
            return "Seasonal conditions are loading"
        case .failed:
            return "Seasonal conditions couldn't refresh"
        case .loaded(let forecast):
            let reading = forecast.current.map {
                "\($0.temperature(metric: usesMetric)) degrees \(usesMetric ? "Celsius" : "Fahrenheit")"
            }
            let notes = primaryAdvisory == nil ? nil : "Seasonal advice available"
            let label = [reading, notes].compactMap { $0 }.joined(separator: ". ")
            return label.isEmpty ? "Seasonal conditions" : label
        }
    }
}

/// The local care note shown in Today's seasonal layer.
///
/// It intentionally accepts every relevant advisory, not just the headline.
/// Each advisory that measured something shows its figure — the humidity
/// reading, the sun-hours shift, the light ladder — with the one action under
/// it, because a number registers in the glance a paragraph never gets. The
/// prose stays in the model for VoiceOver and the botanist; cautions that name
/// plants remain sentences, which is the right shape for "move Monty tonight".
struct SeasonalAdviceCard: View {
    enum Presentation: Equatable {
        case compact
        case detail
    }

    let location: GroveLocation
    let advisories: [GroveSkyAdvisory]
    var presentation: Presentation = .compact

    @State private var isExpanded = false

    private var primary: GroveSkyAdvisory? { advisories.first }

    /// More to show: further advisories, or the prose behind a sentence-only
    /// primary. A lone figure advisory already says everything it has.
    private var isExpandable: Bool {
        advisories.count > 1 || (primary?.figure == nil && primary?.detail != nil)
    }

    private var showsExpandedAdvice: Bool {
        presentation == .detail || isExpanded
    }

    @ViewBuilder
    var body: some View {
        if let primary {
            VStack(alignment: .leading, spacing: 0) {
                if presentation == .compact, isExpandable {
                    Button {
                        Haptics.selection()
                        withAnimation(GroveMotion.snap) { isExpanded.toggle() }
                    } label: {
                        header(primary, showsChevron: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityLabel(primary))
                    .accessibilityHint(isExpanded ? "Hides the other seasonal notes" : "Shows every seasonal note")
                } else {
                    header(primary, showsChevron: false)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(accessibilityLabel(primary))
                }

                block(primary, hero: true)
                    .padding(.top, 13)

                if showsExpandedAdvice {
                    expandedAdvice(primary)
                        .transition(.opacity.combined(with: .offset(y: -5)))
                } else if presentation == .compact, advisories.count > 1 {
                    Text("\(advisories.count - 1) more \(advisories.count == 2 ? "note" : "notes") for your grove")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GroveTheme.accentStrong)
                        .padding(.top, 12)
                }
            }
            .groveCard(padding: 16)
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: - Header

    private func header(_ advisory: GroveSkyAdvisory, showsChevron: Bool) -> some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(tint(advisory.tone).opacity(0.11))
                if let asset = customIconName(for: advisory.kind) {
                    seasonalIcon(asset, size: 32)
                } else {
                    Image(systemName: advisory.symbol)
                        .symbolRenderingMode(.hierarchical)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(tint(advisory.tone))
                }
            }
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)

            Text("Seasonal for \(location.shortLabel)")
                .font(.headline.weight(.bold))
                .foregroundStyle(GroveTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 4)

            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(GroveTheme.subtleInk)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Blocks

    /// One advisory, in whichever shape its evidence takes. The hero position
    /// is the primary advisory sitting directly under the header; everything
    /// below a divider renders with its own leading symbol instead.
    @ViewBuilder
    private func block(_ advisory: GroveSkyAdvisory, hero: Bool) -> some View {
        switch advisory.figure {
        case .reading(let value, let unit):
            if hero {
                figureTile(advisory, value: value, unit: unit, delta: nil, rising: false)
            } else {
                figureRow(advisory, value: value, unit: unit, delta: nil, rising: false)
            }
        case .shift(let value, let unit, let delta, let rising):
            if hero {
                figureTile(advisory, value: value, unit: unit, delta: delta, rising: rising)
            } else {
                figureRow(advisory, value: value, unit: unit, delta: delta, rising: rising)
            }
        case .lightLadder(let outdoorHours):
            lightLadder(advisory, outdoorHours: outdoorHours)
        case nil:
            if hero {
                Text(advisory.headline)
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 61)
                    .accessibilityHidden(true)
            } else {
                sentenceRow(advisory)
            }
        }
    }

    /// The primary figure at full width: the number on a soft field of its own
    /// tone, the situation and the action beside it.
    private func figureTile(_ advisory: GroveSkyAdvisory, value: String, unit: String, delta: String?, rising: Bool) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(GroveTheme.display(GroveDisplayStyle.title.points))
                    .monospacedDigit()
                    .foregroundStyle(emphasis(advisory.tone))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
            }
            .layoutPriority(1)

            Rectangle()
                .fill(GroveTheme.separator)
                .frame(width: 1, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    if let brief = advisory.brief {
                        Text(brief)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(GroveTheme.ink)
                    }
                    if let delta {
                        deltaChip(delta, rising: rising)
                    }
                }
                if let cue = advisory.cue {
                    Text(cue)
                        .font(.footnote)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            tint(advisory.tone).opacity(0.08),
            in: RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
        )
        // The header already announces the whole headline; repeating its parts
        // piecemeal would read the same advice twice.
        .accessibilityHidden(true)
    }

    /// A further advisory with its figure: named, measured, and one line on
    /// what to do.
    private func figureRow(_ advisory: GroveSkyAdvisory, value: String, unit: String, delta: String?, rising: Bool) -> some View {
        HStack(alignment: .top, spacing: 13) {
            advisoryIcon(advisory, size: 23)
                .frame(width: 48)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 3) {
                if let brief = advisory.brief {
                    Text(brief)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(GroveTheme.ink)
                }

                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(value)
                        .font(GroveTheme.display(GroveDisplayStyle.section.points))
                        .monospacedDigit()
                        .foregroundStyle(GroveTheme.ink)
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(GroveTheme.mutedInk)
                    if let delta {
                        deltaChip(delta, rising: rising)
                    }
                }

                if let cue = advisory.cue {
                    Text(cue)
                        .font(.footnote)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(advisory.headline)
    }

    /// What the light out there becomes on the way in: the same daylight meter
    /// the placement picker draws, so the shares can never disagree with the
    /// model that set them.
    private func lightLadder(_ advisory: GroveSkyAdvisory, outdoorHours: Double) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ladderColumn(
                    asset: "SeasonalIconTree",
                    label: "Outdoors",
                    fraction: 1,
                    value: GroveSky.duration(outdoorHours)
                )
                ladderColumn(
                    asset: "SeasonalIconSillSun",
                    label: "Windowsill",
                    fraction: PlantLightPlacement.sill.outdoorLightShare,
                    value: "½"
                )
                ladderColumn(
                    asset: "SeasonalIconRoomSun",
                    label: "Across the room",
                    fraction: PlantLightPlacement.shaded.outdoorLightShare,
                    value: "1⁄20"
                )
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(advisory.headline)

            if let cue = advisory.cue {
                Divider().overlay(GroveTheme.separator)

                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(GroveTheme.accent.opacity(0.11))
                        seasonalIcon("SeasonalIconLeaf", size: 22)
                    }
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)

                    Text(cue)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(GroveTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The icon band has a fixed height because the custom marks have different
    /// silhouettes (a tree is tall, a horizon sun is squat), and each column's
    /// whole stack shifts by that difference otherwise. The label and value
    /// rows are single lines of one font each, so they align on their own — the
    /// bars form one axis and the values one baseline.
    private func ladderColumn(asset: String, label: String, fraction: Double, value: String) -> some View {
        VStack(spacing: 6) {
            seasonalIcon(asset, size: 25)
                .frame(height: 25)
            Text(label)
                .font(.caption)
                .foregroundStyle(GroveTheme.mutedInk)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            GroveProgressBar(
                fraction: fraction,
                tint: GroveTheme.goldDeep,
                height: 5,
                minimumFill: 3
            )
            Text(value)
                .font(.footnote.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(GroveTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
    }

    /// A caution that names plants stays a sentence; "move Monty off the
    /// glass tonight" has no number worth leading with.
    private func sentenceRow(_ advisory: GroveSkyAdvisory) -> some View {
        HStack(alignment: .top, spacing: 13) {
            advisoryIcon(advisory, size: 23)
                .frame(width: 48)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(advisory.headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = advisory.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Expansion

    private func expandedAdvice(_ primary: GroveSkyAdvisory) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let detail = primary.detail,
               primary.figure == nil || presentation == .detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, primary.figure == nil ? 61 : 0)
                    .padding(.top, 10)
            }

            ForEach(Array(advisories.dropFirst())) { advisory in
                Divider()
                    .overlay(GroveTheme.separator)
                    .padding(.vertical, 14)
                block(advisory, hero: false)

                if presentation == .detail,
                   advisory.figure != nil,
                   let detail = advisory.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 61)
                        .padding(.top, 8)
                }
            }
        }
    }

    // MARK: - Shared drawing

    @ViewBuilder
    private func advisoryIcon(_ advisory: GroveSkyAdvisory, size: CGFloat) -> some View {
        if let asset = customIconName(for: advisory.kind) {
            seasonalIcon(asset, size: size)
        } else {
            Image(systemName: advisory.symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint(advisory.tone))
        }
    }

    private func customIconName(for kind: GroveSkyAdvisory.Kind) -> String? {
        switch kind {
        case .dryAir: "SeasonalIconBreeze"
        case .brightRun: "SeasonalIconSun"
        default: nil
        }
    }

    private func seasonalIcon(_ name: String, size: CGFloat) -> some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }

    private func deltaChip(_ text: String, rising: Bool) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(rising ? GroveTheme.goldDeep : GroveTheme.mutedInk)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                rising ? GroveTheme.gold.opacity(0.14) : GroveTheme.secondarySurface,
                in: Capsule()
            )
    }

    private func tint(_ tone: GroveSkyAdvisory.Tone) -> Color {
        switch tone {
        case .caution: GroveTheme.warning
        case .notable: GroveTheme.accent
        case .calm: GroveTheme.gold
        }
    }

    /// The figure's own colour: the tone family, held dark enough to carry
    /// display-size type on the soft field.
    private func emphasis(_ tone: GroveSkyAdvisory.Tone) -> Color {
        switch tone {
        case .caution: GroveTheme.warning
        case .notable: GroveTheme.accentStrong
        case .calm: GroveTheme.ink
        }
    }

    private func accessibilityLabel(_ primary: GroveSkyAdvisory) -> String {
        let additional = advisories.count - 1
        let more = additional > 0 ? ", plus \(additional) more \(additional == 1 ? "note" : "notes")" : ""
        return "Seasonal for \(location.shortLabel). \(primary.headline)\(more)"
    }
}

/// Keeps the seasonal surface present while its evidence is loading, missing or
/// temporarily unavailable. A useful Today component cannot vanish precisely
/// when the network is slow; each state says only what Grove actually knows.
struct SeasonalAdviceStatusCard: View {
    enum State: Equatable {
        case loading
        case steady
        case unavailable
    }

    let location: GroveLocation
    let state: State
    var retry: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack {
                Circle().fill(iconColor.opacity(0.11))
                if state == .loading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(iconColor)
                } else {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.hierarchical)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(iconColor)
                }
            }
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Seasonal for \(location.shortLabel)")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(GroveTheme.ink)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)

                if state == .unavailable, let retry {
                    Button(action: retry) {
                        Text("Try again")
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(GroveTheme.accentStrong)
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 4)
        }
        .groveCard(padding: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Seasonal for \(location.shortLabel). \(message)")
    }

    private var symbol: String {
        switch state {
        case .loading: "cloud.sun.fill"
        case .steady: "checkmark.circle.fill"
        case .unavailable: "wifi.slash"
        }
    }

    private var iconColor: Color {
        switch state {
        case .loading, .steady: GroveTheme.accent
        case .unavailable: GroveTheme.subtleInk
        }
    }

    private var message: String {
        switch state {
        case .loading:
            "Loading this week's weather and light…"
        case .steady:
            "Conditions look steady. Check each plant before changing its care."
        case .unavailable:
            "Local conditions couldn't refresh. Your care schedule isn't affected."
        }
    }
}

/// The secondary layer opened from the conditions pill beside the location.
/// Advice leads; raw forecast and light evidence follow for anyone who wants to
/// inspect why Grove is recommending a change.
struct SeasonalAdviceSheet: View {
    let location: GroveLocation

    @Environment(GroveStore.self) private var store
    @Environment(WeatherService.self) private var weather
    @Environment(\.dismiss) private var dismiss

    private var usesMetric: Bool {
        store.profile.usesMetricSystem ?? (Locale.current.measurementSystem == .metric)
    }

    private var advisories: [GroveSkyAdvisory] {
        guard case .loaded(let forecast) = weather.phase else { return [] }
        return GroveSky.advisories(
            forecast: forecast,
            plants: store.plants,
            profile: store.profile
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GroveTheme.sectionSpacing) {
                    advice

                    if case .loaded = weather.phase {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "Forecast & light")
                            SkyCard(
                                location: location,
                                phase: weather.phase,
                                usesMetric: usesMetric
                            )
                        }
                    }
                }
                .padding(.horizontal, GroveTheme.pagePadding)
                .padding(.top, 14)
                .padding(.bottom, 28)
            }
            .groveBackground()
            .navigationTitle("Seasonal")
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
    }

    @ViewBuilder
    private var advice: some View {
        switch weather.phase {
        case .loaded:
            if advisories.isEmpty {
                SeasonalAdviceStatusCard(location: location, state: .steady)
            } else {
                SeasonalAdviceCard(
                    location: location,
                    advisories: advisories,
                    presentation: .detail
                )
            }
        case .failed:
            SeasonalAdviceStatusCard(location: location, state: .unavailable) {
                Task { await weather.load(for: location.coordinate) }
            }
        case .idle, .loading:
            SeasonalAdviceStatusCard(location: location, state: .loading)
        }
    }
}

/// Everything the sky is doing to the grove, in one card.
///
/// This was two: a week-ahead forecast strip and a fortnight-behind sunlight
/// chart, stacked, together taking a fifth of the home page for information
/// nobody opened the app to get. They are the same subject asked in two
/// directions, so they are now one card — forecast in front, sun behind it —
/// and the chart only takes its full height when someone asks for it.
///
/// This is the evidence below the care advice in Today's seasonal layer: the
/// forecast in front and the recent light record behind it.
struct SkyCard: View {
    let location: GroveLocation
    let phase: WeatherService.Phase
    let usesMetric: Bool

    @State private var showsSunDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            forecast
            if case .loaded(let forecastData) = phase, !forecastData.sunlight.isEmpty {
                Divider().overlay(GroveTheme.separator)
                sun(forecastData.sunlight)
            }
        }
        .groveCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sky over \(location.label)")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "location.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(GroveTheme.accent)
            Text(location.label)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(GroveTheme.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(usesMetric ? "°C" : "°F")
                .font(.caption2.weight(.bold))
                .foregroundStyle(GroveTheme.subtleInk)
        }
    }

    // MARK: - Forecast

    @ViewBuilder
    private var forecast: some View {
        switch phase {
        case .loaded(let forecastData):
            HStack(spacing: 0) {
                ForEach(forecastData.days) { day in
                    dayCell(day)
                }
            }
        case .failed:
            Text("No forecast right now. Care advice carries on without it.")
                .font(.footnote)
                .foregroundStyle(GroveTheme.mutedInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { _ in
                    placeholderCell
                }
            }
            .redacted(reason: .placeholder)
            // Redaction alone greys the row out and then says nothing more. The
            // sweep is what distinguishes "loading" from "broken".
            .groveShimmer()
            // Spoken as what it is, not seven "em dash, zero zero degrees".
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading the forecast")
        }
    }

    private func dayCell(_ day: GroveWeatherDay) -> some View {
        VStack(spacing: 7) {
            Text(day.isToday ? "Today" : day.weekdayLetter)
                .font(.caption2.weight(day.isToday ? .bold : .semibold))
                .foregroundStyle(day.isToday ? GroveTheme.ink : GroveTheme.mutedInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Image(systemName: day.symbol)
                .symbolRenderingMode(.multicolor)
                .font(.title3)
                .frame(height: 24)
            Text("\(day.high(metric: usesMetric))°")
                .font(.footnote.weight(.bold))
                .foregroundStyle(GroveTheme.ink)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background {
            if day.isToday {
                RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous)
                    .fill(GroveTheme.softAccent)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(day.isToday ? "Today" : day.weekdayLetter), high \(day.high(metric: usesMetric)) degrees")
    }

    private var placeholderCell: some View {
        VStack(spacing: 7) {
            Text("—").font(.caption2.weight(.semibold))
            Image(systemName: "sun.max.fill").font(.title3).frame(height: 24)
            Text("00°").font(.footnote.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Sun

    @ViewBuilder
    private func sun(_ days: [GroveSunlightDay]) -> some View {
        let average = days.reduce(0) { $0 + $1.fullSunHours } / Double(days.count)

        Button {
            Haptics.selection()
            withAnimation(GroveMotion.snap) { showsSunDetail.toggle() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sun.max.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(GroveTheme.gold)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(GroveSky.duration(average)) of full sun a day")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(GroveTheme.ink)
                    Text("Averaged over the last \(days.count) days")
                        .font(.caption)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
                Spacer(minLength: 8)
                if !showsSunDetail { sparkline(days) }
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(GroveTheme.subtleInk)
                    .rotationEffect(.degrees(showsSunDetail ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(GroveSky.duration(average)) of full sun a day, averaged over the last \(days.count) days")
        .accessibilityHint(showsSunDetail ? "Hides the daily chart" : "Shows the daily chart")

        if showsSunDetail {
            SunlightCard(locationLabel: location.label, days: days, embedded: true)
                .transition(.opacity.combined(with: .offset(y: -6)))
        }
    }

    /// A fortnight at thumbnail size: enough to see a run of grey days without
    /// spending the 300pt the real chart costs.
    private func sparkline(_ days: [GroveSunlightDay]) -> some View {
        let peak = max(1, days.map(\.fullSunHours).max() ?? 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(days) { day in
                Capsule()
                    .fill(GroveTheme.gold.opacity(day.isForecast ? 0.4 : 0.85))
                    .frame(width: 3, height: max(2, 22 * day.fullSunHours / peak))
            }
        }
        .frame(height: 22, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

// The card that used to stand in before a grove had a location is gone. It
// asked for the same thing as the header's location control, forty points of
// scrolling apart, and taught people to use the transient one. The ask now
// lives in `GroveHeaderLocation`, which is the control that owns this setting
// for good; its reasoning moved to the picker itself.
