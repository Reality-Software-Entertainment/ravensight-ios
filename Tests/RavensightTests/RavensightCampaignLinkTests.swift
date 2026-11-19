import XCTest
@testable import Ravensight

/// The campaign link: a link id the studio passes with setCampaignLink(_:)
/// (from a universal link, a deep link or an install referrer it already
/// handles) goes once, as campaignLink on the next POST /session the client
/// opens for its own player, and is dropped only when that session opens.
/// Mirrors ravensight-js, which reads the same id from the page address.
final class RavensightCampaignLinkTests: XCTestCase {
    private static let linkId = "64b0000000000000000000a1"
    private static let otherId = "64b0000000000000000000b2"
    /// Everything the contract says to ignore.
    private static let invalid: [String?] = [
        nil,
        "",
        "abc",
        String(repeating: "a", count: 23),
        String(repeating: "a", count: 25),
        String(repeating: "g", count: 24),
        " " + linkId,
        linkId + " ",
        "64b0000000000000000000a\u{FF11}", // a full width digit is not hex
    ]

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var queueDirectory: URL!
    private let clock = FakeClock()
    private var nowMs: Int64 = 1_000_000_000

    override func setUp() {
        super.setUp()
        suiteName = "io.ravensight.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        queueDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ravensight-tests-\(UUID().uuidString)", isDirectory: true)
        Ravensight.resetForTesting()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: queueDirectory)
        Ravensight.resetForTesting()
        super.tearDown()
    }

    // MARK: Helpers

    private func json(_ object: [String: Any]) -> Data {
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func body(_ request: RavensightRequest) -> [String: Any] {
        guard let data = request.body else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// campaignLink of every POST /session, in order ("-" for none).
    private func sentLinks(_ transport: FakeTransport) -> [String] {
        return transport.requests(suffix: "/session").map { body($0)["campaignLink"] as? String ?? "-" }
    }

    private func makeCore(playtestToken: String? = nil) -> RavensightCore {
        var core = RavensightCore(config: RavensightCoreConfig(
            ingestKey: "gt_pub_test",
            apiUrl: "https://api.example.com",
            deviceId: "dev_0123456789abcdef0123",
            playtestToken: playtestToken
        ))
        core.random = { 0.5 }
        return core
    }

    private func boot(_ core: inout RavensightCore) {
        guard case .send(_, .settings) = core.nextStep(nowMs: nowMs) else { return XCTFail("expected settings") }
        _ = core.handle(response: RavensightResponse(status: 200, body: json(["trackingEnabled": true])), for: .settings, nowMs: nowMs)
    }

    /// Sends the session request the core asks for, as the client does, and
    /// answers it. Returns the request's body.
    @discardableResult
    private func session(_ core: inout RavensightCore, status: Int = 201, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        guard case .send(let request, .session) = core.nextStep(nowMs: nowMs, ignoringBackoff: true) else {
            XCTFail("expected a session request", file: file, line: line)
            return [:]
        }
        core.noteSessionInFlight()
        let answer = status == 201 ? json(["token": "sess", "expiresIn": 86_400]) : json(["error": "internal_error"])
        _ = core.handle(response: RavensightResponse(status: status, body: answer), for: .session, nowMs: nowMs)
        return body(request)
    }

    private func makeClient(
        transport: FakeTransport,
        ingestKey: String = "gt_live_test",
        environment: [String: String] = [:],
        configure: (inout RavensightConfiguration) -> Void = { _ in }
    ) -> RavensightClient {
        var configuration = RavensightConfiguration(ingestKey: ingestKey)
        configuration.apiUrl = "https://fake.test"
        configuration.gameVersion = "9.9.9"
        configuration.trackLifecycleEvents = false
        configuration.flushInterval = 0
        configure(&configuration)
        let clock = self.clock
        let client = RavensightClient(
            configuration: configuration,
            transport: transport,
            now: { clock.nowMs },
            defaults: defaults,
            environment: environment,
            isBackgroundLaunch: { false },
            installsLifecycleObservers: false,
            queueDirectory: queueDirectory,
            random: { 0.5 }
        )
        client.persistDelay = 0
        return client
    }

    private func settle(_ client: RavensightClient) {
        for _ in 0..<25 {
            let done = expectation(description: "barrier")
            client.onWorkQueue { done.fulfill() }
            wait(for: [done], timeout: 2)
        }
    }

    private func flushAndWait(_ client: RavensightClient) {
        let done = expectation(description: "flush settles")
        client.flush { done.fulfill() }
        wait(for: [done], timeout: 2)
        settle(client)
    }

    /// Lets the current session expire, then tracks so the next flush opens
    /// a fresh one.
    private func nextSession(_ client: RavensightClient) {
        clock.advance(seconds: 86_400 + 60)
        client.track("later")
        flushAndWait(client)
    }

    // MARK: Validation

    func testOnlyATwentyFourCharacterHexIdIsAcceptedAndItIsLowercased() {
        XCTAssertEqual(RavensightCore.validCampaignLink(Self.linkId.uppercased()), Self.linkId)
        XCTAssertEqual(RavensightCore.validCampaignLink(Self.linkId), Self.linkId)
        for value in Self.invalid {
            XCTAssertNil(RavensightCore.validCampaignLink(value), String(describing: value))
        }
    }

    // MARK: Core

    func testTheCoreSendsTheLinkOnceOnTheFirstSession() {
        var core = makeCore()
        XCTAssertTrue(core.setCampaignLink(Self.linkId.uppercased()))
        XCTAssertEqual(core.campaignLink, Self.linkId)
        core.track(name: "e", data: nil, nowMs: nowMs)
        boot(&core)
        XCTAssertEqual(session(&core)["campaignLink"] as? String, Self.linkId)
        XCTAssertNil(core.campaignLink, "dropped once the session opened")
        core.invalidateSession()
        XCTAssertNil(session(&core)["campaignLink"], "a later session carries none")
    }

    func testAnInvalidIdIsRefusedAndKeepsTheLinkAlreadyWaiting() {
        var core = makeCore()
        for value in Self.invalid {
            XCTAssertFalse(core.setCampaignLink(value), String(describing: value))
        }
        XCTAssertNil(core.campaignLink)
        XCTAssertTrue(core.setCampaignLink(Self.linkId))
        for value in Self.invalid { core.setCampaignLink(value) }
        XCTAssertEqual(core.campaignLink, Self.linkId)
        XCTAssertTrue(core.setCampaignLink(Self.otherId), "a valid call replaces it")
        XCTAssertEqual(core.campaignLink, Self.otherId)
    }

    func testAFailedSessionKeepsTheLinkForTheNextAttempt() {
        var core = makeCore()
        core.setCampaignLink(Self.linkId)
        core.track(name: "e", data: nil, nowMs: nowMs)
        boot(&core)
        XCTAssertEqual(session(&core, status: 500)["campaignLink"] as? String, Self.linkId)
        XCTAssertEqual(core.campaignLink, Self.linkId)
        XCTAssertEqual(session(&core, status: 0)["campaignLink"] as? String, Self.linkId)
        XCTAssertEqual(session(&core, status: 201)["campaignLink"] as? String, Self.linkId)
        XCTAssertNil(core.campaignLink)
    }

    func testA201WithoutATokenKeepsTheLink() {
        var core = makeCore()
        core.setCampaignLink(Self.linkId)
        core.noteSessionInFlight()
        core.settleCampaignLink(RavensightResponse(status: 201, body: json(["expiresIn": 60])))
        XCTAssertEqual(core.campaignLink, Self.linkId)
    }

    func testALinkSetWhileTheSessionIsInFlightGoesWithTheNextOne() {
        var core = makeCore()
        core.setCampaignLink(Self.linkId)
        core.track(name: "e", data: nil, nowMs: nowMs)
        boot(&core)
        guard case .send(let request, .session) = core.nextStep(nowMs: nowMs) else { return XCTFail("session") }
        core.noteSessionInFlight()
        core.setCampaignLink(Self.otherId)
        _ = core.handle(response: RavensightResponse(status: 201, body: json(["token": "s", "expiresIn": 86_400])), for: .session, nowMs: nowMs)
        XCTAssertEqual(body(request)["campaignLink"] as? String, Self.linkId)
        XCTAssertEqual(core.campaignLink, Self.otherId, "the newer link still waits")
        core.invalidateSession()
        XCTAssertEqual(session(&core)["campaignLink"] as? String, Self.otherId)
        XCTAssertNil(core.campaignLink)
    }

    func testAPlaytestSessionNeverCarriesItAndDoesNotClearIt() {
        var core = makeCore(playtestToken: "pt_token")
        XCTAssertTrue(core.setCampaignLink(Self.linkId))
        core.track(name: "e", data: nil, nowMs: nowMs)
        boot(&core)
        XCTAssertNil(session(&core)["campaignLink"])
        XCTAssertEqual(core.campaignLink, Self.linkId)
    }

    // MARK: Client

    func testTheFirstSessionCarriesItLowercasedAndALaterOneNone() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)
        XCTAssertTrue(client.setCampaignLink(Self.linkId.uppercased()))
        client.start()
        client.track("e")
        flushAndWait(client)
        nextSession(client)
        XCTAssertEqual(sentLinks(transport), [Self.linkId, "-"])
        XCTAssertEqual(transport.requests(suffix: "/session").first?.headers["X-API-Key"], "gt_live_test")
    }

    func testACallAfterTheFirstSessionGoesWithTheNextOne() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)
        client.start()
        client.track("e")
        flushAndWait(client)
        XCTAssertTrue(client.setCampaignLink(Self.linkId))
        nextSession(client)
        nextSession(client)
        XCTAssertEqual(sentLinks(transport), ["-", Self.linkId, "-"])
    }

    func testInvalidIdsReturnFalseSendNothingAndKeepAnEarlierLink() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)
        for value in Self.invalid {
            XCTAssertFalse(client.setCampaignLink(value), String(describing: value))
        }
        XCTAssertNil(client.campaignLinkPending)
        XCTAssertTrue(client.setCampaignLink(Self.linkId))
        for value in Self.invalid { client.setCampaignLink(value) }
        XCTAssertEqual(client.campaignLinkPending, Self.linkId)
        client.start()
        client.track("e")
        flushAndWait(client)
        XCTAssertEqual(sentLinks(transport), [Self.linkId])
    }

    func testNoLinkSetSendsNoField() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)
        client.start()
        client.track("e")
        flushAndWait(client)
        XCTAssertEqual(sentLinks(transport), ["-"])
    }

    func testAFailedSessionKeepsItAndTheNextSuccessfulOneCarriesIt() {
        let transport = FakeTransport()
        transport.sessionStatus = 500
        let client = makeClient(transport: transport)
        client.setCampaignLink(Self.linkId)
        client.start()
        client.track("e")
        flushAndWait(client)
        XCTAssertEqual(client.campaignLinkPending, Self.linkId)
        transport.sessionStatus = 201
        flushAndWait(client)
        XCTAssertNil(client.campaignLinkPending)
        nextSession(client)
        XCTAssertEqual(sentLinks(transport), [Self.linkId, Self.linkId, "-"])
    }

    func testALinkReplacedWhileTheSessionIsOutGoesWithTheNextSession() {
        let transport = FakeTransport()
        transport.holdSuffix = "/session"
        let client = makeClient(transport: transport)
        client.setCampaignLink(Self.linkId)
        client.start()
        client.track("e")
        client.flush()
        settle(client)
        XCTAssertEqual(transport.heldCount, 1)
        XCTAssertTrue(client.setCampaignLink(Self.otherId))
        settle(client)
        transport.release(RavensightResponse(status: 201, body: json(["token": "held", "expiresIn": 86_400])))
        settle(client)
        XCTAssertEqual(client.campaignLinkPending, Self.otherId)
        nextSession(client)
        XCTAssertEqual(sentLinks(transport), [Self.linkId, Self.otherId])
    }

    func testOptInSendsNothingBeforeTheYesAndTheLinkGoesWithTheFirstSessionAfter() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport, ingestKey: "gt_pub_test") { $0.consent = .optIn }
        client.start()
        XCTAssertTrue(client.setCampaignLink(Self.linkId))
        client.track("before")
        flushAndWait(client)
        XCTAssertTrue(transport.requests.isEmpty, "no session before the yes")
        client.setTrackingEnabled(true)
        client.track("after")
        flushAndWait(client)
        XCTAssertEqual(sentLinks(transport), [Self.linkId])
    }

    func testAnOptedOutPlayerSendsNothing() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)
        client.setTrackingEnabled(false)
        XCTAssertTrue(client.setCampaignLink(Self.linkId))
        client.start()
        client.track("e")
        flushAndWait(client)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAStoppedClientSendsNothing() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport) { $0.enabled = false }
        XCTAssertTrue(client.setCampaignLink(Self.linkId))
        client.start()
        client.track("e")
        flushAndWait(client)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testWithoutAKeyNothingIsSent() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport, ingestKey: "")
        XCTAssertTrue(client.setCampaignLink(Self.linkId))
        client.start()
        client.track("e")
        client.flush()
        let done = expectation(description: "barrier")
        client.onWorkQueue { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAPlaytestRunNeverSendsIt() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport, environment: [
            "RAVENSIGHT_PLAYTEST_TOKEN": "pt_token", "RAVENSIGHT_PLAYTEST_RUN_ID": "run_7",
        ])
        XCTAssertTrue(client.setCampaignLink(Self.linkId))
        client.start()
        client.track("e")
        flushAndWait(client)
        XCTAssertEqual(sentLinks(transport), ["-"])
        XCTAssertEqual(transport.requests(suffix: "/session").first?.headers["X-Ravensight-Playtest"], "pt_token")
    }

    func testNothingIsSaved() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport) { $0.persistQueue = true }
        client.setCampaignLink(Self.linkId)
        client.start()
        transport.sessionStatus = 500
        client.track("e")
        flushAndWait(client)
        XCTAssertEqual(client.campaignLinkPending, Self.linkId)
        let saved = defaults.dictionaryRepresentation().values.map { "\($0)" }.joined(separator: " ")
        XCTAssertFalse(saved.lowercased().contains(Self.linkId))
        let files = (try? FileManager.default.contentsOfDirectory(at: queueDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            XCTAssertFalse(text.contains(Self.linkId), file.lastPathComponent)
        }
    }

    func testASessionAnswerFromBeforeAResetStillUsesUpTheLink() {
        let transport = FakeTransport()
        transport.holdSuffix = "/session"
        let client = makeClient(transport: transport)
        client.setCampaignLink(Self.linkId)
        client.start()
        client.track("e")
        client.flush()
        settle(client)
        XCTAssertEqual(transport.heldCount, 1)
        client.resetDeviceId()
        settle(client)
        transport.release(RavensightResponse(status: 201, body: json(["token": "old", "expiresIn": 86_400])))
        settle(client)
        XCTAssertNil(client.campaignLinkPending, "the server already has it")
        client.track("after_reset")
        flushAndWait(client)
        XCTAssertEqual(sentLinks(transport), [Self.linkId, "-"])
    }

    // MARK: Facade

    func testTheFacadeHoldsALinkSetBeforeStart() {
        XCTAssertFalse(Ravensight.setCampaignLink("abc"))
        XCTAssertTrue(Ravensight.setCampaignLink(Self.linkId.uppercased()))
        let transport = FakeTransport()
        let client = makeClient(transport: transport)
        _ = Ravensight.start(client.configuration) { _ in client }
        client.track("e")
        flushAndWait(client)
        XCTAssertTrue(Ravensight.setCampaignLink(Self.otherId))
        XCTAssertFalse(Ravensight.setCampaignLink(String(repeating: "g", count: 24)))
        nextSession(client)
        XCTAssertEqual(sentLinks(transport), [Self.linkId, Self.otherId])
    }
}
