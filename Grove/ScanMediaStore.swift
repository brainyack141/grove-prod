import Foundation
import UIKit

struct ScanMediaDraft: Codable, Hashable, Sendable {
    let id: UUID
    let mode: ScanMode
    let createdAt: Date
    let fileURL: URL
    let pixelWidth: Int
    let pixelHeight: Int
    var stage: ScanCaptureStage? = nil
    var qualityWarnings: [ScanImageQualityWarning]? = nil
}

enum ScanMediaError: LocalizedError, Equatable {
    case invalidImage
    case imageTooSmall
    case couldNotSave

    var errorDescription: String? {
        switch self {
        case .invalidImage: "The selected file is not a readable image."
        case .imageTooSmall: "Choose a photo at least 500 pixels wide and tall."
        case .couldNotSave: "Grove couldn't save this photo. Free up some storage and try again."
        }
    }
}

actor ScanMediaStore {
    private let rootURL: URL
    private let archiveRootURL: URL

    init(rootURL: URL? = nil, archiveRootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.rootURL = base.appendingPathComponent("Grove/ScanDrafts", isDirectory: true)
        }
        self.archiveRootURL = archiveRootURL
            ?? self.rootURL.deletingLastPathComponent().appendingPathComponent("ScanHistory", isDirectory: true)
    }

    func save(
        imageData: Data,
        mode: ScanMode,
        pixelWidth: Int,
        pixelHeight: Int,
        stage: ScanCaptureStage = .wholePlant,
        qualityWarnings: [ScanImageQualityWarning] = []
    ) throws -> ScanMediaDraft {
        guard pixelWidth >= 500, pixelHeight >= 500 else { throw ScanMediaError.imageTooSmall }
        guard !imageData.isEmpty,
              imageData.count <= UIImage.maximumPlantAnalysisJPEGBytes,
              imageData.starts(with: [0xFF, 0xD8, 0xFF]) else {
            throw ScanMediaError.invalidImage
        }

        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let id = UUID()
            let fileURL = rootURL.appendingPathComponent("\(id.uuidString).jpg")
            try imageData.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return ScanMediaDraft(
                id: id,
                mode: mode,
                createdAt: .now,
                fileURL: fileURL,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                stage: stage,
                qualityWarnings: qualityWarnings
            )
        } catch let error as ScanMediaError {
            throw error
        } catch {
            throw ScanMediaError.couldNotSave
        }
    }

    func load(_ draft: ScanMediaDraft) throws -> Data {
        guard owns(draft) else { throw ScanMediaError.invalidImage }
        do {
            let data = try Data(contentsOf: draft.fileURL)
            guard !data.isEmpty,
                  data.count <= UIImage.maximumPlantAnalysisJPEGBytes,
                  data.starts(with: [0xFF, 0xD8, 0xFF]) else {
                throw ScanMediaError.invalidImage
            }
            return data
        } catch let error as ScanMediaError {
            throw error
        } catch {
            throw ScanMediaError.invalidImage
        }
    }

    func delete(_ draft: ScanMediaDraft) {
        guard owns(draft) else { return }
        try? FileManager.default.removeItem(at: draft.fileURL)
    }

    func archive(_ draft: ScanMediaDraft, scanID: UUID) throws -> URL {
        guard owns(draft) else { throw ScanMediaError.invalidImage }
        let destination = archiveRootURL.appendingPathComponent("\(scanID.uuidString).jpg")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        do {
            let data = try load(draft)
            try FileManager.default.createDirectory(at: archiveRootURL, withIntermediateDirectories: true)
            try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return destination
        } catch let error as ScanMediaError {
            throw error
        } catch {
            throw ScanMediaError.couldNotSave
        }
    }

    /// Draft metadata is persisted outside the media actor and can outlive app
    /// versions, interrupted writes, or a restored device backup. Never trust
    /// its URL as authority to read or delete an arbitrary file in the app
    /// container: every draft we create is one UUID-named JPEG directly under
    /// this store's root.
    private func owns(_ draft: ScanMediaDraft) -> Bool {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = draft.fileURL.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.deletingLastPathComponent().path == root.path,
              candidate.pathExtension.lowercased() == "jpg" else { return false }
        return candidate.deletingPathExtension().lastPathComponent
            .caseInsensitiveCompare(draft.id.uuidString) == .orderedSame
    }

    func removeExpiredDrafts(olderThan cutoff: Date) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in files {
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
