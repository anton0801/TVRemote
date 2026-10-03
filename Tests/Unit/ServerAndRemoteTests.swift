import XCTest
@testable import TVRemoteScreenMirroring

final class LocalHTTPServerTests: XCTestCase {
    private var server: LocalHTTPServer!

    override func setUp() {
        server = LocalHTTPServer()
    }

    override func tearDown() {
        server.stop()
    }

    private func get(_ path: String, port: UInt16, range: String? = nil) async throws -> (Int, Data, [AnyHashable: Any]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let http = response as! HTTPURLResponse
        return (http.statusCode, data, http.allHeaderFields)
    }

    func testServesOnlyRegisteredResourceWithRange() async throws {
        let port = try await server.start()
        let payload = Data((0..<1000).map { UInt8($0 % 256) })
        let path = server.register(.init(body: .data(payload), contentType: "image/jpeg", expiresAt: .now.addingTimeInterval(60),
                                         dlnaTransferMode: "Interactive", dlnaContentFeatures: nil), fileName: "photo.jpg")
        let (status, body, headers) = try await get(path, port: port)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body, payload)
        XCTAssertEqual(headers["transferMode.dlna.org"] as? String, "Interactive")

        let (partialStatus, partial, _) = try await get(path, port: port, range: "bytes=10-19")
        XCTAssertEqual(partialStatus, 206)
        XCTAssertEqual(partial, payload.subdata(in: 10..<20))

        let (unknown, _, _) = try await get("/m/\(LocalHTTPServer.makeToken())/photo.jpg", port: port)
        XCTAssertEqual(unknown, 404)
        let (listing, _, _) = try await get("/", port: port)
        XCTAssertEqual(listing, 404, "No directory listing")
    }

    func testFileStreamingWithRange() async throws {
        let port = try await server.start()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).bin")
        let payload = Data((0..<600_000).map { UInt8($0 % 251) })
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let path = server.register(.init(body: .file(url), contentType: "video/mp4", expiresAt: .now.addingTimeInterval(60),
                                         dlnaTransferMode: "Streaming", dlnaContentFeatures: nil), fileName: "video.mp4")
        let (status, body, _) = try await get(path, port: port)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body, payload)
        let (partialStatus, tail, headers) = try await get(path, port: port, range: "bytes=-100")
        XCTAssertEqual(partialStatus, 206)
        XCTAssertEqual(tail, payload.suffix(100))
        XCTAssertEqual(headers["Content-Range"] as? String, "bytes 599900-599999/600000")
    }

    func testExpiredTokenIsRejected() async throws {
        let port = try await server.start()
        let path = server.register(.init(body: .data(Data([1])), contentType: "text/plain", expiresAt: .now.addingTimeInterval(-1),
                                         dlnaTransferMode: nil, dlnaContentFeatures: nil), fileName: "x")
        let (status, _, _) = try await get(path, port: port)
        XCTAssertEqual(status, 404)
    }

    func testOtherClientsAreForbidden() async throws {
        server.allowedClientHost = "192.168.1.77"
        let port = try await server.start()
        let path = server.register(.init(body: .data(Data([1])), contentType: "text/plain", expiresAt: .now.addingTimeInterval(60),
                                         dlnaTransferMode: nil, dlnaContentFeatures: nil), fileName: "x")
        let (status, _, _) = try await get(path, port: port)
        XCTAssertEqual(status, 403)
    }

    func testStopEndsAccess() async throws {
        let port = try await server.start()
        let path = server.register(.init(body: .data(Data([1])), contentType: "text/plain", expiresAt: .now.addingTimeInterval(60),
                                         dlnaTransferMode: nil, dlnaContentFeatures: nil), fileName: "x")
        server.stop()
        do {
            _ = try await get(path, port: port)
            XCTFail("Server should be gone")
        } catch {}
    }

    func testRangeParsing() {
        XCTAssertEqual(LocalHTTPServer.byteRange("bytes=0-99", total: 1000), 0...99)
        XCTAssertEqual(LocalHTTPServer.byteRange("bytes=900-", total: 1000), 900...999)
        XCTAssertEqual(LocalHTTPServer.byteRange("bytes=-50", total: 1000), 950...999)
        XCTAssertEqual(LocalHTTPServer.byteRange("bytes=0-5000", total: 1000), 0...999)
        XCTAssertNil(LocalHTTPServer.byteRange("bytes=2000-", total: 1000))
        XCTAssertNil(LocalHTTPServer.byteRange("items=0-1", total: 1000))
    }

    func testTokensAreUnguessable() {
        let tokens = Set((0..<100).map { _ in LocalHTTPServer.makeToken() })
        XCTAssertEqual(tokens.count, 100)
        XCTAssertTrue(tokens.allSatisfy { $0.count == 32 })
    }
}

