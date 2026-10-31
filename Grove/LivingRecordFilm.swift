import AVFoundation
import SwiftUI
import UIKit

/// The Living Record, as a file that can leave the app.
///
/// The scrubber in `LivingRecordHero` has been the best thing Grove makes for a
/// while, and until now it could only be experienced by holding the owner's
/// phone. A plant's six months is the one artifact here that a person would
/// actually want to show somebody, and it had no way out: no share sheet, no
/// export, nothing. That is the difference between a feature and a reason
/// somebody else installs the app.
///
/// So the record renders to a short film — the same frames, in the same order,
/// with the date and reading burned into each one so the thing still makes
/// sense with no app around it. Deliberately a video rather than a stacked
/// still: the whole point of the record is the *change*, and a grid of nine
/// thumbnails is a contact sheet, not a growth.
enum LivingRecordFilm {

    // MARK: - Shape of the film

    private enum Reel {
        /// 4:5. The most forgiving portrait crop across the places these get
        /// posted, and close enough to the phone's own aspect that a check-in
        /// photo rarely loses anything that mattered.
        static let size = CGSize(width: 1080, height: 1350)
        static let fps: Int32 = 30
        /// Frames of video per check-in. Fast enough that a year of monthly
        /// check-ins is a few seconds, slow enough to read the date.
        static let holdFrames = 11
        /// The last frame is the payoff, so it stays up long enough to look at.
        static let finalHoldFrames = 46
    }

    enum FilmError: Error {
        case notEnoughFrames
        case noImages
        case writerFailed(String)
    }

    // MARK: - Rendering

