import ActivityKit
import SwiftUI
import WidgetKit

/// "Hannah is plant-sitting" — an owner's active handover: how much of the
/// care the sitter has done, from the day it started to the day they are home.
struct GroveSittingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GroveSittingActivityAttributes.self) { context in
            SittingLockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(LivePalette.night.opacity(0.72))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let attributes = context.attributes
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    SitterAvatar(attributes: attributes, size: 40)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SittingCountText(state: state, style: .title3)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(SittingCopy.title(attributes))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LivePalette.primary)
                            .lineLimit(1)
                        Text(SittingCopy.subtitle(state))
                            .font(.footnote)
                            .foregroundStyle(LivePalette.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SittingTrack(attributes: attributes, state: state)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                SitterAvatar(attributes: attributes, size: 24)
            } compactTrailing: {
                SittingCountText(state: state, style: .footnote)
            } minimal: {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(LivePalette.sitter)
            }
            .keylineTint(LivePalette.sitter)
        }
    }
}

private struct SittingLockScreenView: View {
    let attributes: GroveSittingActivityAttributes
    let state: GroveSittingActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                SitterAvatar(attributes: attributes, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(SittingCopy.title(attributes))
                        .font(.headline)
                        .foregroundStyle(LivePalette.primary)
                        .lineLimit(1)
                    Text(SittingCopy.subtitle(state))
                        .font(.subheadline)
                        .foregroundStyle(LivePalette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                SittingCountText(state: state, style: .title2)
            }
            .accessibilityElement(children: .combine)
            SittingTrack(attributes: attributes, state: state)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

private struct SittingTrack: View {
    let attributes: GroveSittingActivityAttributes
    let state: GroveSittingActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 8) {
            LiveTrack(fraction: SittingCopy.fraction(state), tint: LivePalette.sitter, glyph: "checkmark")
            HStack(alignment: .bottom) {
                LiveStamp(label: "Since", value: LiveFormat.weekdayDay(attributes.startDate))
                Spacer()
                LiveStamp(label: "Home", value: LiveFormat.weekdayDay(attributes.endDate), alignment: .trailing)
            }
        }
    }
}

private struct SitterAvatar: View {
    let attributes: GroveSittingActivityAttributes
    let size: CGFloat

    var body: some View {
        let initials = attributes.sitterInitials.isEmpty
            ? LiveFormat.initial(of: attributes.sitterName)
            : attributes.sitterInitials
        LiveMonogram(text: initials, tint: LivePalette.sitter, size: size, cornerRadius: size / 2)
    }
}

/// "2/3". Hidden when the handover carries no tasks, rather than printing "0/0".
private struct SittingCountText: View {
    let state: GroveSittingActivityAttributes.ContentState
    /// A text style, not a point size, so the count scales with Dynamic Type.
    let style: Font.TextStyle

    var body: some View {
        if state.totalTasks > 0 {
            Text("\(state.completedTasks)/\(state.totalTasks)")
                .font(.system(style, weight: .bold))
                .tracking(-0.3)
                .monospacedDigit()
                .foregroundStyle(LivePalette.primary)
                .lineLimit(1)
                .accessibilityLabel("\(state.completedTasks) of \(state.totalTasks) done")
        }
    }
}

enum SittingCopy {
    static func title(_ attributes: GroveSittingActivityAttributes) -> String {
        "\(attributes.sitterName) is plant-sitting"
    }

    static func subtitle(_ state: GroveSittingActivityAttributes.ContentState) -> String {
        if !state.recentPlantNames.isEmpty {
            return "Cared for \(LiveFormat.list(state.recentPlantNames))"
        }
        return state.completedTasks > 0 ? "Care is being logged" : "Nothing logged yet"
    }

    static func fraction(_ state: GroveSittingActivityAttributes.ContentState) -> Double {
        guard state.totalTasks > 0 else { return 0 }
        return Double(state.completedTasks) / Double(state.totalTasks)
    }
}

#Preview(
    "Lock Screen",
    as: .content,
    using: GroveSittingActivityAttributes(
        assignmentID: "preview",
        sitterName: "Hannah",
        sitterInitials: "H",
        startDate: .now.addingTimeInterval(-4 * 86_400),
        endDate: .now.addingTimeInterval(3 * 86_400)
    )
) {
    GroveSittingLiveActivity()
} contentStates: {
    GroveSittingActivityAttributes.ContentState(completedTasks: 2, totalTasks: 3, recentPlantNames: ["Monty", "Olive"])
}