// MARK: - Remote control

actor MockTVSession: TVSession {
    nonisolated let deviceID = TVDeviceID(platform: .samsungTizen, uniqueID: "mock")
    nonisolated let platform: TVPlatform = .samsungTizen
    nonisolated let events: AsyncStream<TVSessionEvent> = AsyncStream { _ in }
    nonisolated let supportedCommands = Set(RemoteCommand.allCases)
    nonisolated let textInputMode: TextInputMode? = .appendAndDelete
    nonisolated let canListInstalledApps = false
    nonisolated let canOpenBrowser = false
    private(set) var sent: [(RemoteCommand, KeyAction)] = []
    private(set) var textOperations: [TextInputOperation] = []
    var delay: Duration = .zero
    var failNext: AppError?

    nonisolated func supportsPressRelease(_ command: RemoteCommand) -> Bool { command.isRepeatable }

    func setDelay(_ delay: Duration) { self.delay = delay }

    func send(_ command: RemoteCommand, action: KeyAction) async throws {
        if delay != .zero { try await Task.sleep(for: delay) }
        if let failNext { self.failNext = nil; throw failNext }
        sent.append((command, action))
    }

    func performText(_ operation: TextInputOperation) async throws { textOperations.append(operation) }
    func installedApps() async throws -> [TVAppInfo] { [] }
    func launch(_ app: TVAppCatalog.Entry) async throws -> AppLaunchOutcome { .accepted }
    func launch(appID: String) async throws -> AppLaunchOutcome { .accepted }
    func openBrowser(url: URL) async throws {}
    func appIconData(for app: TVAppInfo) async -> Data? { nil }
    func close() async {}
}

final class CommandPipelineTests: XCTestCase {
    func testOrderIsPreserved() async throws {
        let session = MockTVSession()
        await session.setDelay(.milliseconds(5))
        let pipeline = CommandPipeline(session: session) { _, _ in }
        for command in [RemoteCommand.up, .left, .ok, .back] { await pipeline.enqueue(command, .click) }
        try await Task.sleep(for: .milliseconds(200))
        let sent = await session.sent.map(\.0)
        XCTAssertEqual(sent, [.up, .left, .ok, .back])
    }

    func testBacklogDropsClicksButNeverRelease() async throws {
        let session = MockTVSession()
        await session.setDelay(.milliseconds(30))
        let pipeline = CommandPipeline(session: session) { _, _ in }
        for _ in 0..<30 { await pipeline.enqueue(.volumeUp, .click) }
        await pipeline.enqueue(.volumeUp, .release)
        try await Task.sleep(for: .milliseconds(700))
        let sent = await session.sent
        XCTAssertLessThanOrEqual(sent.count, CommandPipeline.maxBacklog + 2)
        XCTAssertEqual(sent.last?.1, .release)
    }

    func testCancelStopsDelivery() async throws {
        let session = MockTVSession()
        await session.setDelay(.milliseconds(50))
        let pipeline = CommandPipeline(session: session) { _, _ in }
        for _ in 0..<5 { await pipeline.enqueue(.down, .click) }
        await pipeline.cancel()
        await pipeline.enqueue(.up, .click)
        try await Task.sleep(for: .milliseconds(300))
        let sent = await session.sent
        XCTAssertLessThanOrEqual(sent.count, 1, "At most the in-flight command completes")
        XCTAssertFalse(sent.contains { $0.0 == .up })
    }

    func testFailureIsReported() async throws {
        let session = MockTVSession()
        await session.setFailNext(.commandTimedOut)
        let expectation = expectation(description: "failure")
        let pipeline = CommandPipeline(session: session) { command, error in
            XCTAssertEqual(command, .home)
            XCTAssertEqual(error, .commandTimedOut)
            expectation.fulfill()
        }
        await pipeline.enqueue(.home, .click)
        await fulfillment(of: [expectation], timeout: 2)
    }
}

extension MockTVSession {
    func setFailNext(_ error: AppError) { failNext = error }
}

@MainActor
final class KeyHoldControllerTests: XCTestCase {
    private var sent: [(RemoteCommand, KeyAction)] = []
    private var sessionID = UUID()
    private var pressRelease = true

    private func makeController() -> KeyHoldController {
        KeyHoldController(
            send: { [unowned self] command, action in self.sent.append((command, action)); return true },
            supportsPressRelease: { [unowned self] _ in self.pressRelease },
            currentSessionID: { [unowned self] in self.sessionID }
        )
    }

