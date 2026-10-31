import SwiftUI

/// Where the soil stands, on a scale that runs from scorched clay to standing
/// water.
///
/// `SoilMoistureRead` has been fully modelled since the pot-reading work — a
/// position, an uncertainty band, a verdict, and the prose to explain all
/// three — and until now nothing in the app drew any of it. The moisture tile in
/// the indicators grid shows a 0–100 health score, which is a different and
/// blunter number: it says how the soil is *doing*, not where it is in its
/// cycle. The one question someone opens this page to answer is whether to water
/// today, and nothing on the page answered it.
///
/// Two decisions carry the whole thing:
///
/// **The gradient is the axis, not decoration.** It runs through the plant's own
/// world — fired clay, dry dust, dry grass, leaf, deep green, shallow water,
/// deep water — so the colour under the needle *is* the reading. Every stop is
/// fixed rather than adaptive, because the scale sits in a dark well that lights
/// itself; a gradient that re-lit from the canvas would mean something different
/// after dark.
///
/// **The band is lit and the rest is dimmed.** A heart-rate monitor can put a
/// hairline at 109 BPM because it measured 109 BPM. Grove measured nothing: it
/// took a dated word about the soil and decayed it through a dry-down estimate,
/// and the whole page is built on never dressing that up as a reading. So the
/// needle carries a window of everywhere the soil could plausibly be, and the
/// window is narrow exactly when Grove has earned it — a pot it has seen, felt
/// this morning — and wide when it has not. An instrument that shows its own
/// doubt is the more precise instrument, not the less.
struct SoilMoistureGauge: View {
    let read: SoilMoistureRead

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The instrument coming up to its reading. One variable drives the needle
    /// and both edges of the band so they arrive together, the way a needle and
    /// its tolerance are one movement rather than two animations.
    @State private var sweep: Double = 0

