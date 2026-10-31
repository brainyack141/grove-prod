import Photos
import SwiftUI
import UIKit

/// A share composer for one plant's living record.
///
/// The exported image is a 4:5 social card rather than a screenshot of this
/// sheet. Type and health data stay native and current; ImageGen supplies only
/// the tactile botanical ground, so a changed nickname or score can never be
/// trapped in a raster asset.
struct PlantShareSheet: View {
    @Environment(GroveStore.self) private var store
    @Environment(GroveToastCenter.self) private var toasts: GroveToastCenter?
    @Environment(\.dismiss) private var dismiss

    let plant: Plant

    @State private var photo: UIImage?
    @State private var exportImage: UIImage?
    @State private var isPreparing = true
    @State private var isSaving = false
    @State private var didCopy = false
    @State private var didSave = false
    @State private var saveError: String?

    private static let cardSize = CGSize(width: 432, height: 540)
    private static let exportScale: CGFloat = 2.5

    /// "Meet Monty, my Monstera." The species is left out when it would only
    /// repeat the nickname or is the unknown-plant stand-in, and the status
    /// says "it" so the name isn't said twice in a row.
    private var shareText: String {
        let species = plant.species.trimmingCharacters(in: .whitespacesAndNewlines)
        let namesSpecies = !PlantIdentityState.isPlaceholderName(species)
            && species.caseInsensitiveCompare(plant.nickname) != .orderedSame
        let intro = namesSpecies ? "Meet \(plant.nickname), my \(species)." : "Meet \(plant.nickname)."
        if plant.hasHealthReading {
            return "\(intro) \(PlantShareCopy.status(for: plant, subject: "It")) "
                + "Its health score is \(plant.healthScore) out of 100 in Grove."
        }
        return "\(intro) \(PlantShareCopy.status(for: plant, subject: "It"))"
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 22) {
                    preview

                    if isPreparing {
                        Label("Preparing your share image", systemImage: "leaf.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(GroveTheme.mutedInk)
                            .transition(.opacity)
                    }

                    actions

                    Button { dismiss() } label: {
                        GroveOutlineLabel(title: "Close", systemImage: "xmark")
                    }
                    .buttonStyle(GrovePressStyle())
                }
                .padding(.horizontal, GroveTheme.pagePadding)
                .padding(.bottom, GroveTheme.pageBottomPadding)
            }
        }
        .background(GroveTheme.background)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .task(id: plant) { await prepareShareImage() }
        .alert(
            "Couldn’t save image",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "The image didn't save to Photos. Try again.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                GroveDisplayHeading(text: "Share \(plant.nickname)", style: .section)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text("A polished card made from the latest record")
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
            }

            Spacer(minLength: 8)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(GroveTheme.mutedInk)
                    .frame(width: 38, height: 38)
                    .background(GroveTheme.secondarySurface, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(GroveTilePressStyle())
            .accessibilityLabel("Close share sheet")
        }
        .padding(.horizontal, GroveTheme.pagePadding)
        .padding(.top, 18)
        .padding(.bottom, 20)
    }

    /// The preview and export share one 432 × 540 layout. The sheet scales that
    /// layout down, while ImageRenderer gives the same points 2.5 pixels each
    /// for an exact 1080 × 1350 output.
    private var preview: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / Self.cardSize.width
            PlantShareCard(plant: plant, photo: photo)
                .frame(width: Self.cardSize.width, height: Self.cardSize.height)
                .scaleEffect(scale, anchor: .topLeading)
        }
        .aspectRatio(Self.cardSize.width / Self.cardSize.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: GroveTheme.heroRadius, style: .continuous))
        .groveEdgeLight(radius: GroveTheme.heroRadius)
        .groveShadow(.hero)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Share card preview for \(plant.nickname). \(PlantShareCopy.status(for: plant))")
    }

    private var actions: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: copyText) {
                PlantShareActionLabel(
                    title: didCopy ? "Copied" : "Copy text",
                    symbol: didCopy ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(GroveTilePressStyle())

            Button {
                Task { await saveImage() }
            } label: {
                PlantShareActionLabel(
                    title: didSave ? "Saved" : "Save",
                    symbol: didSave ? "checkmark" : "arrow.down.to.line",
                    isWorking: isSaving
                )
            }
            .buttonStyle(GroveTilePressStyle())
            .disabled(exportImage == nil || isSaving)

            if let exportImage {
                ShareLink(
                    item: Image(uiImage: exportImage),
                    subject: Text("How \(plant.nickname) is doing"),
                    message: Text(shareText),
                    preview: SharePreview(
                        plant.nickname,
                        image: Image(uiImage: exportImage)
                    )
                ) {
                    PlantShareActionLabel(title: "Other", symbol: "ellipsis")
                }
                .buttonStyle(GroveTilePressStyle())
                .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
            } else {
                PlantShareActionLabel(title: "Other", symbol: "ellipsis", isWorking: true)
                    .opacity(0.45)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @MainActor
    private func prepareShareImage() async {
        isPreparing = true
        photo = nil

        if let photoURL = store.latestPhotoURL(for: plant.id),
           let resolvedURL = photoURL.isFileURL ? GroveMediaPath.resolved(photoURL) : photoURL {
            photo = await GroveThumbnailCache.thumbnail(at: resolvedURL, maxDimension: 1_600)
        }

        let content = PlantShareCard(plant: plant, photo: photo)
            .frame(width: Self.cardSize.width, height: Self.cardSize.height)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(Self.cardSize)
        renderer.scale = Self.exportScale
        renderer.isOpaque = true
        exportImage = renderer.uiImage
        isPreparing = false
    }

    private func copyText() {
        UIPasteboard.general.string = shareText
        didCopy = true
        Haptics.complete()
        toasts?.show("Copied \(plant.nickname)’s update", symbol: "doc.on.doc.fill")
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
    }

    @MainActor
    private func saveImage() async {
        guard let data = exportImage?.pngData() else { return }
        isSaving = true
        defer { isSaving = false }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            saveError = "Allow Grove to add photos in Settings, then try again."
            Haptics.warning()
            return
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = "grove-\(plant.id.uuidString.lowercased()).png"
                request.addResource(with: .photo, data: data, options: options)
            }
            didSave = true
            Haptics.complete()
            toasts?.show("Saved \(plant.nickname)’s share card", symbol: "photo.badge.checkmark")
            Task {
                try? await Task.sleep(for: .seconds(2))
                didSave = false
            }
        } catch {
            saveError = "The image didn't save to Photos. Try again."
            Haptics.error()
        }
    }
}

