import Foundation

/// TEMPORARY on-device diagnostic sink. Delete along with its call sites.
///
/// `devicectl --console` produced nothing for this app, so runtime facts are
/// appended to a file inside the container instead, where `devicectl device
/// copy from` can fetch them.
enum GroveDiag {
    private static let url: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("grove-diag.txt")
    }()

    static func log(_ message: String) {
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
