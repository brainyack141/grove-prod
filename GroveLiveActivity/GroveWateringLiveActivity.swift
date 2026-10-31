import ActivityKit
import SwiftUI
import WidgetKit

/// "Monty · soil check": the soil drying from the last watering towards the
/// day the owner's own rhythm says it is usually dry. Never "water today":
/// nothing has felt the soil, so the most a Lock Screen can ask is a check.
struct GroveWateringLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GroveWateringActivityAttributes.self) { context in
            WateringLockScreenView(state: context.state)
                .activityBackgroundTint(LivePalette.night.opacity(0.72))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LiveMonogram(text: LiveFormat.initial(of: state.plantName), tint: LivePalette.thriving, size: 40)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    WateringDueText(state: state, style: .title3)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(WateringCopy.title(state))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LivePalette.primary)
                            .lineLimit(1)
                        Text(WateringCopy.subtitle(state))
                            .font(.footnote)
                            .foregroundStyle(LivePalette.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    WateringTrack(state: state)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                // The plant's initial when it has a name to give, the drop when
                // it does not — never an empty circle.
                let initial = LiveFormat.initial(of: state.plantName)
                if initial.isEmpty {
                    Image(systemName: "drop.fill").foregroundStyle(LivePalette.water)
                } else {
                    LiveMonogram(text: initial, tint: LivePalette.thriving, size: 24, cornerRadius: 12)
                }
            } compactTrailing: {
                WateringDueText(state: state, style: .footnote)
            } minimal: {
                Image(systemName: state.isDone ? "checkmark" : "drop.fill")
                    .foregroundStyle(state.isDone ? LivePalette.thriving : LivePalette.water)
            }
            .keylineTint(LivePalette.water)
        }
    }
}

// MARK: - Lock Screen

private struct WateringLockScreenView: View {
    let state: GroveWateringActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                LiveMonogram(text: LiveFormat.initial(of: state.plantName), tint: LivePalette.thriving)
                VStack(alignment: .leading, spacing: 3) {
                    Text(WateringCopy.title(state))
                        .font(.headline)
                        .foregroundStyle(LivePalette.primary)
                        .lineLimit(1)
                    Text(WateringCopy.subtitle(state))
                        .font(.subheadline)
                        .foregroundStyle(LivePalette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                WateringDueText(state: state, style: .title2)
            }
            .accessibilityElement(children: .combine)
            WateringTrack(state: state)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

// MARK: - Pieces

private struct WateringTrack: View {
    let state: GroveWateringActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 8) {
            LiveTrack(
                fraction: state.isDone ? 0 : WateringCopy.fraction(state),
                tint: LivePalette.water,
                glyph: "drop.fill"
            )
            HStack(alignment: .bottom) {
                LiveStamp(label: "Watered", value: state.isDone ? "Today" : LiveFormat.dayMonth(state.wateredAt))
                Spacer()
                LiveStamp(
                    label: "Usually dry",
                    value: state.isDone ? WateringCopy.inDays(state.typicalDays) : LiveFormat.relativeDay(state.dryAt),
                    valueColor: state.isDone ? LivePalette.primary : LivePalette.amber,
                    alignment: .trailing
                )
            }
        }
    }
}

/// The amber "when". A day, not a clock time: the rhythm is counted in days,
/// and printing "6 pm" would claim a precision Grove does not have. Sized by
/// text style so the Lock Screen honours Dynamic Type.
private struct WateringDueText: View {
    let state: GroveWateringActivityAttributes.ContentState
    let style: Font.TextStyle

    var body: some View {
        Group {
            if state.isDone {
                Image(systemName: "checkmark")
                    .font(.system(style, weight: .bold))
                    .foregroundStyle(LivePalette.thriving)
                    .accessibilityLabel("Watered")
            } else {
                Text(LiveFormat.relativeDay(state.dryAt))
                    .font(.system(style, weight: .bold))
                    .tracking(-0.3)
                    .monospacedDigit()
                    .foregroundStyle(LivePalette.amber)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel("Usually dry \(LiveFormat.relativeDay(state.dryAt).lowercased())")
            }
        }
    }
}

enum WateringCopy {
    static func title(_ state: GroveWateringActivityAttributes.ContentState) -> String {
        state.isDone ? "\(state.plantName) · watered" : "\(state.plantName) · soil check"
    }

    static func subtitle(_ state: GroveWateringActivityAttributes.ContentState) -> String {
        let days = state.typicalDays
        if state.isDone {
            return days == 1 ? "Next check tomorrow" : "Next check in about \(days) days"
        }
        // The title already asks for the check; this is the owner's rhythm.
        return days == 1 ? "You usually water daily" : "You usually water every \(days) days"
    }

    /// "Tomorrow" or "In 4 days", never "In 1 days".
    static func inDays(_ days: Int) -> String {
        days == 1 ? "Tomorrow" : "In \(days) days"
    }

    /// How far through the owner's usual interval the soil is. Read against the
    /// clock at render time; the system redraws the activity often enough for a
    /// track that moves by a day's width at a time.
    static func fraction(_ state: GroveWateringActivityAttributes.ContentState, now: Date = .now) -> Double {
        let span = state.dryAt.timeIntervalSince(state.wateredAt)
        guard span > 0 else { return 1 }
        return now.timeIntervalSince(state.wateredAt) / span
    }
}

#Preview("Lock Screen", as: .content, using: GroveWateringActivityAttributes(plantID: "preview")) {
    GroveWateringLiveActivity()
} contentStates: {
    GroveWateringActivityAttributes.ContentState(
        plantName: "Monty",
        wateredAt: .now.addingTimeInterval(-7 * 86_400),
        dryAt: .now.addingTimeInterval(3_600),
        typicalDays: 8
    )
}
