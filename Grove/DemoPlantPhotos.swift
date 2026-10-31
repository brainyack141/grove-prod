import UIKit

/// Real photographs for the demo grove's fixture plants (sources and licences
/// in PHOTO_CREDITS.md). The demo plants used to carry no photo at all, so
/// every surface drew the leaf placeholder over them. The photos are copied
/// once into Application Support so they travel the same file-URL path as a
/// gardener's own check-in photos, and `GroveMediaPath` can re-root them
/// after a reinstall.
enum DemoPlantPhotos {
    /// Asset name for each fixture plant, keyed by the fixture's fixed ID.
    private static let assetNames: [UUID: String] = [
        UUID(uuidString: "10000000-0000-0000-0000-000000000001")!: "DemoPlantMonstera",
        UUID(uuidString: "10000000-0000-0000-0000-000000000002")!: "DemoPlantBirdOfParadise",
        UUID(uuidString: "10000000-0000-0000-0000-000000000003")!: "DemoPlantSnakePlant",
        UUID(uuidString: "10000000-0000-0000-0000-000000000004")!: "DemoPlantStringOfPearls"
    ]

    /// The photo the simulator's "Use a sample photo" hands to the scan flow.
    static let sampleScanAssetName = "DemoPlantMonstera"

    /// A file URL for the plant's demo photo, written on first use; `nil`
    /// when the plant has no demo photo or the file could not be written, in
    /// which case the drawn portrait stands in as before.
    static func photoURL(for plantID: UUID) -> URL? {
        guard let name = assetNames[plantID],
              let base = FileManager.default
                  .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let directory = base.appendingPathComponent("Grove/DemoPhotos", isDirectory: true)
        let fileURL = directory.appendingPathComponent("\(name).jpg")
        if FileManager.default.fileExists(atPath: fileURL.path) { return fileURL }
        guard let data = UIImage(named: name)?.jpegData(compressionQuality: 0.85) else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }

    /// The sample scan photo, or `nil` if the asset is missing.
    static func sampleScanImage() -> UIImage? {
        UIImage(named: sampleScanAssetName)
    }
}
