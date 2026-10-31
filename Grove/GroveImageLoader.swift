import Foundation
import ImageIO
import UIKit

/// Loads plant photography wherever it lives: the protected local files this
/// device captured (the common case), or the time-limited signed Storage URLs
/// a server bootstrap restores onto a new device.
///
/// Downsampling happens off the main actor in both paths so scrolling stays
/// smooth; remote fetches ride the shared URLCache, which is enough reuse for
/// signed URLs that rotate on every bootstrap anyway.
enum GroveImageLoader {
    /// Decoded thumbnails, so a grid of plant cards decodes each photo once
    /// rather than on every pass through a lazy grid's reuse. Keyed by URL and
    /// size, because the same photo is asked for at card, hero and avatar
    /// scales. The cache empties itself under memory pressure.
    /// `nonisolated(unsafe)` because `NSCache` is documented as thread-safe:
    /// it does its own locking, so the loader's detached decodes can share it.
    private nonisolated(unsafe) static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        return cache
    }()

    static func downsampledImage(at url: URL, maxDimension: CGFloat = 1200) async -> UIImage? {
        let key = "\(url.absoluteString)|\(Int(maxDimension.rounded()))" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let image: UIImage?
        if url.isFileURL {
            image = await Task.detached(priority: .utility) {
                downsampledImage(fileURL: url, maxDimension: maxDimension)
            }.value
        } else if let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) {
            image = await Task.detached(priority: .utility) {
                downsampledImage(data: data, maxDimension: maxDimension)
            }.value
        } else {
            image = nil
        }

        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    private nonisolated static func downsampledImage(fileURL: URL, maxDimension: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions) else { return nil }
        return thumbnail(from: source, maxDimension: maxDimension)
    }

    private nonisolated static func downsampledImage(data: Data, maxDimension: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return thumbnail(from: source, maxDimension: maxDimension)
    }

    private nonisolated static func thumbnail(from source: CGImageSource, maxDimension: CGFloat) -> UIImage? {
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// A bounded cache of decoded thumbnails, for photography that is drawn over
/// and over rather than once.
///
/// A `LazyVGrid` tears its cards down and rebuilds them on every scroll pass.
/// Without this, a grove of plant photos re-reads and re-decodes a JPEG per
/// card per pass — which is exactly what makes a photo grid stutter.
///
/// Main-actor rather than an `NSCache`: the only callers are SwiftUI views
/// already on the main actor, and a plain dictionary keeps the eviction rule
/// visible instead of leaving it to the system's memory pressure heuristics.
@MainActor
enum GroveThumbnailCache {
    private struct Key: Hashable {
        let url: URL
        let maxDimension: Int
    }

    private static var images: [Key: UIImage] = [:]
    /// Insertion order, oldest first. Eviction by age rather than by access:
    /// a grove is small enough that the cache never thrashes, so the extra
    /// bookkeeping of a true LRU would buy nothing.
    private static var keys: [Key] = []
    private static let limit = 180

    static func thumbnail(at url: URL, maxDimension: CGFloat) async -> UIImage? {
        let key = Key(url: url, maxDimension: Int(maxDimension))
        if let cached = images[key] { return cached }
        guard let image = await GroveImageLoader.downsampledImage(at: url, maxDimension: maxDimension) else {
            return nil
        }
        // Two cards can ask for the same photo at once; only the first insert
        // records the key, so eviction can never drop an image that a later
        // duplicate key still claims to own.
        if images.updateValue(image, forKey: key) == nil {
            keys.append(key)
            if keys.count > limit {
                images.removeValue(forKey: keys.removeFirst())
            }
        }
        return image
    }

    /// Drops every cached image. Called when photo files are deleted, so the
    /// memory a departed plant's photography held is released with it rather
    /// than sitting in the cache until enough scrolling evicts it.
    static func clear() {
        images.removeAll()
        keys.removeAll()
    }
}
