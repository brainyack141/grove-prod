import SwiftUI

// MARK: - Status

/// What a plant's row is telling you, and how loudly.
///
/// Grove had six spellings of two facts. The same overdue check-in read
/// "Check-in overdue" on one screen, "OVERDUE" in tracked caps on another, and
/// "Health check-in" with a red day label on a third; a plant in trouble read
/// "Urgent · Review plant" here and "Needs attention" there. Worse, *sick* and
/// *late* were both `danger` red, so a dying plant and a photo nobody had taken
/// yet were the same colour on the same page.
///
/// This is the split. A tone is chosen from what the fact **is**, not from how
/// alarming it feels:
///
/// | Tone | Means | Colour |
/// | --- | --- | --- |
/// | `urgent` | the plant is in trouble | `danger` |
/// | `attention` | the plant needs a look | `healthAttention` |
/// | `late` | work Grove owes is overdue | `warning` |
/// | `due` | work is due today, and can be done now | `accentStrong` |
/// | `quiet` | work is coming, or the plant is paused | `mutedInk` |
/// | `steady` | nothing owed | `healthHealthy` |
///
/// Red therefore means *the plant*, and only the plant, anywhere in Grove.
/// Amber means *the calendar*. That is the whole vocabulary, and it is learnable
/// in one screen instead of inferred per screen.
enum GroveStatusTone: Equatable, Sendable {
    case urgent
    case attention
    case late
    case due
    case quiet
    case steady

    var tint: Color {
        switch self {
        case .urgent: GroveTheme.danger
        case .attention: GroveTheme.healthAttention
        case .late: GroveTheme.warning
        case .due: GroveTheme.accentStrong
        case .quiet: GroveTheme.mutedInk
        case .steady: GroveTheme.healthHealthy
        }
    }

    /// Only the three tones that are asking for something carry weight. A row
    /// where every status is semibold has no status at all.
    var isPressing: Bool {
        switch self {
        case .urgent, .attention, .late: true
        case .due, .quiet, .steady: false
        }
    }
}

/// One status, in sentence case, ready to be drawn.
struct GroveStatus: Equatable, Sendable {
    let tone: GroveStatusTone
    let text: String

    init(_ tone: GroveStatusTone, _ text: String) {
        self.tone = tone
        self.text = text
    }
}

// MARK: - Drawing

/// The status mark: a dot, nothing else.
///
/// Status used to arrive as an SF Symbol that changed per case — a triangle for
/// attention, a viewfinder for a check-in, a droplet for water — so the reader
/// had to decode a glyph before reading the sentence that said the same thing.
/// A dot carries the tone and gets out of the way, and because it is one shape
/// at one size every row in the app lines up on the same left edge.
struct GroveStatusDot: View {
    let tone: GroveStatusTone
    var diameter: CGFloat = 7

    var body: some View {
        Circle()
            .fill(tone.tint)
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
    }
}

/// The one way a status is written down: dot, then sentence.
struct GroveStatusLabel: View {
    let status: GroveStatus
    var lineLimit: Int? = 2

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if dynamicTypeSize.isAccessibilitySize && status.tone.isPressing {
                // At accessibility sizes a shape, not only a colour, separates
                // late from due today.
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(status.tone.tint)
                    .accessibilityHidden(true)
            } else {
                GroveStatusDot(tone: status.tone)
                    // Nudged onto the text's optical centre: a 7pt circle sitting on
                    // the first baseline hangs below the x-height it belongs to.
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            }
            Text(status.text)
                .font(.footnote.weight(status.tone.isPressing ? .semibold : .regular))
                .foregroundStyle(status.tone.tint)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.text)
    }
}

// MARK: - Row anatomy

/// The one shape a plant takes in a list, anywhere in Grove.
///
/// Before this, a plant appeared as a 52pt circle with a coloured ring on the
/// attention shelf, a 56pt rounded square on a care row, a 112×136 photo panel
/// in the library, and a 52pt rounded square in Ask's scope rail — four
/// anatomies for one object, on three screens the user moves between in a
/// single session. The thumbnail is now one size and one radius, the name is one
/// size, the status is one component, and the trailing slot is whatever this
/// particular list can do about it.
///
/// The trailing slot obeys the app's affordance rule: a chevron means the row
/// navigates, a pill means the row acts in place, and nothing means the row is
/// only telling you something.
struct PlantRow<Trailing: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let plant: Plant
    let status: GroveStatus
    /// A quiet second line, used only when it is news. Never a null value: a
    /// plant with no room says nothing rather than saying "Unassigned".
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    /// One thumbnail size for every plant row in the app.
    static var thumbnailSize: CGFloat { 56 }

    private var resolvedSubtitle: String? {
        guard let subtitle else { return nil }
        let trimmed = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        HStack(spacing: 12) {
            if !dynamicTypeSize.isAccessibilitySize {
                thumbnail
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(plant.nickname)
                    .font(.headline)
                    .foregroundStyle(GroveTheme.ink)
                    .lineLimit(1)
                if let resolvedSubtitle {
                    Text(resolvedSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .lineLimit(1)
                }
                GroveStatusLabel(status: status)
            }

            Spacer(minLength: 8)

            trailing()
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [plant.nickname, resolvedSubtitle, status.text]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }

    private var thumbnail: some View {
        PlantThumbnail(plant: plant, height: Self.thumbnailSize, maxDimension: 220)
            .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
            .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
    }
}

extension PlantRow where Trailing == GroveRowChevron {
    /// The navigating form: the row opens the plant.
    init(plant: Plant, status: GroveStatus, subtitle: String? = nil) {
        self.init(plant: plant, status: status, subtitle: subtitle) {
            GroveRowChevron()
        }
    }
}

/// The app's one "this row goes somewhere" mark.
///
/// Ask's suggestion rows used to use a diagonal `arrow.up.right`, which on every
/// other platform means *leaves this place* — a link out. Nothing in Grove
/// leaves. One chevron, one meaning.
struct GroveRowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(GroveTheme.subtleInk)
            .accessibilityHidden(true)
    }
}

// MARK: - Grouping

/// A hairline between two rows in a group, inset past the leading art so the
/// line starts where the reading does.
struct GroveRowDivider: View {
    /// Distance from the group's leading edge to where the text column begins.
    var inset: CGFloat = PlantRow<EmptyView>.thumbnailSize + 12

    var body: some View {
        Rectangle()
            .fill(GroveTheme.separator)
            .frame(height: 1)
            .padding(.leading, inset)
            .accessibilityHidden(true)
    }
}

/// One card holding a column of rows, rather than a column of cards.
///
/// A list of five plants drawn as five floating cards is five objects with five
/// shadows and five edges, and it reads as a stack of unrelated things. One card
/// with hairlines between its rows is the idiom every shipped iOS list uses, and
/// it is what makes a column scannable: the eye follows one left edge down
/// instead of re-entering a new container at every row.
struct GroveRowGroup<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, padding)
        .groveCard(padding: 0)
    }
}
