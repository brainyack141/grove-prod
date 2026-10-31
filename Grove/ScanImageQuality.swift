import CoreGraphics
import UIKit

enum ScanImageQualityWarning: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case lowLight
    case overexposed
    case softFocus
    case lowContrast
    case possibleObstruction

    var id: String { rawValue }

    var guidance: String {
        switch self {
        case .lowLight: "Add more even light and avoid using flash directly on the leaves."
        case .overexposed: "Move away from glare or direct sun so leaf colour and texture remain visible."
        case .softFocus: "Hold steady, tap the plant to focus, and move closer instead of zooming."
        case .lowContrast: "Use a simpler background so the plant outline is easier to distinguish."
        case .possibleObstruction: "Check that the lens is clean and not covered by a finger or case."
        }
    }
}

struct ScanImageQualityReport: Equatable, Sendable {
    let warnings: [ScanImageQualityWarning]
    let blockingMessage: String?
    let meanLuminance: Double
    let luminanceDeviation: Double
    let darkPixelRatio: Double
    let brightPixelRatio: Double
    let edgeStrength: Double

    var isAcceptable: Bool { blockingMessage == nil }
}

enum ScanImageQualityAnalyzer {
    private static let maximumSampleDimension = 160

    static func assess(_ image: UIImage) -> ScanImageQualityReport {
        guard let sample = grayscaleSample(from: image), !sample.pixels.isEmpty else {
            return ScanImageQualityReport(
                warnings: [],
                blockingMessage: "Grove couldn't read this photo. Take it again, or pick another one.",
                meanLuminance: 0,
                luminanceDeviation: 0,
                darkPixelRatio: 0,
                brightPixelRatio: 0,
                edgeStrength: 0
            )
        }

        let count = Double(sample.pixels.count)
        let mean = sample.pixels.reduce(0.0) { $0 + Double($1) } / count
        let variance = sample.pixels.reduce(0.0) {
            let difference = Double($1) - mean
            return $0 + difference * difference
        } / count
        let deviation = variance.squareRoot()
        let darkRatio = Double(sample.pixels.count(where: { $0 < 18 })) / count
        let brightRatio = Double(sample.pixels.count(where: { $0 > 242 })) / count
        let edgeStrength = averageLaplacianMagnitude(
            pixels: sample.pixels,
            width: sample.width,
            height: sample.height
        )

        let blockingMessage: String?
        if mean < 7 || darkRatio > 0.985 {
            blockingMessage = "That photo is almost completely dark or the lens is covered. Add light and check the lens before trying again."
        } else if mean > 248 || brightRatio > 0.985 {
            blockingMessage = "That photo is almost completely white. Move away from glare or direct light and try again."
        } else if deviation < 2.5 {
            blockingMessage = "That photo does not contain enough visible detail. Put the plant in frame and try again."
        } else {
            blockingMessage = nil
        }

        var warnings: [ScanImageQualityWarning] = []
        if mean < 55 || darkRatio > 0.45 { warnings.append(.lowLight) }
        if mean > 205 || brightRatio > 0.35 { warnings.append(.overexposed) }
        if edgeStrength < 4.5 { warnings.append(.softFocus) }
        if deviation < 22 { warnings.append(.lowContrast) }
        if darkRatio > 0.82 || brightRatio > 0.82 { warnings.append(.possibleObstruction) }

        return ScanImageQualityReport(
            warnings: warnings,
            blockingMessage: blockingMessage,
            meanLuminance: mean,
            luminanceDeviation: deviation,
            darkPixelRatio: darkRatio,
            brightPixelRatio: brightRatio,
            edgeStrength: edgeStrength
        )
    }

    private static func grayscaleSample(from image: UIImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let source = image.cgImage else { return nil }
        let longestDimension = max(source.width, source.height)
        guard longestDimension > 0 else { return nil }
        let scale = CGFloat(maximumSampleDimension) / CGFloat(longestDimension)
        let width = max(1, Int((CGFloat(source.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(source.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? (pixels, width, height) : nil
    }

    private static func averageLaplacianMagnitude(pixels: [UInt8], width: Int, height: Int) -> Double {
        guard width > 2, height > 2 else { return 0 }
        var total = 0.0
        var samples = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                let centre = Int(pixels[index]) * 4
                let neighbours = Int(pixels[index - 1])
                    + Int(pixels[index + 1])
                    + Int(pixels[index - width])
                    + Int(pixels[index + width])
                total += Double(abs(centre - neighbours))
                samples += 1
            }
        }
        return samples == 0 ? 0 : total / Double(samples)
    }
}
