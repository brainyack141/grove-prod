#!/usr/bin/env swift
//
//  generate-brand-mark.swift
//
//  Derives `GroveBrandMark` from `GroveBrandIcon`.
//
//  The brand icon is an app-icon *tile*: the sculpted `g` sitting on its own
//  warm beige ground with a soft drop shadow, exactly right on a home screen.
//  In a navigation bar that tile becomes a sticker — its beige (#EADAC0) is
//  warmer than the app canvas (#F4EDDF), so the mark arrives wearing a faintly
//  visible square.
//
//  This script keys that ground out: every pixel is measured against the tile's
//  background colour, pixels close to it become transparent, the shadow goes
//  with them, and the surviving edge pixels are un-matted so no beige fringe is
//  left behind. The result is cropped to the mark itself, so a caller sizing the
//  image sizes the `g` rather than the padding around it.
//
//  Run after changing the app icon:
//      swift scripts/generate-brand-mark.swift
//
import AppKit

// MARK: - Paths

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = repoRoot.appendingPathComponent("Grove/Assets.xcassets")
let source = assets.appendingPathComponent("GroveBrandIcon.imageset/GroveBrandIcon@3x.png")
let destination = assets.appendingPathComponent("GroveBrandMark.imageset")

// MARK: - Keying constants

/// The drop shadow is the ground colour darkened, so it cannot be separated by
/// brightness alone without also eating the glyph's own dark edges. It *can* be
/// separated by hue: shadow and ground point the same direction in RGB, and the
/// green mark does not. These two bound the ramp on that angular distance
/// (measured as the gap between unit colour vectors, scaled to 0…255).
let groundHueDistance = 8.0
let markHueDistance = 26.0
/// A hue test alone would drop a highlight that happens to be neutral, so a
/// pixel far enough from the ground in plain brightness is kept regardless. The
/// floor sits above the darkest shadow pixel (~66) so the shadow stays out.
let groundValueDistance = 95.0
let markValueDistance = 150.0
/// Bleed left around the mark when cropping, in source pixels.
let bleed = 3

// MARK: - Read

guard let image = NSImage(contentsOf: source),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Could not read \(source.path)")
}

let width = cg.width
let height = cg.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
guard let readContext = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("Could not build a read context") }
readContext.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

// MARK: - Ground colour

/// The tile's ground, taken as the most common colour rather than a constant:
/// the icon can be re-exported with a slightly different beige and this keeps
/// working.
let ground: (r: Double, g: Double, b: Double) = {
    var counts: [UInt32: Int] = [:]
    for i in stride(from: 0, to: pixels.count, by: 4) {
        let key = UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2])
        counts[key, default: 0] += 1
    }
    guard let key = counts.max(by: { $0.value < $1.value })?.key else {
        fatalError("Empty image")
    }
    return (Double((key >> 16) & 0xFF), Double((key >> 8) & 0xFF), Double(key & 0xFF))
}()

/// The ground as a unit vector: shadow pixels are the same vector, shorter.
let groundUnit: (r: Double, g: Double, b: Double) = {
    let length = (ground.r * ground.r + ground.g * ground.g + ground.b * ground.b).squareRoot()
    return (ground.r / length, ground.g / length, ground.b / length)
}()

/// 0 below `low`, 1 above `high`, linear between — the ramp is what keeps the
/// keyed curves smooth instead of stair-stepped.
func ramp(_ value: Double, _ low: Double, _ high: Double) -> Double {
    min(max((value - low) / (high - low), 0), 1)
}

// MARK: - Key out the ground

var keyed = [UInt8](repeating: 0, count: width * height * 4)
var minX = width, minY = height, maxX = -1, maxY = -1

for y in 0..<height {
    for x in 0..<width {
        let i = (y * width + x) * 4
        let r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])

        let dr = r - ground.r, dg = g - ground.g, db = b - ground.b
        let valueDistance = (dr * dr + dg * dg + db * db).squareRoot()

        let length = (r * r + g * g + b * b).squareRoot()
        let hueDistance: Double
        if length < 1 {
            hueDistance = .greatestFiniteMagnitude  // pure black is never the ground
        } else {
            let hr = r / length - groundUnit.r
            let hg = g / length - groundUnit.g
            let hb = b / length - groundUnit.b
            hueDistance = (hr * hr + hg * hg + hb * hb).squareRoot() * 255
        }

        let alpha = max(
            ramp(hueDistance, groundHueDistance, markHueDistance),
            ramp(valueDistance, groundValueDistance, markValueDistance)
        )
        guard alpha > 0 else { continue }

        // Un-matte: the pixel we have is the mark composited over the ground, so
        // recover the mark's own colour before re-compositing it somewhere else.
        // Without this every edge carries a beige halo onto the cream canvas.
        func unmatte(_ value: Double, _ groundValue: Double) -> UInt8 {
            let recovered = (value - groundValue * (1 - alpha)) / alpha
            return UInt8(min(max(recovered, 0), 255).rounded())
        }

        // Stored premultiplied, which is what CGContext expects on the way back in.
        keyed[i] = UInt8((Double(unmatte(r, ground.r)) * alpha).rounded())
        keyed[i + 1] = UInt8((Double(unmatte(g, ground.g)) * alpha).rounded())
        keyed[i + 2] = UInt8((Double(unmatte(b, ground.b)) * alpha).rounded())
        keyed[i + 3] = UInt8((alpha * 255).rounded())

        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}

guard maxX >= minX, maxY >= minY else { fatalError("Nothing survived the key") }

let cropX = max(0, minX - bleed)
let cropY = max(0, minY - bleed)
let cropMaxX = min(width - 1, maxX + bleed)
let cropMaxY = min(height - 1, maxY + bleed)
let cropWidth = cropMaxX - cropX + 1
let cropHeight = cropMaxY - cropY + 1

guard let keyedContext = CGContext(
    data: &keyed,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
), let keyedImage = keyedContext.makeImage(),
   let cropped = keyedImage.cropping(to: CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)) else {
    fatalError("Could not crop the keyed mark")
}

// MARK: - Write the imageset

try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func write(_ image: CGImage, scale: Int, to url: URL) {
    let targetWidth = Int((Double(cropWidth) * Double(scale) / 3).rounded())
    let targetHeight = Int((Double(cropHeight) * Double(scale) / 3).rounded())
    guard let context = CGContext(
        data: nil,
        width: targetWidth,
        height: targetHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Could not build a write context") }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    guard let scaled = context.makeImage() else { fatalError("Could not scale the mark") }
    let bitmap = NSBitmapImageRep(cgImage: scaled)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode PNG")
    }
    try! data.write(to: url)
    print("wrote \(url.lastPathComponent) — \(targetWidth)×\(targetHeight)")
}

for scale in 1...3 {
    let name = scale == 1 ? "GroveBrandMark.png" : "GroveBrandMark@\(scale)x.png"
    write(cropped, scale: scale, to: destination.appendingPathComponent(name))
}

let contents = """
{
  "images" : [
    {
      "filename" : "GroveBrandMark.png",
      "idiom" : "universal",
      "scale" : "1x"
    },
    {
      "filename" : "GroveBrandMark@2x.png",
      "idiom" : "universal",
      "scale" : "2x"
    },
    {
      "filename" : "GroveBrandMark@3x.png",
      "idiom" : "universal",
      "scale" : "3x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(to: destination.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("mark cropped to \(cropWidth)×\(cropHeight) of \(width)×\(height)")
