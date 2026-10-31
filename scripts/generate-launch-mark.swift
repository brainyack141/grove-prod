#!/usr/bin/env swift
//
//  generate-launch-mark.swift
//
//  Derives `LaunchMark` — the mark the launch screen shows — from the 1024pt
//  app icon.
//
//  The splash and the home screen show the same object: the sculpted `g`. Taking
//  it from `AppIcon.appiconset` rather than redrawing it means a re-exported icon
//  is the *only* place the logo lives, and the launch screen cannot drift away
//  from the icon the user tapped a moment earlier.
//
//  The icon is a tile — the mark sitting on warm beige with a drop shadow — so
//  this keys that ground out the same way `generate-brand-mark.swift` does:
//  pixels near the ground colour go transparent, the shadow goes with them, and
//  surviving edge pixels are un-matted so no beige fringe rides along onto the
//  launch screen's cream. The result is cropped to the glyph and written at the
//  exact point size the storyboard and `GroveLaunchView` both pin it to.
//
//  Run after changing the app icon or `markHeight`:
//      scripts/generate-launch-mark.sh
//
import AppKit

// MARK: - Paths

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = repoRoot.appendingPathComponent("Grove/Assets.xcassets")
let source = assets.appendingPathComponent("AppIcon.appiconset/AppIcon-1024-v2.png")
let destination = assets.appendingPathComponent("LaunchMark.imageset")

/// The mark's rendered height in points. The storyboard and `GroveLaunchView`
/// both state this number; changing it here means changing it in both.
let markHeight = 132.0

// MARK: - Keying constants

/// The drop shadow is the ground colour darkened, so it cannot be separated by
/// brightness alone without also eating the glyph's own dark edges. It *can* be
/// separated by hue: shadow and ground point the same direction in RGB, and the
/// green mark does not. These two bound the ramp on that angular distance
/// (measured as the gap between unit colour vectors, scaled to 0…255).
let groundHueDistance = 8.0
let markHueDistance = 26.0
/// A hue test alone would drop a highlight that happens to be neutral, so a
/// pixel far enough from the ground in plain brightness is kept regardless.
let groundValueDistance = 95.0
let markValueDistance = 150.0
/// Bleed left around the mark when cropping, in source pixels.
let bleed = 12

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

/// The tile's ground, taken as the most common colour rather than a constant, so
/// a re-exported icon with a slightly different beige keeps working. The icon
/// carries a faint paper grain, so the single most common value is a point in a
/// cloud rather than a flat field — the ramp below is what absorbs the spread.
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

var alphas = [Double](repeating: 0, count: width * height)
var keyed = [UInt8](repeating: 0, count: width * height * 4)

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

        alphas[y * width + x] = max(
            ramp(hueDistance, groundHueDistance, markHueDistance),
            ramp(valueDistance, groundValueDistance, markValueDistance)
        )
    }
}

/// The grain leaves a dusting of faintly-surviving pixels across the tile. They
/// are invisible against beige and would be invisible against cream too, but
/// they sit anywhere on the tile — including its corners — so left in they would
/// blow the crop out to the full 1024 and shrink the mark to a stamp inside it.
/// A pixel only counts as mark if it is opaque enough to be part of the glyph.
let cropThreshold = 0.35
var minX = width, minY = height, maxX = -1, maxY = -1
for y in 0..<height {
    for x in 0..<width where alphas[y * width + x] >= cropThreshold {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX >= minX, maxY >= minY else { fatalError("Nothing survived the key") }

/// Below this the pixel is grain, not glyph: clear it outright rather than
/// carrying a haze of near-transparent beige-flecked pixels into the asset.
let grainFloor = 0.06
for y in 0..<height {
    for x in 0..<width {
        let index = y * width + x
        let alpha = alphas[index]
        guard alpha > grainFloor else { continue }

        let i = index * 4
        let r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])

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
    }
}

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

/// 1x is the mark's point size exactly, so the storyboard — which pins the image
/// view to these numbers — and `GroveLaunchView` agree by construction.
let markWidth = (markHeight * Double(cropWidth) / Double(cropHeight)).rounded()

try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func write(_ image: CGImage, scale: Int, to url: URL) {
    let targetWidth = Int(markWidth * Double(scale))
    let targetHeight = Int(markHeight * Double(scale))
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
    let name = scale == 1 ? "LaunchMark.png" : "LaunchMark@\(scale)x.png"
    write(cropped, scale: scale, to: destination.appendingPathComponent(name))
}

let contents = """
{
  "images" : [
    {
      "filename" : "LaunchMark.png",
      "idiom" : "universal",
      "scale" : "1x"
    },
    {
      "filename" : "LaunchMark@2x.png",
      "idiom" : "universal",
      "scale" : "2x"
    },
    {
      "filename" : "LaunchMark@3x.png",
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
print("point size: \(Int(markWidth))×\(Int(markHeight)) — put these in LaunchScreen.storyboard and GroveLaunchView")
