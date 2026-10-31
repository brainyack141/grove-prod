import SwiftUI
import UIKit

// MARK: - Capture board
//
// The camera, scan result and check-in screens read as one family with Today's
// departures board: dark glass chips and a single white shutter on the camera,
// then a white sheet over the photo carrying small caps over large values.
// Everything here is presentation only; the pipelines own the data.

// MARK: Camera chrome

/// A circular dark glass control for camera surfaces (close, flash, flip).
struct CaptureGlassChip: View {
    let systemImage: String
    var tint: Color = .white

    var body: some View {
        Image(systemName: systemImage)
            .font(.body.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: Circle())
            .background(Color.white.opacity(0.08), in: Circle())
            .environment(\.colorScheme, .dark)
            .contentShape(Circle())
    }
}

/// The single white shutter: an 80pt ring around a solid disc that closes a
/// little while a capture is in flight, the way a real shutter does.
struct CaptureShutterLabel: View {
    var isBusy = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.white, lineWidth: 4)
                .frame(width: 80, height: 80)
            Circle()
                .fill(.white)
                .frame(width: isBusy ? 50 : 62, height: isBusy ? 50 : 62)
            if isBusy {
                ProgressView().tint(.black)
            }
        }
        .animation(GroveMotion.press, value: isBusy)
    }
}

/// A short live sentence above the controls, led by a status dot.
struct CaptureHintCapsule: View {
    let text: String
    var dot: Color = GroveTheme.mapThriving

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dot)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 36)
        .background(.black.opacity(0.5), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// The scan camera's hint, driven by the live frame reading. White while
/// searching, amber when there is something to fix, green once the frame will
/// land.
struct CaptureLiveHint: View {
    let model: LiveScanModel
    let idleInstruction: String

    private var line: String {
        switch model.phase {
        case .searching:
            return idleInstruction
        case .sighted:
            if let hint = model.hint { return hint.line }
            return "Hold it there…"
        case .locked:
            if let label = model.friendlyLabel {
                return "Looks like \(label). Take the photo"
            }
            return "Plant in frame. Take the photo"
        }
    }

    private var dot: Color {
        switch model.phase {
        case .searching: .white.opacity(0.55)
        case .sighted: model.hint == nil ? .white : GroveTheme.mapDue
        case .locked: GroveTheme.mapThriving
        }
    }

    var body: some View {
        CaptureHintCapsule(text: line, dot: dot)
            .animation(GroveMotion.snap, value: model.phase)
            .accessibilityLabel(line)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Camera-style text segments: the selected mode in white with a small green
/// dot beneath it, the others dimmed. Falls back to a horizontal scroll when
/// large text would not fit across the screen.
struct CaptureModeSwitcher: View {
    let modes: [ScanMode]
    let selected: ScanMode?
    var isInteractive = true
    var identifierPrefix = "scanMode"
    let onSelect: (ScanMode) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 26) { segments }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) { segments }
                    .padding(.horizontal, 20)
            }
        }
    }

    private var segments: some View {
        ForEach(modes) { mode in
            segment(mode)
        }
    }

    private func segment(_ mode: ScanMode) -> some View {
        let isSelected = mode == selected
        return Button {
            guard isInteractive, !isSelected else { return }
            onSelect(mode)
        } label: {
            VStack(spacing: 7) {
                Text(mode.title)
                    .font(.subheadline.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.6))
                    .lineLimit(1)
                    .fixedSize()
                Circle()
                    .fill(isSelected ? GroveTheme.mapThriving : Color.clear)
                    .frame(width: 5, height: 5)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isInteractive)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("\(identifierPrefix).\(mode.rawValue)")
    }
}

/// Segmented progress for a multi-step capture.
struct CaptureStepCapsules: View {
    let total: Int
    /// How many segments are lit, counting from the first.
    let lit: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<max(total, 1), id: \.self) { index in
                Capsule()
                    .fill(index < lit ? Color.white : Color.white.opacity(0.3))
                    .frame(height: 4)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The square photo tile at the left of the shutter row.
struct CapturePhotoTile: View {
    let image: UIImage

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.7), lineWidth: 1.5)
            }
    }
}

/// The library button in the same 50pt slot, for when there is no photo to show.
struct CaptureLibraryTile: View {
    var body: some View {
        Image(systemName: "photo.on.rectangle")
            .font(.title3.weight(.medium))
            .foregroundStyle(.white)
            .frame(width: 50, height: 50)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.7), lineWidth: 1.5)
            }
    }
}

