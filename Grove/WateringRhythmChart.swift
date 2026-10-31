import SwiftUI

/// How often this plant actually gets watered — one bar per gap, in days.
///
/// Deliberately the plainest chart on the page, because it is the only one that
/// is plainly true. No band, no forecast, no tint that shifts with a judgement:
/// a bar is a number of days the owner can count on their fingers, and the line
/// across it is the middle of their own history.
///
/// It reads left to right as time, and the rightmost bar is the gap that ended
/// with the most recent watering. The dry-down estimate lives further up the
/// page and is allowed to guess; this one is not.
struct WateringRhythmChart: View {
    let rhythm: WateringRhythm
    let nickname: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var grow: CGFloat = 0

    /// The tallest bar the axis is drawn against.
    ///
    /// Anchored to the longest real gap plus a little headroom, never to the
    /// typical gap: clipping the holiday everybody remembers would quietly make
    /// the chart disagree with the owner's memory of it.
    private var scaleMax: Int {
        let longest = rhythm.intervals.map(\.days).max() ?? 1
        return max(longest + 1, (rhythm.typicalDays ?? 1) + 2)
    }

    /// The last dozen gaps. Beyond that the bars are too thin to read a height
    /// from, and a rhythm older than a year is a different plant in a different
    /// pot anyway.
    private var visible: [WateringRhythm.Interval] {
        Array(rhythm.intervals.suffix(12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            bars
            footer
        }
        .onAppear {
            guard grow == 0 else { return }
            if reduceMotion {
                grow = 1
            } else {
                withAnimation(GroveMotion.reveal) { grow = 1 }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            GroveEyebrow(text: "How often you water")
            Spacer(minLength: 8)
            if let days = rhythm.typicalDays {
                Text(days == 1 ? "about every day" : "about every \(days) days")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(GroveTheme.hydration)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Bars

    private var bars: some View {
        HStack(alignment: .bottom, spacing: barSpacing) {
            ForEach(visible) { interval in
                bar(for: interval)
            }
        }
        .frame(height: chartHeight, alignment: .bottom)
        .background(alignment: .bottom) { typicalLine }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Days between waterings")
        .accessibilityValue(accessibilitySummary)
    }

    private var barSpacing: CGFloat { visible.count > 8 ? 5 : 7 }
    private var chartHeight: CGFloat { dynamicTypeSize.isAccessibilitySize ? 148 : 116 }

    private func bar(for interval: WateringRhythm.Interval) -> some View {
        let share = CGFloat(interval.days) / CGFloat(scaleMax)
        return VStack(spacing: 6) {
            // The number sits on top of its own bar rather than on an axis.
            // A y-axis would need gridlines and a legend to say the same thing,
            // and there are never more than a dozen bars to label.
            Text("\(interval.days)")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(GroveTheme.mutedInk)
                .opacity(grow)

            GeometryReader { proxy in
                let full = proxy.size.height
                let height = max(4, full * share * grow)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(interval.isApproximate ? Color.clear : GroveTheme.hydration.opacity(0.85))
                    .overlay {
                        // Hollow when the gap rests on a reminder date rather
                        // than a record. Same rule the rest of the page follows:
                        // an estimate may be shown, never dressed as a reading.
                        if interval.isApproximate {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(GroveTheme.hydration.opacity(0.55), lineWidth: 1.5)
                        }
                    }
                    .frame(height: height)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    /// The median, drawn across the bars so each one reads as "longer or shorter
    /// than usual" without the reader doing any arithmetic.
    @ViewBuilder
    private var typicalLine: some View {
        if let typical = rhythm.typicalDays, typical > 0 {
            GeometryReader { proxy in
                let share = CGFloat(typical) / CGFloat(scaleMax)
                Rectangle()
                    .fill(GroveTheme.hydration.opacity(0.32))
                    .frame(height: 1)
                    .offset(y: proxy.size.height * (1 - share))
                    .opacity(grow)
            }
            .accessibilityHidden(true)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(Self.monthLabel(visible.first?.endedAt))
                Spacer(minLength: 8)
                Text(sinceLabel)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(GroveTheme.subtleInk)
            .lineLimit(1)
            .minimumScaleFactor(0.8)

            if let note = driftNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if rhythm.hasApproximateIntervals {
                Text("Hollow bars are older waterings dated by their reminder, so those gaps are approximate.")
                    .font(.caption2)
                    .foregroundStyle(GroveTheme.subtleInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Where the owner is in the current gap, which is the one the chart cannot
    /// draw yet because it has not ended.
    private var sinceLabel: String {
        guard let since = rhythm.daysSinceLast else { return "" }
        switch since {
        case 0: return "watered today"
        case 1: return "1 day since"
        default: return "\(since) days since"
        }
    }

    /// One sentence, only when the history genuinely supports it.
    private var driftNote: String? {
        let name = nickname.isEmpty ? "This one" : nickname
        switch rhythm.drift {
        case .steady:
            return nil
        case let .slowing(from, to):
            return "\(name) has been going longer between drinks lately: about \(to) days, up from \(from). That usually follows the light getting shorter."
        case let .quickening(from, to):
            return "\(name) is drinking faster than it was: about \(to) days between waterings, down from \(from). Longer days, or roots that have filled the pot."
        }
    }

    private static func monthLabel(_ date: Date?) -> String {
        guard let date else { return "" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    private var accessibilitySummary: String {
        let gaps = visible.map { "\($0.days)" }.joined(separator: ", ")
        var summary = "\(visible.count) gaps between waterings, in days: \(gaps)."
        if let typical = rhythm.typicalDays {
            summary += typical == 1 ? " Typically 1 day." : " Typically \(typical) days."
        }
        if let since = rhythm.daysSinceLast {
            let sinceLine = switch since {
            case 0: " Watered today."
            case 1: " 1 day since the last watering."
            default: " \(since) days since the last watering."
            }
            summary += sinceLine
        }
        if let note = driftNote {
            summary += " \(note)"
        }
        return summary
    }
}