/// The actual exported artwork. It deliberately owns a fixed canvas: social
/// image dimensions are content, not device layout, and should not change when
/// the sheet appears on an iPad or under larger Dynamic Type.
private struct PlantShareCard: View {
    let plant: Plant
    let photo: UIImage?

    var body: some View {
        ZStack {
            Image("PlantShareBackdrop")
                .resizable()
                .scaledToFill()

            LinearGradient(
                colors: [.black.opacity(0.38), .clear, .black.opacity(0.12)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 16) {
                brand
                portrait
                caption
            }
            .padding(24)
        }
        .frame(width: 432, height: 540)
        .clipped()
    }

    private var brand: some View {
        HStack(spacing: 9) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(GroveTheme.inkOnLight)
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.88), in: Circle())

            Text("GROVE")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .tracking(2.2)
                .foregroundStyle(.white)

            Spacer()

            Text(Date.now.formatted(.dateTime.month(.abbreviated).day().year()))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(height: 30)
    }

    private var portrait: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                } else {
                    PlantPortrait(plant: plant, height: 308)
                }
            }
            .frame(width: 384, height: 308)
            .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.52)],
                startPoint: .center,
                endPoint: .bottom
            )

            HStack(spacing: 7) {
                Circle()
                    .fill(plant.hasHealthReading ? plant.healthBand.onPhotoColor : Color.white.opacity(0.7))
                    .frame(width: 8, height: 8)
                Text(plant.hasHealthReading ? plant.healthBand.shortTitle : "No reading yet")
                if plant.hasHealthReading {
                    Text("·")
                        .foregroundStyle(.white.opacity(0.65))
                    Label(plant.trend.title, systemImage: plant.trend.icon)
                }
            }
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(.black.opacity(0.4), in: Capsule())
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.62), lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.24), radius: 14, y: 8)
    }

    private var caption: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plant.nickname)
                    .font(.system(size: 29, weight: .bold, design: .rounded))
                    .foregroundStyle(GroveTheme.inkOnLight)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(plant.species)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .italic()
                    .foregroundStyle(GroveTheme.inkOnLight.opacity(0.68))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            VStack(spacing: 0) {
                Text(plant.hasHealthReading ? "\(plant.healthScore)" : "New")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(GroveTheme.inkOnLight)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(plant.hasHealthReading ? "HEALTH" : "No reading yet")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(GroveTheme.inkOnLight.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(width: 66, height: 66)
            .background(.white.opacity(0.6), in: Circle())
            .overlay {
                Circle().strokeBorder(
                    (plant.hasHealthReading ? plant.healthBand.color : GroveTheme.mutedInk).opacity(0.55),
                    lineWidth: 2
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.86), in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            Text("A living record, grown with Grove")
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(GroveTheme.inkOnLight.opacity(0.55))
                .padding(.leading, 16)
                .padding(.bottom, 7)
        }
    }
}

private struct PlantShareActionLabel: View {
    let title: String
    let symbol: String
    var isWorking = false

    var body: some View {
        VStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(GroveTheme.secondarySurface)
                    .frame(width: 62, height: 62)
                if isWorking {
                    ProgressView()
                        .tint(GroveTheme.ink)
                } else {
                    Image(systemName: symbol)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(GroveTheme.ink)
                }
            }
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(GroveTheme.mutedInk)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private enum PlantShareCopy {
    /// `subject` replaces the name when the sentence before has just said it.
    static func status(for plant: Plant, subject: String? = nil) -> String {
        let name = subject ?? plant.nickname
        guard plant.hasHealthReading else {
            return "\(name) has no health reading yet."
        }
        switch plant.healthBand {
        case .thriving:
            return "\(name) is thriving."
        case .healthy:
            return "\(name) is looking healthy."
        case .monitor:
            return "I’m keeping an eye on \(subject?.lowercased() ?? plant.nickname)."
        case .attention:
            return "\(name) needs a little attention."
        case .urgent:
            return "\(name) needs care now."
        }
    }
}