/// The dark wash that carries the camera controls.
struct CaptureBottomScrim: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0), location: 0),
                .init(color: .black.opacity(0.86), location: 0.4),
                .init(color: .black.opacity(0.86), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
    }
}

// MARK: Result sheet

/// The white sheet that rises over a full-bleed photo.
struct CaptureSheetModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                UnevenRoundedRectangle(
                    topLeadingRadius: GroveTheme.heroRadius,
                    topTrailingRadius: GroveTheme.heroRadius,
                    style: .continuous
                )
                .fill(GroveTheme.background)
                .shadow(color: GroveTheme.shadow, radius: 15, y: -8)
            }
    }
}

extension View {
    func captureSheet() -> some View {
        modifier(CaptureSheetModifier())
    }
}

/// A status dot in its own halo, then a short tabular line ("94% match").
struct CaptureStatusLine: View {
    let text: String
    var tint: Color = GroveTheme.healthThriving

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.17))
                    .frame(width: 22, height: 22)
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(GroveTheme.surface, lineWidth: 2.5))
            }
            .accessibilityHidden(true)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
    }
}

/// One fact for a stat grid.
struct CaptureStat: Identifiable {
    let label: String
    let value: String
    var tint: Color = GroveTheme.ink
    var trend: HealthTrend? = nil

    var id: String { label }
}

/// Two columns of `GroveStatCell`s, stacking to one column at accessibility
/// text sizes so nothing truncates.
struct CaptureStatGrid: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let stats: [CaptureStat]
    var large = false

    private var rows: [[CaptureStat]] {
        stride(from: 0, to: stats.count, by: 2).map { start in
            Array(stats[start..<min(start + 2, stats.count)])
        }
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(stats) { stat in
                    cell(stat)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(rows.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(rows[index]) { stat in
                            cell(stat)
                        }
                        if rows[index].count == 1 {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                        }
                    }
                }
            }
        }
    }

    private func cell(_ stat: CaptureStat) -> some View {
        GroveStatCell(label: stat.label, value: stat.value, tint: stat.tint, trend: stat.trend, large: large)
    }
}

/// A white card with a hairline border and a section heading.
struct CaptureCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
                .strokeBorder(GroveTheme.separator, lineWidth: 1)
        }
    }
}

/// The night-green card for Grove's own voice: a forecast or Ari's read.
struct CaptureDarkCard<Content: View>: View {
    var eyebrow: String? = nil
    let content: Content

    init(eyebrow: String? = nil, @ViewBuilder content: () -> Content) {
        self.eyebrow = eyebrow
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let eyebrow {
                Text(eyebrow.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(GroveTheme.mapCaption)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .groveAriSurface()
    }
}

/// One row of a list inside a `CaptureCard`: name over italic detail, with a
/// tabular figure at the trailing edge.
struct CaptureListRow: View {
    let title: String
    var detail: String? = nil
    let trailing: String
    var isLast = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(GroveTheme.ink)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline.italic())
                        .foregroundStyle(GroveTheme.mutedInk)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(trailing)
                .font(.body.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(GroveTheme.subtleInk)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(GroveTheme.separator).frame(height: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A Was / Now row for a change Grove just made.
struct CaptureChangeRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let was: String
    let now: String
    var nowTint: Color = GroveTheme.healthThriving
    var isLast = false

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        layout {
            Text(title)
                .font(.body)
                .foregroundStyle(GroveTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            GroveStatCell(label: "Was", value: was)
            GroveStatCell(label: "Now", value: now, tint: nowTint)
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(GroveTheme.separator).frame(height: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). Was \(was). Now \(now).")
    }
}

/// A photo loaded from Grove's media store, filling its frame.
struct CaptureStoredPhoto: View {
    let url: URL?
    var maxDimension: CGFloat = 1200

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            GroveTheme.mapGround
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            image = nil
            guard let resolved = GroveMediaPath.resolved(url) else { return }
            let loaded = await GroveThumbnailCache.thumbnail(at: resolved, maxDimension: maxDimension)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { image = loaded }
        }
    }
}

/// A small capsule laid over a photo ("23 Sep", "Today").
struct CapturePhotoTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.black.opacity(0.45), in: Capsule())
    }
}
