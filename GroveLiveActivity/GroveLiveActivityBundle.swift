import SwiftUI
import WidgetKit

/// Grove's Live Activities: the watering track and the plant-sitting handover.
/// Started, updated and ended by `GroveLiveActivityController` in the app; this
/// extension only draws them.
@main
struct GroveLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        GroveWateringLiveActivity()
        GroveSittingLiveActivity()
    }
}

// MARK: - Palette

/// The extension cannot see `GroveTheme`, so the handful of colours it needs
/// are restated here. They mirror GroveTheme's tokens (DesignSystem.swift) —
/// change them there first, then here.
enum LivePalette {
    /// GroveTheme.mapGround — the card's tint.
    static let night = Color(hex: 0x0C1510)
    /// GroveTheme.mapDue — anything that is due now.
    static let amber = Color(hex: 0xF0A81C)
    /// The approved design's water blue (no GroveTheme token yet) — the drying track.
    static let water = Color(hex: 0x5AA2FF)
    /// GroveTheme.mapThriving — the plant's initial tile.
    static let thriving = Color(hex: 0x34C27A)
    /// GroveTheme.purple, dark variant — the plant-sitting accent.
    static let sitter = Color(hex: 0xB49BEE)

    static let primary = Color.white
    static let secondary = Color.white.opacity(0.62)
    static let trackRest = Color.white.opacity(0.18)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Shared pieces

/// A 4pt track with a white disc riding on the fill, carrying a glyph.
struct LiveTrack: View {
    let fraction: Double
    let tint: Color
    let glyph: String

    private let disc: CGFloat = 30

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(fraction, 0), 1)
            let travel = max(proxy.size.width - disc, 0)
            ZStack(alignment: .leading) {
                Capsule().fill(LivePalette.trackRest).frame(height: 4)
                Capsule().fill(tint)
                    .frame(width: max(4, travel * clamped + disc / 2), height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: disc, height: disc)
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                    .overlay {
                        Image(systemName: glyph)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                    .offset(x: travel * clamped)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 34)
        .accessibilityHidden(true)
    }
}

/// An uppercase caption over a value — "WATERED / 24 Sep".
struct LiveStamp: View {
    let label: String
    let value: String
    var valueColor: Color = LivePalette.primary
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 5) {
            Text(label)
                .font(.caption2.weight(.medium))
                .tracking(0.55)
                .textCase(.uppercase)
                .foregroundStyle(LivePalette.secondary)
            Text(value)
                .font(.body.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(valueColor)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A plant's or a person's first letter in a filled tile.
struct LiveMonogram: View {
    let text: String
    let tint: Color
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(tint)
            .frame(width: size, height: size)
            .overlay {
                Text(text)
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
            }
            .accessibilityHidden(true)
    }
}

enum LiveFormat {
    /// "24 Sep"
    static func dayMonth(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// "Sun 5"
    static func weekdayDay(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day())
    }

    /// The dry estimate is a day, never a clock time — so it says the day:
    /// "Today", "Tomorrow", "Yesterday", or "Mon 29".
    static func relativeDay(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return weekdayDay(date)
    }

    static func initial(of name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? ""
    }

    /// "Monty", "Monty and Olive", "Monty, Olive and Fern"
    static func list(_ names: [String]) -> String {
        names.formatted(.list(type: .and))
    }
}
