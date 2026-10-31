// Renders every `GroveEmptyScene` into a contact sheet PNG so the artwork can
// be judged as a set rather than one screen at a time.
//
//   scripts/preview-empty-art.sh
//
// Output lands in build/empty-art/ (gitignored) — light and dark, side by side.
//
// This compiles Grove/GroveEmptyArt.swift on macOS against the small
// GroveTheme/GroveMotion stub next to this file. The preview view loads the
// source PNGs directly because a standalone swiftc binary has no asset
// catalogue bundle.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct PreviewEmptyArt {
    @MainActor
    static func main() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let outputDirectory = root.appending(path: "build/empty-art")

        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            for (name, isDark) in [("light", false), ("dark", true)] {
                let url = outputDirectory.appending(path: "empty-art-\(name).png")
                try render(isDark: isDark, to: url)
                print("wrote \(url.path)")
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func render(isDark: Bool, to url: URL) throws {
        GrovePreviewAppearance.isDark = isDark

        let renderer = ImageRenderer(content: ContactSheet())
        renderer.scale = 2
        guard let cgImage = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }

        try png.write(to: url)
    }
}

private struct ContactSheet: View {
    private let columns = Array(repeating: GridItem(.fixed(180), spacing: 0), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(Array(GroveEmptyScene.allCases.enumerated()), id: \.offset) { _, scene in
                VStack(spacing: 6) {
                    PreviewEmptySceneArt(scene: scene, size: 132)
                    Text(String(describing: scene))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(GroveTheme.mutedInk)
                }
                .frame(width: 180, height: 176)
            }
        }
        .padding(24)
        .frame(width: 768)
        .background(GroveTheme.background)
    }
}

/// macOS contact-sheet counterpart to `GroveEmptyArt`. It uses the same scene
/// metadata and live ring while resolving the source artwork directly from
/// each imageset.
private struct PreviewEmptySceneArt: View {
    let scene: GroveEmptyScene
    let size: CGFloat

    private var scale: CGFloat { size / 100 }

    var body: some View {
        ZStack {
            GroveEmptyRing(closed: scene.ringIsClosed)
                .stroke(
                    GroveTheme.accent.opacity(scene.ringIsClosed ? 0.38 : 0.28),
                    style: StrokeStyle(
                        lineWidth: 3.2 * scale,
                        lineCap: .round,
                        dash: scene.ringIsDashed ? [7 * scale, 6 * scale] : []
                    )
                )

            if let radius = scene.seedRadius {
                Circle()
                    .fill(GroveTheme.accent.opacity(0.5))
                    .frame(width: 6.2 * scale, height: 6.2 * scale)
                    .offset(
                        x: radius * cos(GroveEmptyRing.gapBearing) * scale,
                        y: radius * sin(GroveEmptyRing.gapBearing) * scale
                    )
            }

            if let image = sourceImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(
                        width: size * scene.artworkFrameFraction,
                        height: size * scene.artworkFrameFraction
                    )
            }
        }
        .frame(width: size, height: size)
    }

    private var sourceImage: NSImage? {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let imageset = repositoryRoot
            .appending(path: "Grove/Assets.xcassets")
            .appending(path: "\(scene.artworkName).imageset")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: imageset,
            includingPropertiesForKeys: nil
        ) else { return nil }

        let rasterFiles = files.filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
        let preferred = rasterFiles.first { $0.lastPathComponent.contains("@3x") }
            ?? rasterFiles.first
        return preferred.flatMap(NSImage.init(contentsOf:))
    }
}