    /// Renders the record to an mp4 in the caches directory and hands back its
    /// URL. Long-running and image-heavy, so callers should show progress.
    static func render(
        plantName: String,
        frames: [LivingRecordFrame]
    ) async throws -> URL {
        guard frames.count >= 2 else { throw FilmError.notEnoughFrames }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("grove-record-\(UUID().uuidString).mp4")

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(Reel.size.width),
                AVVideoHeightKey: Int(Reel.size.height)
            ]
        )
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: Int(Reel.size.width),
                kCVPixelBufferHeightKey as String: Int(Reel.size.height)
            ]
        )

        guard writer.canAdd(input) else {
            throw FilmError.writerFailed("The writer refused the video input")
        }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let first = frames.first?.date
        var presented: Int64 = 0
        var wroteAnything = false

        for (index, frame) in frames.enumerated() {
            try Task.checkCancellation()

            guard let resolved = GroveMediaPath.resolved(frame.photoURL),
                  let photo = await GroveImageLoader.downsampledImage(
                      at: resolved,
                      maxDimension: Reel.size.height
                  )
            else { continue }

            let canvas = compose(
                photo: photo,
                frame: frame,
                plantName: plantName,
                index: index,
                total: frames.count,
                since: first
            )
            guard let buffer = pixelBuffer(from: canvas) else { continue }

            let holds = index == frames.count - 1 ? Reel.finalHoldFrames : Reel.holdFrames
            for _ in 0..<holds {
                await waitUntilReady(input)
                adaptor.append(buffer, withPresentationTime: CMTime(value: presented, timescale: Reel.fps))
                presented += 1
            }
            wroteAnything = true
        }

        guard wroteAnything else {
            input.markAsFinished()
            writer.cancelWriting()
            throw FilmError.noImages
        }

        input.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw FilmError.writerFailed(
                writer.error?.localizedDescription ?? "The film could not be written"
            )
        }
        return output
    }

    /// `isReadyForMoreMediaData` is the only backpressure the writer offers, and
    /// spinning on it would peg a core for the length of the export.
    private static func waitUntilReady(_ input: AVAssetWriterInput) async {
        while !input.isReadyForMoreMediaData {
            try? await Task.sleep(for: .milliseconds(8))
        }
    }

    // MARK: - One frame

    /// The photograph, filled to the reel, with the day's reading over it.
    ///
    /// Everything burned in here is chosen so the film stands alone once it has
    /// left Grove: what plant, which day, how far into the record, and how the
    /// reading was moving. Without the date in particular a growth time-lapse is
    /// just a plant that gets bigger for no stated reason.
    private static func compose(
        photo: UIImage,
        frame: LivingRecordFrame,
        plantName: String,
        index: Int,
        total: Int,
        since: Date?
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: Reel.size, format: format).image { context in
            let cg = context.cgContext

            UIColor(GroveTheme.inkOnLight).setFill()
            cg.fill(CGRect(origin: .zero, size: Reel.size))

            draw(photo: photo, filling: CGRect(origin: .zero, size: Reel.size))

            // Legibility scrims. The bottom one carries the readout; the top
            // one only has to hold a name and a counter.
            drawScrim(in: cg, from: 0, to: 0.26, topDown: true, strength: 0.55)
            drawScrim(in: cg, from: 0.62, to: 1, topDown: false, strength: 0.78)

            let margin: CGFloat = 68

            draw(
                plantName,
                at: CGPoint(x: margin, y: 66),
                font: .systemFont(ofSize: 40, weight: .bold),
                color: .white
            )
            let counter = "\(index + 1) of \(total)"
            let counterFont = UIFont.systemFont(ofSize: 30, weight: .semibold)
            let counterWidth = counter.size(withAttributes: [.font: counterFont]).width
            draw(
                counter,
                at: CGPoint(x: Reel.size.width - margin - counterWidth, y: 74),
                font: counterFont,
                color: UIColor.white.withAlphaComponent(0.75)
            )

            let dateLine = frame.date.formatted(
                .dateTime.day().month(.wide).year()
            ).uppercased()
            draw(
                dateLine,
                at: CGPoint(x: margin, y: Reel.size.height - 268),
                font: .systemFont(ofSize: 30, weight: .heavy),
                color: UIColor.white.withAlphaComponent(0.88),
                tracking: 3
            )

            draw(
                "\(frame.score)",
                at: CGPoint(x: margin, y: Reel.size.height - 224),
                font: .systemFont(ofSize: 128, weight: .bold),
                color: .white
            )

            let delta = frame.score - frame.previousScore
            if delta != 0, index > 0 {
                let sign = delta > 0 ? "+" : "−"
                draw(
                    "\(sign)\(abs(delta))",
                    at: CGPoint(x: margin + 196, y: Reel.size.height - 156),
                    font: .systemFont(ofSize: 44, weight: .bold),
                    color: UIColor(delta > 0 ? GroveTheme.onPhotoImproving : GroveTheme.onPhotoDeclining)
                )
            }

            if let since, index > 0 {
                let days = Calendar.current.dateComponents(
                    [.day],
                    from: Calendar.current.startOfDay(for: since),
                    to: Calendar.current.startOfDay(for: frame.date)
                ).day ?? 0
                if days > 0 {
                    draw(
                        days == 1 ? "Day 1" : "Day \(days)",
                        at: CGPoint(x: margin, y: Reel.size.height - 78),
                        font: .systemFont(ofSize: 30, weight: .semibold),
                        color: UIColor.white.withAlphaComponent(0.75)
                    )
                }
            }

            if frame.hasNewGrowth {
                let tag = "New growth"
                let tagFont = UIFont.systemFont(ofSize: 28, weight: .bold)
                let width = tag.size(withAttributes: [.font: tagFont]).width + 44
                let rect = CGRect(
                    x: Reel.size.width - margin - width,
                    y: Reel.size.height - 232,
                    width: width,
                    height: 56
                )
                UIColor(GroveTheme.accent).withAlphaComponent(0.92).setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: 28).fill()
                draw(
                    tag,
                    at: CGPoint(x: rect.minX + 22, y: rect.minY + 12),
                    font: tagFont,
                    color: .white
                )
            }
        }
    }

    private static func draw(photo: UIImage, filling rect: CGRect) {
        let size = photo.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let scaled = CGSize(width: size.width * scale, height: size.height * scale)
        photo.draw(in: CGRect(
            x: rect.midX - scaled.width / 2,
            y: rect.midY - scaled.height / 2,
            width: scaled.width,
            height: scaled.height
        ))
    }

    private static func drawScrim(
        in context: CGContext,
        from start: CGFloat,
        to end: CGFloat,
        topDown: Bool,
        strength: CGFloat
    ) {
        let colors = [
            UIColor.black.withAlphaComponent(topDown ? strength : 0).cgColor,
            UIColor.black.withAlphaComponent(topDown ? 0 : strength).cgColor
        ]
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: [0, 1]
        ) else { return }

        context.saveGState()
        context.clip(to: CGRect(
            x: 0,
            y: Reel.size.height * start,
            width: Reel.size.width,
            height: Reel.size.height * (end - start)
        ))
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: Reel.size.height * start),
            end: CGPoint(x: 0, y: Reel.size.height * end),
            options: []
        )
        context.restoreGState()
    }

    private static func draw(
        _ text: String,
        at point: CGPoint,
        font: UIFont,
        color: UIColor,
        tracking: CGFloat = 0
    ) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        if tracking != 0 { attributes[.kern] = tracking }
        (text as NSString).draw(at: point, withAttributes: attributes)
    }

    // MARK: - Pixel buffers

    private static func pixelBuffer(from image: UIImage) -> CVPixelBuffer? {
        guard let cgImage = image.cgImage else { return nil }

        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(Reel.size.width),
            Int(Reel.size.height),
            kCVPixelFormatType_32ARGB,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(Reel.size.width),
            height: Int(Reel.size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(origin: .zero, size: Reel.size))
        return buffer
    }
}