    private static let barHeight: CGFloat = 26
    private static let barRadius: CGFloat = 9

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            verdict
            scale
            advice
            reasons
        }
        .onAppear {
            guard sweep == 0 else { return }
            if reduceMotion {
                sweep = 1
            } else {
                withAnimation(GroveMotion.reveal) { sweep = 1 }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Soil moisture")
        .accessibilityValue(read.accessibilitySummary)
    }

    // MARK: - What Grove thinks

    private var verdict: some View {
        VStack(alignment: .leading, spacing: 9) {
            GroveDisplayHeading(text: read.headline, style: .section)

            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(zoneLabel)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(zoneTint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(zoneTint.opacity(0.14), in: Capsule())
                    .fixedSize()

                if let qualifier {
                    Text(qualifier)
                        .font(.footnote)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The chip names where the needle is standing, which is not always what the
    /// verdict concludes: the verdict is taken from the whole band, so it can
    /// decline to call a reading whose best guess sits squarely in one zone.
    /// Showing both is the point of drawing a band.
    private var zoneLabel: String {
        read.verdict == .noReading ? "No reading" : read.zone.name
    }

    private var zoneTint: Color {
        guard read.verdict != .noReading else { return GroveTheme.subtleInk }
        return switch read.zone {
        case .dry: GroveTheme.warning
        case .drying: GroveTheme.accent
        case .damp: GroveTheme.hydration
        }
    }

    /// How much the reading is worth, and the dated fact it rests on. Silent
    /// when there is no such fact, because the headline already says so and a
    /// confidence phrase about nothing is worse than no phrase at all.
    private var qualifier: String? {
        guard let evidence = read.evidence else { return nil }
        let confidence = read.confidencePhrase
        return "\(confidence.prefix(1).uppercased())\(confidence.dropFirst()). \(evidence.phrase)."
    }

    // MARK: - The scale

    private var scale: some View {
        VStack(spacing: 10) {
            bar
            ticks
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Self.wellTop, Self.wellBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var bar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width

            ZStack(alignment: .leading) {
                // The full scale, held back. It stays visible end to end so the
                // reader can see what the band is a slice *of*.
                track.opacity(0.24)

                if read.verdict != .noReading {
                    track.mask { bandWindow }
                    thresholds(width: width)
                    needle(width: width)
                } else {
                    thresholds(width: width)
                }
            }
        }
        .frame(height: Self.barHeight)
    }

    private var track: some View {
        RoundedRectangle(cornerRadius: Self.barRadius, style: .continuous)
            .fill(LinearGradient(stops: Self.scaleStops, startPoint: .leading, endPoint: .trailing))
    }

    /// The lit slice: everywhere the soil could plausibly be. Feathered at both
    /// edges, because a hard-edged window would claim the band has boundaries
    /// as crisp as the needle, and it does not.
    private var bandWindow: some View {
        let low = min(1, max(0, read.bandLow * sweep))
        let high = min(1, max(low, read.bandHigh * sweep))
        let feather = 0.035

        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: CGFloat(max(0, low - feather))),
                .init(color: .white, location: CGFloat(low)),
                .init(color: .white, location: CGFloat(high)),
                .init(color: .clear, location: CGFloat(min(1, high + feather))),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Grove's single best guess, drawn as one hairline that overhangs the bar
    /// top and bottom so it reads as an instrument's marker rather than as a
    /// segment of the fill.
    private func needle(width: CGFloat) -> some View {
        let x = width * CGFloat(min(1, max(0, read.position * sweep)))
        return Capsule()
            .fill(Color.white.opacity(0.95))
            .frame(width: 3.5, height: Self.barHeight + 8)
            // The needle catches light; the bar behind it does not. This is the
            // one glow on the page and it is doing a legibility job, holding a
            // 3.5pt white line apart from a stop that may itself be pale.
            .shadow(color: .white.opacity(0.34), radius: 5)
            .position(x: min(width - 2, max(2, x)), y: Self.barHeight / 2)
    }

    /// The two lines that actually decide something: below `readyLine` Grove
    /// will say the soil is ready, above `holdingLine` it will say it is still
    /// holding water. No other graduations, because no other position on this
    /// scale changes what Grove says.
    private func thresholds(width: CGFloat) -> some View {
        ForEach([SoilMoistureRead.readyLine, SoilMoistureRead.holdingLine], id: \.self) { line in
            Rectangle()
                .fill(Color.white.opacity(0.26))
                .frame(width: 1, height: Self.barHeight - 12)
                .position(x: width * CGFloat(line), y: Self.barHeight / 2)
        }
    }

    @ViewBuilder
    private var ticks: some View {
        if dynamicTypeSize.isAccessibilitySize {
            // The middle label is anchored to a threshold a fifth of the way
            // along the bar. At accessibility sizes it cannot clear the one to
            // its left, so the ends carry the axis on their own.
            HStack(alignment: .firstTextBaseline) {
                tick("bone dry")
                Spacer(minLength: 10)
                tick("soaked")
            }
        } else {
            GeometryReader { proxy in
                ZStack {
                    tick("bone dry")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    tick("soaked")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    tick("ready")
                        .position(
                            x: proxy.size.width * CGFloat(SoilMoistureRead.readyLine),
                            y: proxy.size.height / 2
                        )
                }
            }
            .frame(height: 14)
        }
    }

    private func tick(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .tracking(0.3)
            .foregroundStyle(Color.white.opacity(0.52))
            .fixedSize()
    }

    // MARK: - What to do about it

    private var advice: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(read.action)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GroveTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            if let detail = read.actionDetail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var reasons: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What this estimate uses")
                .font(.caption.weight(.bold))
                .foregroundStyle(GroveTheme.subtleInk)
            ForEach(read.reasons) { reason in
                Label(reason.text, systemImage: reason.symbol)
                    .font(.caption)
                    .foregroundStyle(reason.isAlarming ? GroveTheme.warning : GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Colour

    /// The darkest green in Grove rather than a black box. `ink` is #1C261C, so
    /// the well is the same forest carried two steps further down: a panel set
    /// into the card, not a foreign surface dropped onto it.
    private static let wellTop = GroveTheme.fixed(0x1B2620)
    private static let wellBottom = GroveTheme.fixed(0x0F1613)

    /// Dry to wet, through the only materials this scale is ever about. Fired
    /// clay and dust at the parched end, dry grass through leaf across the
    /// middle where a plant is comfortable, then shallow and deep water.
    private static let scaleStops: [Gradient.Stop] = [
        .init(color: GroveTheme.fixed(0x8A2B04), location: 0.00),
        .init(color: GroveTheme.fixed(0xC55C0B), location: 0.12),
        .init(color: GroveTheme.fixed(0xEDAF2C), location: 0.25),
        .init(color: GroveTheme.fixed(0xBFC247), location: 0.34),
        .init(color: GroveTheme.fixed(0x5FA85C), location: 0.42),
        .init(color: GroveTheme.fixed(0x2FA57E), location: 0.58),
        .init(color: GroveTheme.fixed(0x3B93C6), location: 0.76),
        .init(color: GroveTheme.fixed(0x2A5EA6), location: 1.00),
    ]
}
