import CryptoKit
import Foundation

enum AccountStorage {
    static func namespace(for accountID: String) -> String {
        SHA256.hash(data: Data(accountID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func snapshotKey(for accountID: String) -> String {
        "grove.local.snapshot.v2.account.\(namespace(for: accountID))"
    }

    static func mediaRootURL(for accountID: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("Grove/Accounts", isDirectory: true)
            .appendingPathComponent(namespace(for: accountID), isDirectory: true)
    }
}
