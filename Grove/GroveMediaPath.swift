import Foundation

/// Resolves a stored photo path against the sandbox the app is running in *now*.
///
/// Photo references are persisted as absolute file URLs, and an iOS data
/// container is `/var/mobile/Containers/Data/Application/<UUID>/…` where the
/// UUID is reassigned on reinstall. The bytes survive — the container's contents
/// are carried across — but every stored path still names the old UUID, so
/// `FileManager` reports the photo missing and anything that guards on
/// existence silently falls back to its empty state. The Today hero showed a
/// gradient and a leaf glyph instead of the user's own plants; check-in
/// history, the living record, and scan history all lost their thumbnails the
/// same way.
///
/// Re-rooting the tail of the path onto the current Application Support
/// directory recovers the file without changing how anything is written.
enum GroveMediaPath {
    /// The stored URL when it still resolves, the re-rooted equivalent when the
    /// file moved with the container, otherwise `nil`.
    static func resolved(_ url: URL?) -> URL? {
        guard let url else { return nil }
        // Server-restored photos are signed https URLs — remote, and nothing to
        // re-root. Hand them back untouched.
        guard url.isFileURL else { return url }
        if FileManager.default.fileExists(atPath: url.path) { return url }
        return relocated(url)
    }

    /// The same file under the current container, or `nil` when the stored path
    /// carries no container-relative tail or the file is genuinely gone.
    ///
    /// Callers that repair persisted state use this rather than `resolved` so a
    /// URL they cannot account for is left alone instead of being erased.
    static func relocated(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let components = url.standardizedFileURL.pathComponents
        // Everything Grove writes lives under Application Support; the segment
        // before it is the part that changes between installs.
        guard let marker = components.lastIndex(of: "Application Support"),
              marker + 1 < components.count,
              let base = FileManager.default
                  .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let rebased = components[(marker + 1)...].reduce(base) { $0.appendingPathComponent($1) }
        guard rebased != url.standardizedFileURL,
              FileManager.default.fileExists(atPath: rebased.path) else { return nil }
        return rebased
    }
}
