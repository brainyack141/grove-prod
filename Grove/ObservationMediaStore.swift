import Foundation

struct ObservationMediaDraft: Codable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    let fileURL: URL
    let pixelWidth: Int
    let pixelHeight: Int
}

actor ObservationMediaStore {
    private let rootURL: URL

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.rootURL = base.appendingPathComponent("Grove/Observations", isDirectory: true)
        }
    }

    func save(imageData: Data, pixelWidth: Int, pixelHeight: Int) throws -> ObservationMediaDraft {
        guard !imageData.isEmpty else { throw ScanMediaError.invalidImage }
        guard pixelWidth >= 500, pixelHeight >= 500 else { throw ScanMediaError.imageTooSmall }

        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let id = UUID()
            let fileURL = rootURL.appendingPathComponent("\(id.uuidString).jpg")
            try imageData.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return ObservationMediaDraft(
                id: id,
                createdAt: .now,
                fileURL: fileURL,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        } catch let error as ScanMediaError {
            throw error
        } catch {
            throw ScanMediaError.couldNotSave
        }
    }

    func load(_ draft: ObservationMediaDraft) throws -> Data {
        do {
            return try Data(contentsOf: draft.fileURL)
        } catch {
            throw ScanMediaError.invalidImage
        }
    }

    func delete(_ draft: ObservationMediaDraft) {
        try? FileManager.default.removeItem(at: draft.fileURL)
    }
}
