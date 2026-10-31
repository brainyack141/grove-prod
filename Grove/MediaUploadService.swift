import CryptoKit
import Foundation

enum MediaPurpose: String, Codable, Sendable {
    case scan
    case observation
    case avatar
    case sharedProgress = "shared_progress"
}

struct PendingMediaUpload: Codable, Hashable, Sendable {
    let localMediaID: UUID
    let fileURL: URL
    let purpose: MediaPurpose
    let mimeType: String
    let pixelWidth: Int
    let pixelHeight: Int
}

private struct CreateMediaUploadRequest: Encodable {
    let localMediaID: UUID
    let purpose: MediaPurpose
    let mimeType: String
    let byteCount: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let sha256: String
}

private struct CreateMediaUploadResponse: Decodable {
    let mediaAssetID: UUID
    let uploadURL: URL
    let headers: [String: String]
    let expiresAt: Date
}

private struct CompleteMediaUploadRequest: Encodable {
    let localMediaID: UUID
    let sha256: String
}

struct CompletedMediaUpload: Codable, Equatable, Sendable {
    let mediaAssetID: UUID
    let status: String
}

@MainActor
protocol MediaUploading {
    func upload(_ pending: PendingMediaUpload) async throws -> CompletedMediaUpload
}

@MainActor
final class HTTPMediaUploadService: MediaUploading {
    private let client: APIClient
    private let uploadSession: URLSession

    init(client: APIClient, uploadSession: URLSession = .shared) {
        self.client = client
        self.uploadSession = uploadSession
    }

    func upload(_ pending: PendingMediaUpload) async throws -> CompletedMediaUpload {
        // Read and hashed off the main actor: a full-size JPEG and its SHA-256
        // were costing the UI a visible hitch every time the queue drained.
        let (data, checksum) = try await Task.detached(priority: .utility) {
            try HTTPMediaUploadService.readPhoto(at: pending.fileURL)
        }.value
        let createRequest = CreateMediaUploadRequest(
            localMediaID: pending.localMediaID,
            purpose: pending.purpose,
            mimeType: pending.mimeType,
            byteCount: data.count,
            pixelWidth: pending.pixelWidth,
            pixelHeight: pending.pixelHeight,
            sha256: checksum
        )
        let signed: CreateMediaUploadResponse = try await client.post("media/uploads", body: createRequest)
        guard signed.expiresAt > .now else {
            throw APIError.validation("The photo upload permission expired. Retry sync to request a new one.")
        }

        var uploadRequest = URLRequest(url: signed.uploadURL)
        uploadRequest.httpMethod = "PUT"
        uploadRequest.setValue(pending.mimeType, forHTTPHeaderField: "Content-Type")
        for (header, value) in signed.headers { uploadRequest.setValue(value, forHTTPHeaderField: header) }

        let response: URLResponse
        do {
            (_, response) = try await uploadSession.upload(for: uploadRequest, from: data)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        // Storage, not a Grove gateway: whatever it says about a failed PUT is
        // not written for a user, so this keeps the generic wording.
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(status: http.statusCode, message: nil)
        }

        let completion: CompletedMediaUpload = try await client.post(
            "media/\(signed.mediaAssetID.uuidString)/complete",
            body: CompleteMediaUploadRequest(localMediaID: pending.localMediaID, sha256: checksum)
        )
        return completion
    }

    /// The photo's bytes and their SHA-256.
    ///
    /// The queue stores an absolute path, and the data container's UUID changes
    /// across reinstalls and some updates. It is re-rooted the same way the
    /// store's own photo references are, or every upload queued before the
    /// move reads as a missing file and is dropped.
    nonisolated private static func readPhoto(at storedURL: URL) throws -> (Data, String) {
        let fileURL = GroveMediaPath.resolved(storedURL) ?? storedURL
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw APIError.validation("The local photo is no longer available. Capture it again to continue syncing.")
            }
            // The file is there but cannot be read yet, typically because the
            // phone is locked and the photo is protected until it is unlocked.
            // That is a wait, not a loss: the queue retries it.
            throw APIError.transport(error.localizedDescription)
        }
        guard !data.isEmpty else { throw APIError.validation("The local photo is empty.") }
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (data, checksum)
    }
}
