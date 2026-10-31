import XCTest
@testable import Grove

@MainActor
final class DataExportServiceTests: XCTestCase {
    func testExportContainsAccountGraphAndEmbeddedObservationMedia() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveExportTests-\(UUID().uuidString)", isDirectory: true)
        let mediaURL = directory.appendingPathComponent("observation.jpg")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mediaData = Data(repeating: 0xEF, count: 128)
        try mediaData.write(to: mediaURL)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = GroveStore(persistenceEnabled: false)
        let plant = try XCTUnwrap(store.plants.first)
        let invite = store.createSittingInvite(
            sitterLabel: "Neighbour",
            startDate: .now,
            endDate: Date.now.addingTimeInterval(86_400),
            plantIDs: [plant.id],
            canLogCare: true
        )
        store.attachShareURL(inviteID: invite.id, url: URL(string: "https://grove.example/sit/export-secret")!)
        _ = store.applyCheckIn(
            plantID: plant.id,
            score: plant.healthScore,
            band: plant.healthBand,
            note: "Export evidence",
            photoURL: mediaURL
        )
        let service = LocalDataExportService(outputDirectory: directory)

        let exportURL = try await service.export(store: store)
        let data = try Data(contentsOf: exportURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(GroveDataExport.self, from: data)

        XCTAssertEqual(export.schemaVersion, 3)
        XCTAssertEqual(export.profile.username, store.profile.username)
        XCTAssertEqual(export.plants.count, store.plants.count)
        XCTAssertEqual(export.media.first?.base64Data, mediaData.base64EncodedString())
        XCTAssertEqual(export.sittingInvites.map(\.id), [invite.id])
        XCTAssertNil(export.sittingInvites.first?.shareURL, "a plaintext export must not contain a bearer credential")
    }
}
