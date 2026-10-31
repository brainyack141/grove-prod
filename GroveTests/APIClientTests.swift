import Foundation
import XCTest
@testable import Grove

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: APIError.invalidResponse)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private struct TestResponse: Codable, Equatable {
    let value: String
}

private func requestBodyData(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw try XCTUnwrap(stream.streamError) }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

@MainActor
final class APIClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testGetDecodesResponseAndSendsBearerToken() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.grove.test/v1/bootstrap")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"value":"ready"}"#.utf8))
        }
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://api.grove.test/v1/")!, environment: .staging),
            session: session,
            accessToken: { "test-token" }
        )

        let response: TestResponse = try await client.get("bootstrap")

        XCTAssertEqual(response, TestResponse(value: "ready"))
    }

    func testSpeciesSearchEncodesQuerySeparatorsAsText() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.path, "/v1/species/search")
            XCTAssertEqual(components.queryItems, [URLQueryItem(name: "q", value: "monstera&limit=1#fragment")])
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("[]".utf8)
            )
        }
        let client = APIClient(
            configuration: APIConfiguration(
                baseURL: URL(string: "https://api.grove.test/v1/")!,
                environment: .staging
            ),
            session: session,
            accessToken: { "test-token" }
        )
        let service = HTTPPlantSpeciesSearchClient(client: client)

        let results = try await service.search(query: "monstera&limit=1#fragment", regionCode: "NZ")

        XCTAssertTrue(results.isEmpty)
    }

    func testDeleteSendsAuthenticatedRequestWithoutABody() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.grove.test/v1/account")
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.httpBodyStream)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"value":"deleted"}"#.utf8))
        }
        let client = APIClient(
            configuration: APIConfiguration(
                baseURL: URL(string: "https://api.grove.test/v1/")!,
                environment: .staging
            ),
            session: session,
            accessToken: { "test-token" }
        )

        let response: TestResponse = try await client.delete("account")

        XCTAssertEqual(response, TestResponse(value: "deleted"))
    }

    func testForbiddenResponseMapsToPermissionError() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"message":"Assignment expired"}"#.utf8))
        }
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://api.grove.test/v1/")!, environment: .staging),
            session: session,
            accessToken: { "test-token" }
        )

        do {
            let _: TestResponse = try await client.get("plants/private")
            XCTFail("Expected forbidden")
        } catch let error as APIError {
            XCTAssertEqual(error, .forbidden)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// A gateway that explains itself — "Ari took too long to answer" —
    /// must not have that flattened into "Grove's service is down for a moment",
    /// which sends the user to look for an outage that isn't happening.
    func testServerFailureCarriesTheGatewaysOwnWording() async throws {
        let stalled = "Ari took too long to answer. Try asking again."
        let error = try await postFailure(status: 504, body: "{\"message\":\"\(stalled)\"}")
        XCTAssertEqual(error, .server(status: 504, message: stalled))
        XCTAssertEqual(error?.errorDescription, stalled)
    }

    /// Grove is not the only thing that can answer: a proxy or an edge runtime
    /// in front of it replies with traces and request ids, which are not copy.
    func testServerFailureFallsBackWhenTheBodyIsNotUserFacing() async throws {
        let notCopy = String(repeating: "stack frame ", count: 40)
        for body in ["{\"message\":\"\(notCopy)\"}", "{\"message\":\"  \"}", "<html>502 Bad Gateway</html>"] {
            let error = try await postFailure(status: 502, body: body)
            XCTAssertEqual(error, .server(status: 502, message: nil), "Unexpected mapping for body: \(body.prefix(40))")
            XCTAssertEqual(error?.errorDescription, "Grove's service is down for a moment. Try again shortly.")
        }
    }

    /// App and Edge Function releases cannot be atomic. Botanist v1 returned
    /// only the reply, so a v2-capable app must keep the answer rather than turn
    /// a successful request into "response not understood" while rollout lags.
    func testBotanistAcceptsLegacyReplyDuringRollingDeploy() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.grove.test/v1/botanist/ask")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"reply":"Check the soil first."}"#.utf8))
        }
        let api = APIClient(
            configuration: APIConfiguration(
                baseURL: URL(string: "https://api.grove.test/v1/")!,
                environment: .staging
            ),
            session: session,
            accessToken: { "test-token" }
        )

        let answer = try await HTTPBotanistClient(client: api).ask(
            conversation: [BotanistMessage(role: .user, text: "Does it need water?")],
            plantContext: nil,
            plantID: nil,
            threadID: UUID(),
            photoAttachments: []
        )

        XCTAssertEqual(answer.reply, "Check the soil first.")
        XCTAssertEqual(answer.disposition, "answer")
        XCTAssertEqual(answer.confidence, "low")
        XCTAssertEqual(answer.verification, "legacy")
        XCTAssertTrue(answer.sources.isEmpty)
        XCTAssertNil(answer.adviceID)
    }

    func testBotanistSendsStableMessageIDsAndPhotoAttachments() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let message = BotanistMessage(role: .user, text: "Are these spots spreading?")
        let photo = Data([0xff, 0xd8, 0xff, 0xd9])
        MockURLProtocol.handler = { request in
            // URLProtocol hands a streamed body over as `httpBodyStream`, never
            // `httpBody`, so reading the property directly makes this assertion
            // unreachable rather than true.
            let body = try requestBodyData(request)
            let json = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["requestID"] as? String, message.id.uuidString)
            XCTAssertEqual(json["safetyOnly"] as? Bool, false)
            let conversation = try XCTUnwrap(json["conversation"] as? [[String: Any]])
            XCTAssertEqual(conversation.last?["id"] as? String, message.id.uuidString)
            let attachments = try XCTUnwrap(json["attachments"] as? [[String: Any]])
            XCTAssertEqual(attachments.count, 1)
            XCTAssertEqual(attachments[0]["messageID"] as? String, message.id.uuidString)
            XCTAssertEqual(attachments[0]["mimeType"] as? String, "image/jpeg")
            XCTAssertEqual(attachments[0]["base64Data"] as? String, photo.base64EncodedString())
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (
                response,
                Data(
                    #"{"reply":"Keep watching the two marked leaves.","provider":"google_gemini","model":"gemini-3.7-flash","usedPhotoMessageIDs":["\#(message.id.uuidString)"],"visualEvidence":"bounded evidence"}"#.utf8
                )
            )
        }
        let api = APIClient(
            configuration: APIConfiguration(
                baseURL: URL(string: "https://api.grove.test/v1/")!,
                environment: .staging
            ),
            session: session,
            accessToken: { "test-token" }
        )

        let answer = try await HTTPBotanistClient(client: api).ask(
            conversation: [message],
            plantContext: nil,
            plantID: nil,
            threadID: UUID(),
            photoAttachments: [BotanistPhotoAttachment(messageID: message.id, data: photo)]
        )

        XCTAssertEqual(answer.provider, "google_gemini")
        XCTAssertEqual(answer.model, "gemini-3.7-flash")
        XCTAssertEqual(answer.usedPhotoMessageIDs, [message.id])
        XCTAssertEqual(answer.visualEvidence, "bounded evidence")
    }

    func testBotanistEncodesSafetyProbeAndMapsPaymentRequiredToPolicy() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let message = BotanistMessage(role: .user, text: "One more routine question?")
        MockURLProtocol.handler = { request in
            let body = try requestBodyData(request)
            let json = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["safetyOnly"] as? Bool, true)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 402,
                httpVersion: nil,
                headerFields: nil
            )!
            return (
                response,
                Data(#"{"message":"Grove Premium is needed for another question today."}"#.utf8)
            )
        }
        let api = APIClient(
            configuration: APIConfiguration(
                baseURL: URL(string: "https://api.grove.test/v1/")!,
                environment: .staging
            ),
            session: session,
            accessToken: { "test-token" }
        )

        do {
            _ = try await HTTPBotanistClient(client: api).ask(
                conversation: [message],
                plantContext: nil,
                plantID: nil,
                threadID: UUID(),
                photoAttachments: [],
                safetyOnly: true
            )
            XCTFail("Expected the premium policy result")
        } catch BotanistClientPolicyError.premiumRequired {
            // Expected: the session opens the paywall instead of showing a
            // generic server failure or retaining an unanswered fourth turn.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBotanistKeepsAnOlderPhotoMessageOutsideTheRecentTurnWindow() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let olderPhotoMessage = BotanistMessage(role: .user, text: "This is the original photo.")
        let laterTurns = (0..<13).map { index in
            BotanistMessage(
                role: index.isMultiple(of: 2) ? .botanist : .user,
                text: "Later turn \(index)"
            )
        }
        // The final turn must be a user message, as it is in production.
        let finalTurn = BotanistMessage(role: .user, text: "Compare it with the first photo.")
        let conversation = [olderPhotoMessage] + laterTurns + [finalTurn]
        let photo = Data([0xff, 0xd8, 0xff, 0xd9])
        // Flattened to plain strings before the handler is built. The handler
        // runs on URLSession's queue, and capturing main-actor state (a mutable
        // local especially) makes Swift assert the actor at read time, which
        // trapped the whole test host rather than failing one assertion.
        let olderPhotoID = olderPhotoMessage.id.uuidString
        let finalTurnID = finalTurn.id.uuidString

        // `@Sendable` makes this closure and the assertion closures nested in
        // it non-isolated. Without it they inherit the test's main-actor
        // isolation, and running on URLSession's queue trapped the test host
        // instead of failing an assertion.
        MockURLProtocol.handler = { @Sendable request in
            let body = try requestBodyData(request)
            let json = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let sent = try XCTUnwrap(json["conversation"] as? [[String: Any]])
            XCTAssertEqual(sent.last?["id"] as? String, finalTurnID)
            XCTAssertTrue(
                sent.contains { $0["id"] as? String == olderPhotoID },
                "The message owning a reused photo must accompany its attachment."
            )
            XCTAssertLessThanOrEqual(sent.count, 14)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"reply":"Compared safely."}"#.utf8))
        }
        let api = APIClient(
            configuration: APIConfiguration(
                baseURL: URL(string: "https://api.grove.test/v1/")!,
                environment: .staging
            ),
            session: session,
            accessToken: { "test-token" }
        )

        _ = try await HTTPBotanistClient(client: api).ask(
            conversation: conversation,
            plantContext: nil,
            plantID: nil,
            threadID: UUID(),
            photoAttachments: [
                BotanistPhotoAttachment(messageID: olderPhotoMessage.id, data: photo)
            ]
        )
    }

    /// Sends one POST that fails, and hands back how the client classified it.
    private func postFailure(status: Int, body: String) async throws -> APIError? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            return (HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://api.grove.test/v1/")!, environment: .staging),
            session: session,
            accessToken: { "test-token" }
        )
        do {
            let _: TestResponse = try await client.post("botanist/ask", body: TestResponse(value: "hi"))
            XCTFail("A \(status) should not decode as a reply")
            return nil
        } catch let error as APIError {
            return error
        }
    }

    func testSignedMediaUploadCreatesUploadsAndCompletesAsset() async throws {
        let mediaAssetID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.absoluteString == "https://api.grove.test/v1/media/uploads" {
                XCTAssertEqual(request.httpMethod, "POST")
                let json = """
                {"mediaAssetID":"\(mediaAssetID.uuidString)","uploadURL":"https://uploads.grove.test/object","headers":{"x-grove-upload":"signed"},"expiresAt":"2030-01-01T00:00:00Z"}
                """
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
            if url.host == "uploads.grove.test" {
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-grove-upload"), "signed")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
            XCTAssertEqual(url.absoluteString, "https://api.grove.test/v1/media/\(mediaAssetID.uuidString)/complete")
            let json = "{\"mediaAssetID\":\"\(mediaAssetID.uuidString)\",\"status\":\"ready\"}"
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }

        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://api.grove.test/v1/")!, environment: .staging),
            session: session,
            accessToken: { "test-token" }
        )
        let service = HTTPMediaUploadService(client: client, uploadSession: session)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("GroveUpload-\(UUID().uuidString).jpg")
        try Data(repeating: 0xCD, count: 2_048).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let completed = try await service.upload(
            PendingMediaUpload(
                localMediaID: UUID(),
                fileURL: fileURL,
                purpose: .observation,
                mimeType: "image/jpeg",
                pixelWidth: 900,
                pixelHeight: 1200
            )
        )

        XCTAssertEqual(completed, CompletedMediaUpload(mediaAssetID: mediaAssetID, status: "ready"))
    }

    func testPlantAnalysisUsesResumableJobAndPollsUntilCompletion() async throws {
        let jobID = UUID(uuidString: "41000000-0000-4000-8000-000000000001")!
        let clientRequestID = UUID(uuidString: "42000000-0000-4000-8000-000000000001")!
        let localMediaID = UUID(uuidString: "43000000-0000-4000-8000-000000000001")!
        let mediaAssetID = UUID(uuidString: "44000000-0000-4000-8000-000000000001")!
        let expected = try await LocalPlantAnalysisClient(simulatedDelay: .zero)
            .analyse(imageData: Data([0x01]), mode: .identify)
        let resultObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected))
        let queuedData = try JSONSerialization.data(withJSONObject: [
            "id": jobID.uuidString.lowercased(),
            "status": "queued",
        ])
        let analysingData = try JSONSerialization.data(withJSONObject: [
            "id": jobID.uuidString.lowercased(),
            "status": "analysing",
        ])
        let completedData = try JSONSerialization.data(withJSONObject: [
            "id": jobID.uuidString.lowercased(),
            "status": "completed",
            "result": resultObject,
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let mediaFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveAnalysisUpload-\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: mediaFileURL)
        defer { try? FileManager.default.removeItem(at: mediaFileURL) }
        var pollCount = 0
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if request.httpMethod == "POST" {
                XCTAssertEqual(url.absoluteString, "https://api.grove.test/v1/analysis/jobs")
                let body = try requestBodyData(request)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual((json["clientRequestID"] as? String)?.lowercased(), clientRequestID.uuidString.lowercased())
                let images = try XCTUnwrap(json["images"] as? [[String: Any]])
                XCTAssertEqual((images.first?["mediaAssetID"] as? String)?.lowercased(), mediaAssetID.uuidString.lowercased())
                XCTAssertNil(images.first?["base64Data"])
                return (HTTPURLResponse(url: url, statusCode: 202, httpVersion: nil, headerFields: nil)!, queuedData)
            }

            XCTAssertEqual(url.absoluteString, "https://api.grove.test/v1/analysis/jobs/\(jobID.uuidString.lowercased())")
            pollCount += 1
            let data = pollCount == 1 ? analysingData : completedData
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://api.grove.test/v1/")!, environment: .staging),
            session: session,
            accessToken: { "test-token" }
        )
        let mediaUploader = RecordingMediaUploader(mediaAssetID: mediaAssetID)
        let service = HTTPPlantAnalysisClient(client: client, mediaUploader: mediaUploader, pollInterval: .zero)

        let result = try await service.analyse(
            request: PlantAnalysisRequest(
                clientRequestID: clientRequestID,
                mode: .identify,
                images: [
                    PlantAnalysisImage(
                        stage: .wholePlant,
                        mimeType: "image/jpeg",
                        base64Data: Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString(),
                        localMediaID: localMediaID,
                        localFileURL: mediaFileURL,
                        pixelWidth: 900,
                        pixelHeight: 1_200
                    )
                ],
                regionCode: "GB",
                existingPlant: nil,
                answers: [:]
            )
        )

        XCTAssertEqual(result, expected)
        XCTAssertEqual(pollCount, 2)
        XCTAssertEqual(mediaUploader.pending.map(\.localMediaID), [localMediaID])
    }

    func testPlantAnalysisRetriesTransientJobCreationFailure() async throws {
        let jobID = UUID(uuidString: "41000000-0000-4000-8000-000000000004")!
        let expected = try await LocalPlantAnalysisClient(simulatedDelay: .zero)
            .analyse(imageData: Data([0x01]), mode: .identify)
        let resultObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected))
        let queuedData = try JSONSerialization.data(withJSONObject: [
            "id": jobID.uuidString.lowercased(),
            "status": "queued",
        ])
        let completedData = try JSONSerialization.data(withJSONObject: [
            "id": jobID.uuidString.lowercased(),
            "status": "completed",
            "result": resultObject,
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var creationCount = 0
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if request.httpMethod == "POST" {
                creationCount += 1
                if creationCount == 1 {
                    return (
                        HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                        Data()
                    )
                }
                return (
                    HTTPURLResponse(url: url, statusCode: 202, httpVersion: nil, headerFields: nil)!,
                    queuedData
                )
            }
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                completedData
            )
        }
        let client = APIClient(
            configuration: APIConfiguration(
                baseURL: URL(string: "https://api.grove.test/v1/")!,
                environment: .staging
            ),
            session: session,
            accessToken: { "test-token" }
        )
        let service = HTTPPlantAnalysisClient(
            client: client,
            mediaUploader: RecordingMediaUploader(mediaAssetID: UUID()),
            pollInterval: .zero,
            creationRetryDelay: .zero
        )

        let result = try await service.analyse(
            request: PlantAnalysisRequest(
                clientRequestID: UUID(),
                mode: .identify,
                images: [
                    PlantAnalysisImage(
                        stage: .wholePlant,
                        mimeType: "image/jpeg",
                        base64Data: Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()
                    )
                ],
                regionCode: nil,
                existingPlant: nil,
                answers: [:]
            )
        )

        XCTAssertEqual(result, expected)
        XCTAssertEqual(creationCount, 2)
    }

    func testPlantAnalysisRecreatesStableJobAfterPollLookupIsLost() async throws {
        let firstJobID = UUID(uuidString: "41000000-0000-4000-8000-000000000005")!
        let resumedJobID = UUID(uuidString: "41000000-0000-4000-8000-000000000006")!
        let clientRequestID = UUID(uuidString: "51000000-0000-4000-8000-000000000001")!
        let expected = try await LocalPlantAnalysisClient(simulatedDelay: .zero)
            .analyse(imageData: Data([0x01]), mode: .identify)
        let resultObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected))
        let firstQueuedData = try JSONSerialization.data(withJSONObject: [
            "id": firstJobID.uuidString.lowercased(),
            "status": "queued",
        ])
        let resumedQueuedData = try JSONSerialization.data(withJSONObject: [
            "id": resumedJobID.uuidString.lowercased(),
            "status": "queued",
        ])
        let completedData = try JSONSerialization.data(withJSONObject: [
            "id": resumedJobID.uuidString.lowercased(),
            "status": "completed",
            "result": resultObject,
        ])
        let notFoundData = try JSONSerialization.data(withJSONObject: [
            "message": "Analysis job not found.",
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var creationCount = 0
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if request.httpMethod == "POST" {
                creationCount += 1
                let body = try requestBodyData(request)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(
                    (json["clientRequestID"] as? String)?.lowercased(),
                    clientRequestID.uuidString.lowercased()
                )
                let data = creationCount == 1 ? firstQueuedData : resumedQueuedData
                return (HTTPURLResponse(url: url, statusCode: 202, httpVersion: nil, headerFields: nil)!, data)
            }
            if url.path.hasSuffix(firstJobID.uuidString.lowercased()) {
                return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, notFoundData)
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, completedData)
        }
        let client = APIClient(
            configuration: APIConfiguration(
                baseURL: URL(string: "https://api.grove.test/v1/")!,
                environment: .staging
            ),
            session: session,
            accessToken: { "test-token" }
        )
        let service = HTTPPlantAnalysisClient(
            client: client,
            mediaUploader: RecordingMediaUploader(mediaAssetID: UUID()),
            pollInterval: .zero,
            creationRetryDelay: .zero
        )

        let result = try await service.analyse(
            request: PlantAnalysisRequest(
                clientRequestID: clientRequestID,
                mode: .identify,
                images: [
                    PlantAnalysisImage(
                        stage: .wholePlant,
                        mimeType: "image/jpeg",
                        base64Data: Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()
                    )
                ],
                regionCode: nil,
                existingPlant: nil,
                answers: [:]
            )
        )

        XCTAssertEqual(result, expected)
        XCTAssertEqual(creationCount, 2)
    }

    func testServiceURLRejectsBlankAndRelativeOverrides() {
        XCTAssertNil(GroveServiceFactory.serviceURL(from: nil))
        XCTAssertNil(GroveServiceFactory.serviceURL(from: ""))
        XCTAssertNil(GroveServiceFactory.serviceURL(from: "   "))
        XCTAssertNil(GroveServiceFactory.serviceURL(from: "$(GROVE_ANALYSIS_BASE_URL)"))
        XCTAssertNil(GroveServiceFactory.serviceURL(from: "analysis/jobs"))
    }

    /// No key is compiled into the source any more: an unset `GROVE_APP_KEY`
    /// must read as "not configured" so the production clients stay off.
    func testAppKeyTreatsUnsetBuildSettingAsMissing() {
        XCTAssertNil(GroveServiceFactory.configuredAppKey(from: nil))
        XCTAssertNil(GroveServiceFactory.configuredAppKey(from: ""))
        XCTAssertNil(GroveServiceFactory.configuredAppKey(from: "  \n"))
        XCTAssertNil(GroveServiceFactory.configuredAppKey(from: "$(GROVE_APP_KEY)"))
        XCTAssertEqual(GroveServiceFactory.configuredAppKey(from: " local-key "), "local-key")
    }

    func testServiceURLNormalisesTrailingSlash() {
        XCTAssertEqual(
            GroveServiceFactory.serviceURL(from: " https://example.test/functions/v1 "),
            URL(string: "https://example.test/functions/v1/")
        )
        XCTAssertEqual(
            URL(
                string: "analysis/jobs",
                relativeTo: GroveServiceFactory.serviceURL(from: "https://example.test/functions/v1")
            )?.absoluteString,
            "https://example.test/functions/v1/analysis/jobs"
        )
    }

    /// The on-device quality gate's warnings have to survive the trip to the
    /// gateway. The job body once had no field for them, so every production
    /// photo reached the model described as "no warning", and the gateway's
    /// check for a confident identification never saw a soft or dark capture.
    func testPlantAnalysisSendsOnDeviceQualityWarningsToTheGateway() async throws {
        let jobID = UUID(uuidString: "41000000-0000-4000-8000-000000000009")!
        let queuedData = try JSONSerialization.data(withJSONObject: [
            "id": jobID.uuidString.lowercased(),
            "status": "queued",
        ])
        let failedData = try JSONSerialization.data(withJSONObject: [
            "id": jobID.uuidString.lowercased(),
            "status": "failed",
            "message": "Stopped by the test.",
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var sentImages: [[String: Any]] = []
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if request.httpMethod == "POST" {
                let body = try requestBodyData(request)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                sentImages = try XCTUnwrap(json["images"] as? [[String: Any]])
                return (HTTPURLResponse(url: url, statusCode: 202, httpVersion: nil, headerFields: nil)!, queuedData)
            }
            return (HTTPURLResponse(url: url, statusCode: 202, httpVersion: nil, headerFields: nil)!, failedData)
        }
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://api.grove.test/v1/")!, environment: .staging),
            session: session,
            accessToken: { "test-token" }
        )
        // Production sends photos inline to the Edge Function gateway.
        let service = HTTPPlantAnalysisClient(client: client, pollInterval: .zero, sendsInlineImages: true)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()

        _ = try? await service.analyse(
            request: PlantAnalysisRequest(
                clientRequestID: UUID(),
                mode: .diagnose,
                images: [
                    PlantAnalysisImage(
                        stage: .wholePlant,
                        mimeType: "image/jpeg",
                        base64Data: jpeg,
                        qualityWarnings: ["lowLight", "softFocus"]
                    ),
                    PlantAnalysisImage(stage: .symptom, mimeType: "image/jpeg", base64Data: jpeg)
                ],
                regionCode: "NZ",
                existingPlant: nil,
                answers: [:]
            )
        )

        XCTAssertEqual(sentImages.count, 2)
        XCTAssertEqual(sentImages.first?["qualityWarnings"] as? [String], ["lowLight", "softFocus"])
        // A photo the gate did not flag sends no field rather than an empty list.
        XCTAssertNil(sentImages.last?["qualityWarnings"])
    }

    func testPlantAnalysisSurfacesServerFailureMessageForFailedJob() async throws {
        let jobID = UUID(uuidString: "41000000-0000-4000-8000-000000000002")!
        let failureMessage = "Plant analysis timed out. Try again with the saved photos."
        let queuedData = try JSONSerialization.data(withJSONObject: [
            "id": jobID.uuidString.lowercased(),
            "status": "queued",
        ])
        let failedData = try JSONSerialization.data(withJSONObject: [
            "id": jobID.uuidString.lowercased(),
            "status": "failed",
            "message": failureMessage,
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if request.httpMethod == "POST" {
                return (HTTPURLResponse(url: url, statusCode: 202, httpVersion: nil, headerFields: nil)!, queuedData)
            }
            return (HTTPURLResponse(url: url, statusCode: 202, httpVersion: nil, headerFields: nil)!, failedData)
        }
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://api.grove.test/v1/")!, environment: .staging),
            session: session,
            accessToken: { "test-token" }
        )
        let service = HTTPPlantAnalysisClient(
            client: client,
            mediaUploader: RecordingMediaUploader(mediaAssetID: UUID()),
            pollInterval: .zero
        )

        do {
            _ = try await service.analyse(
                request: PlantAnalysisRequest(
                    clientRequestID: UUID(),
                    mode: .identify,
                    images: [
                        PlantAnalysisImage(
                            stage: .wholePlant,
                            mimeType: "image/jpeg",
                            base64Data: Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()
                        )
                    ],
                    regionCode: nil,
                    existingPlant: nil,
                    answers: [:]
                )
            )
            XCTFail("A failed analysis job should throw.")
        } catch let error as PlantAnalysisError {
            XCTAssertEqual(error, .reported(message: failureMessage))
            XCTAssertEqual(error.errorDescription, failureMessage)
        }
    }

    func testPlantAnalysisGivesUpAtThePollDeadlineAndCancelsTheServerJob() async throws {
        let jobID = UUID(uuidString: "41000000-0000-4000-8000-000000000003")!
        let queuedData = try JSONSerialization.data(withJSONObject: [
            "id": jobID.uuidString.lowercased(),
            "status": "queued",
        ])
        let cancelledData = try JSONSerialization.data(withJSONObject: [
            "id": jobID.uuidString.lowercased(),
            "status": "cancelled",
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var cancelledOnServer = false
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if request.httpMethod == "POST" {
                return (HTTPURLResponse(url: url, statusCode: 202, httpVersion: nil, headerFields: nil)!, queuedData)
            }
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(url.absoluteString, "https://api.grove.test/v1/analysis/jobs/\(jobID.uuidString.lowercased())")
            cancelledOnServer = true
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cancelledData)
        }
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://api.grove.test/v1/")!, environment: .staging),
            session: session,
            accessToken: { "test-token" }
        )
        let service = HTTPPlantAnalysisClient(
            client: client,
            mediaUploader: RecordingMediaUploader(mediaAssetID: UUID()),
            pollInterval: .zero,
            pollDeadline: .zero
        )

        do {
            _ = try await service.analyse(
                request: PlantAnalysisRequest(
                    clientRequestID: UUID(),
                    mode: .identify,
                    images: [
                        PlantAnalysisImage(
                            stage: .wholePlant,
                            mimeType: "image/jpeg",
                            base64Data: Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()
                        )
                    ],
                    regionCode: nil,
                    existingPlant: nil,
                    answers: [:]
                )
            )
            XCTFail("A job that never settles should throw at the poll deadline.")
        } catch let error as PlantAnalysisError {
            guard case .reported(let message) = error else {
                return XCTFail("Expected a user-facing deadline message, got \(error)")
            }
            XCTAssertTrue(message.contains("longer than it should"), "Unexpected deadline copy: \(message)")
        }
        await service.pendingRemoteCancellation?.value
        XCTAssertTrue(cancelledOnServer)
    }

    /// The gateway's daily scan ceiling is an abuse guard, but a real person can
    /// still reach it, and when they do they must be told what happened in a
    /// sentence they can act on — not left with a generic "check it and try
    /// again", and not made to sit through three pointless retries first.
    func testPlantAnalysisSurfacesTheDailyCeilingWithoutRetrying() async throws {
        let ceilingMessage = "You've used today's scans. Your photos are saved. Try again tomorrow."
        let body = try JSONSerialization.data(withJSONObject: ["message": ceilingMessage])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var creationAttempts = 0
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.httpMethod, "POST")
            creationAttempts += 1
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "3600"]
                )!,
                body
            )
        }
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://api.grove.test/v1/")!, environment: .staging),
            session: session,
            accessToken: { "test-token" }
        )
        let service = HTTPPlantAnalysisClient(
            client: client,
            mediaUploader: RecordingMediaUploader(mediaAssetID: UUID()),
            pollInterval: .zero,
            creationRetryDelay: .zero
        )

        do {
            _ = try await service.analyse(
                request: PlantAnalysisRequest(
                    clientRequestID: UUID(),
                    mode: .identify,
                    images: [
                        PlantAnalysisImage(
                            stage: .wholePlant,
                            mimeType: "image/jpeg",
                            base64Data: Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()
                        )
                    ],
                    regionCode: nil,
                    existingPlant: nil,
                    answers: [:]
                )
            )
            XCTFail("A refused scan should throw.")
        } catch {
            XCTAssertEqual(error.localizedDescription, ceilingMessage)
        }
        XCTAssertEqual(creationAttempts, 1, "A ceiling is not a transient failure and must not be retried.")
    }

    /// A phone with its data switched off used to be told "Analysis is
    /// unavailable right now" — Grove blaming its own service for a fault it
    /// could see was the user's connection, and inviting a retry that could not
    /// leave the device. The one failure the phone can diagnose by itself has
    /// to survive the trip through the analysis client.
    func testAnalysisKeepsOfflineDistinctFromAServiceFault() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://api.grove.test/v1/")!, environment: .staging),
            session: session,
            accessToken: { "test-token" }
        )
        let service = HTTPPlantAnalysisClient(
            client: client,
            mediaUploader: RecordingMediaUploader(mediaAssetID: UUID()),
            pollInterval: .zero,
            creationRetryDelay: .zero
        )

        do {
            _ = try await service.analyse(request: offlineTestRequest())
            XCTFail("An offline scan should throw.")
        } catch let error as PlantAnalysisError {
            XCTAssertEqual(error, .offline)
            XCTAssertEqual(ScanFailureKind(error), .connection)
            let copy = try XCTUnwrap(error.errorDescription)
            XCTAssertTrue(copy.localizedCaseInsensitiveContains("offline"), "Unexpected offline copy: \(copy)")
            XCTAssertNotEqual(error, .unavailable)
        }
    }

    func testMalformedResultIsRetryableWithoutBlamingThePhoto() {
        let error = PlantAnalysisError.malformedResponse

        XCTAssertEqual(ScanFailureKind(error), .service)
        XCTAssertTrue(ScanFailureKind(error).isRetryable)
        XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("photo is saved"))
    }

    /// The ceiling reaches the scan card as a failure that offers no retry —
    /// the whole point of telling someone to come back tomorrow is not handing
    /// them a button that fails again.
    func testDailyCeilingReachesTheScanCardAsANonRetryableFailure() async throws {
        let ceilingMessage = "You've used today's scans. Your photos are saved. Try again tomorrow."
        let body = try JSONSerialization.data(withJSONObject: ["message": ceilingMessage])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            return (HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://api.grove.test/v1/")!, environment: .staging),
            session: session,
            accessToken: { "test-token" }
        )
        let service = HTTPPlantAnalysisClient(
            client: client,
            mediaUploader: RecordingMediaUploader(mediaAssetID: UUID()),
            pollInterval: .zero,
            creationRetryDelay: .zero
        )

        do {
            _ = try await service.analyse(request: offlineTestRequest())
            XCTFail("A refused scan should throw.")
        } catch let error as PlantAnalysisError {
            XCTAssertEqual(error, .atDailyLimit(message: ceilingMessage))
            XCTAssertEqual(error.errorDescription, ceilingMessage)
            XCTAssertFalse(ScanFailureKind(error).isRetryable)
        }
    }

    /// A 5xx that carries the gateway's own sentence — "Ari took too
    /// long to answer" — used to be replaced with Grove's generic one on the
    /// way through, throwing away the only specific thing the user was told.
    func testAnalysisKeepsTheGatewaysOwnServerMessage() async throws {
        let stalled = "The plant reader took too long to answer. Your photo is saved."
        let body = try JSONSerialization.data(withJSONObject: ["message": stalled])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            return (HTTPURLResponse(url: url, statusCode: 504, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = APIClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://api.grove.test/v1/")!, environment: .staging),
            session: session,
            accessToken: { "test-token" }
        )
        let service = HTTPPlantAnalysisClient(
            client: client,
            mediaUploader: RecordingMediaUploader(mediaAssetID: UUID()),
            pollInterval: .zero,
            creationRetryDelay: .zero
        )

        do {
            _ = try await service.analyse(request: offlineTestRequest())
            XCTFail("A gateway failure should throw.")
        } catch let error as PlantAnalysisError {
            XCTAssertEqual(error.errorDescription, stalled)
            XCTAssertTrue(ScanFailureKind(error).isRetryable)
        }
    }

    private func offlineTestRequest() -> PlantAnalysisRequest {
        PlantAnalysisRequest(
            clientRequestID: UUID(),
            mode: .identify,
            images: [
                PlantAnalysisImage(
                    stage: .wholePlant,
                    mimeType: "image/jpeg",
                    base64Data: Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()
                )
            ],
            regionCode: nil,
            existingPlant: nil,
            answers: [:]
        )
    }
}

@MainActor
private final class RecordingMediaUploader: MediaUploading {
    private let mediaAssetID: UUID
    private(set) var pending: [PendingMediaUpload] = []

    init(mediaAssetID: UUID) {
        self.mediaAssetID = mediaAssetID
    }

    func upload(_ pending: PendingMediaUpload) async throws -> CompletedMediaUpload {
        self.pending.append(pending)
        return CompletedMediaUpload(mediaAssetID: mediaAssetID, status: "ready")
    }
}