    func testTapSendsClick() {
        let controller = makeController()
        controller.touchDown(.ok)
        controller.touchUp(.ok)
        XCTAssertEqual(sent.map(\.1), [.click])
    }

    func testHoldWithPressReleaseProtocol() async throws {
        let controller = makeController()
        controller.touchDown(.volumeUp)
        try await Task.sleep(for: .milliseconds(500))
        controller.touchUp(.volumeUp)
        XCTAssertEqual(sent.map(\.1), [.press, .release])
    }

    func testHoldWithoutPressReleaseRepeatsAndStops() async throws {
        pressRelease = false
        let controller = makeController()
        controller.touchDown(.down)
        try await Task.sleep(for: .milliseconds(900))
        controller.touchUp(.down)
        let count = sent.count
        XCTAssertGreaterThanOrEqual(count, 2)
        XCTAssertTrue(sent.allSatisfy { $0.1 == .click })
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(sent.count, count, "Repeating stops after release")
    }

    func testCancelAllReleasesHeldKey() async throws {
        let controller = makeController()
        controller.touchDown(.volumeDown)
        try await Task.sleep(for: .milliseconds(500))
        controller.cancelAll() // e.g. app went to background
        XCTAssertEqual(sent.map(\.1), [.press, .release])
    }

    // Review T1: a lost touch-up must never leave a key held (volume climbing forever).
    func testHoldIsCappedEvenWithoutTouchUp() async throws {
        let controller = KeyHoldController(
            send: { [unowned self] command, action in self.sent.append((command, action)); return true },
            supportsPressRelease: { [unowned self] _ in self.pressRelease },
            currentSessionID: { [unowned self] in self.sessionID },
            maximumHold: .milliseconds(600)
        )
        controller.touchDown(.volumeUp)
        try await Task.sleep(for: .milliseconds(1500)) // no touchUp at all
        XCTAssertEqual(sent.map(\.1), [.press, .release], "Released automatically at the cap")

        sent = []
        pressRelease = false
        controller.touchDown(.volumeDown)
        try await Task.sleep(for: .milliseconds(1500))
        let count = sent.count
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(sent.count, count, "Repeating stops at the cap")
    }

    func testNoCommandReachesANewSession() {
        let controller = makeController()
        controller.touchDown(.ok)
        sessionID = UUID() // user switched TV while the finger was down
        controller.touchUp(.ok)
        XCTAssertTrue(sent.isEmpty)
    }
}

@MainActor
final class DiscoveryMergeTests: XCTestCase {
    private func tv(_ id: String, platform: TVPlatform, host: String, airPlay: Bool = false, sources: Set<DiscoveredTV.Source> = [.probe]) -> DiscoveredTV {
        DiscoveredTV(id: TVDeviceID(platform: platform, uniqueID: id), platform: platform, name: id, manufacturer: nil, modelName: nil,
                     osVersion: nil, host: host, port: nil, macAddress: nil, mediaRendererLocation: nil, sources: sources,
                     advertisesAirPlay: airPlay, lastSeen: .now)
    }

    func testSameIdentityFromTwoSourcesMerges() {
        let service = DiscoveryService()
        service.merge(tv("abc", platform: .samsungTizen, host: "192.168.1.2", sources: [.ssdp]))
        service.merge(tv("abc", platform: .samsungTizen, host: "192.168.1.2", airPlay: true, sources: [.bonjour]))
        XCTAssertEqual(service.results.count, 1)
        XCTAssertEqual(service.results.first?.sources, [.ssdp, .bonjour])
        XCTAssertTrue(service.results.first?.advertisesAirPlay == true)
    }

    func testAirPlayOnlyRecordMergesIntoProtocolRecordAtSameAddress() {
        let service = DiscoveryService()
        service.merge(tv("airplay-1", platform: .unknown, host: "192.168.1.9", airPlay: true, sources: [.bonjour]))
        service.merge(tv("lg-1", platform: .lgWebOS, host: "192.168.1.9"))
        XCTAssertEqual(service.results.count, 1)
        XCTAssertEqual(service.results.first?.platform, .lgWebOS)
    }

    func testIPChangeKeepsIdentity() {
        let service = DiscoveryService()
        service.merge(tv("abc", platform: .samsungTizen, host: "192.168.1.2"))
        service.merge(tv("abc", platform: .samsungTizen, host: "192.168.1.40"))
        XCTAssertEqual(service.results.count, 1)
        XCTAssertEqual(service.results.first?.host, "192.168.1.40")
    }
}
