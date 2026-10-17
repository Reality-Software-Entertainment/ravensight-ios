import XCTest
@testable import Ravensight

/// The 0.4.0 public-build contract: inert without a key, opt-in consent,
/// the distribution label, a refused key ending the run, backoff jitter,
/// rs_event_id on every event and the 8 KB event cap.
final class RavensightPublicBuildTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var queueDirectory: URL!
    private let clock = FakeClock()
    private var nowMs: Int64 = 1_000_000_000

    override func setUp() {
        super.setUp()
        suiteName = "io.ravensight.public.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        queueDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ravensight-public-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: queueDirectory)
        super.tearDown()
    }

    // MARK: Helpers

    private func makeClient(
        transport: FakeTransport,
        key: String = "gt_pub_test",
        random: @escaping () -> Double = { 0.5 },
        configure: (inout RavensightConfiguration) -> Void = { _ in }
    ) -> RavensightClient {
        var configuration = RavensightConfiguration(ingestKey: key)
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
            environment: [:],
            isBackgroundLaunch: { false },
            installsLifecycleObservers: false,
            queueDirectory: queueDirectory,
            random: random
        )
        client.persistDelay = 0
        settle(client)
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

    /// Every event sent in a batch, with its data.
    private func sentEvents(_ transport: FakeTransport) -> [(name: String, data: [String: Any])] {
        return transport.requests(suffix: "/track/batch").flatMap { request -> [(name: String, data: [String: Any])] in
            guard let body = request.body,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let events = object["events"] as? [[String: Any]] else { return [] }
            return events.map { (name: $0["event"] as? String ?? "", data: $0["data"] as? [String: Any] ?? [:]) }
        }
    }

    private func sessionBody(_ transport: FakeTransport) -> [String: Any]? {
        guard let body = transport.requests(suffix: "/session").last?.body else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    /// Every UserDefaults key the SDK owns in the test suite.
    private func storedKeys() -> [String] {
        return defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("ravensight_") }.sorted()
    }

    private func queueFiles() -> [URL] {
        return (try? FileManager.default.contentsOfDirectory(at: queueDirectory, includingPropertiesForKeys: nil)) ?? []
    }

    private func makeCore(distribution: String? = nil) -> RavensightCore {
        var core = RavensightCore(config: RavensightCoreConfig(
            ingestKey: "gt_pub_test",
            apiUrl: "https://api.example.com",
            deviceId: "dev_0123456789abcdef0123",
            distribution: distribution,
            eventIds: RavensightEventIds(deviceId: "dev_0123456789abcdef0123", startSec: 1_700_000_000, nonce: "a1b2c3d4")
        ))
        core.random = { 0.5 }
        return core
    }

    private func json(_ object: [String: Any]) -> Data {
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func boot(_ core: inout RavensightCore) {
        guard case .send(_, .settings) = core.nextStep(nowMs: nowMs) else { return XCTFail("expected settings") }
        _ = core.handle(response: RavensightResponse(status: 200, body: json(["trackingEnabled": true])), for: .settings, nowMs: nowMs)
    }

    private func openSession(_ core: inout RavensightCore) -> RavensightRequest? {
        guard case .send(let request, .session) = core.nextStep(nowMs: nowMs) else {
            XCTFail("expected a session request")
            return nil
        }
        _ = core.handle(response: RavensightResponse(status: 201, body: json(["token": "sess", "expiresIn": 86_400])), for: .session, nowMs: nowMs)
        return request
    }

    private func batchIds(_ request: RavensightRequest) -> [String] {
        guard let body = request.body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let events = object["events"] as? [[String: Any]] else { return [] }
        return events.compactMap { ($0["data"] as? [String: Any])?["rs_event_id"] as? String }
    }

    // MARK: 1. Inert without a key

    func testEmptyKeyIsInert() {
        let transport = FakeTransport()
        for key in ["", "   "] {
            let client = makeClient(transport: transport, key: key) { $0.persistQueue = true }
            client.start()
            XCTAssertFalse(client.track("ignored", data: ["a": 1]))
            client.submitFeedback("hello")
            flushAndWait(client)
            XCTAssertTrue(client.isInert)
            XCTAssertFalse(client.isEnabled)
            XCTAssertEqual(client.statusReason, "no_key")
            XCTAssertEqual(client.deviceId, "")
            XCTAssertEqual(client.queuedEventCount, 0)
        }
        XCTAssertTrue(transport.requests.isEmpty, "no request of any kind")
        XCTAssertEqual(storedKeys(), [], "no device id or anything else stored")
        XCTAssertTrue(queueFiles().isEmpty, "no queue file, even with persistQueue")
    }

    func testInertResetForgetsAndMintsNothing() {
        defaults.set("dev_old", forKey: RavensightClient.deviceIdKey)
        let client = makeClient(transport: FakeTransport(), key: "") { $0.optional = true }
        XCTAssertEqual(client.deviceId, "dev_old", "an existing id is read, never created")
        XCTAssertEqual(client.resetDeviceId(), "")
        XCTAssertEqual(storedKeys(), [])
    }

    func testKeyOnlyCallerWritesNoNewKeys() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)
        client.start()
        client.track("e")
        flushAndWait(client)
        XCTAssertEqual(storedKeys(), [RavensightClient.deviceIdKey], "consent defaults to opt_out: only the device id, as before")
        XCTAssertNil(sessionBody(transport)?["distribution"], "no distribution unless one is set")
    }

    // MARK: 2. Opt-in consent

    func testOptInSendsNothingBeforeTheYes() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport) {
            $0.consent = .optIn
            $0.persistQueue = true
        }
        client.start()
        XCTAssertFalse(client.track("before_yes"))
        flushAndWait(client)
        XCTAssertTrue(transport.requests.isEmpty, "no settings call, no session")
        XCTAssertEqual(storedKeys(), [], "no device id created, nothing saved")
        XCTAssertTrue(queueFiles().isEmpty)
        XCTAssertEqual(client.deviceId, "")
        XCTAssertTrue(client.isOptedOut)
        XCTAssertEqual(client.statusReason, "disabled")
    }

    func testOptInYesPersistsStartsAndQueuesEventsTrackedRightAfter() {
        let transport = FakeTransport()
        transport.holdSuffix = "/settings"
        let client = makeClient(transport: transport) { $0.consent = .optIn }
        client.start()
        XCTAssertFalse(client.track("dropped_before_yes"))
        client.setTrackingEnabled(true)
        XCTAssertTrue(defaults.bool(forKey: RavensightClient.optInKey), "the yes is saved before the call returns")
        let id = client.deviceId
        XCTAssertTrue(id.hasPrefix("dev_"), "the id is made at the yes")
        XCTAssertEqual(defaults.string(forKey: RavensightClient.deviceIdKey), id)
        XCTAssertTrue(client.track("right_after_yes"))
        settle(client)
        XCTAssertEqual(transport.heldCount, 1, "the settings check is out")
        XCTAssertEqual(client.queuedEventCount, 1, "queued while the settings check runs")

        transport.release(RavensightResponse(status: 200, body: json(["trackingEnabled": true])))
        flushAndWait(client)
        XCTAssertEqual(sentEvents(transport).map { $0.name }, ["right_after_yes"])
        XCTAssertEqual(sessionBody(transport)?["deviceId"] as? String, id)

        // The next launch remembers the yes.
        let next = makeClient(transport: FakeTransport()) { $0.consent = .optIn }
        XCTAssertFalse(next.isOptedOut)
        XCTAssertEqual(next.deviceId, id)
    }

    func testOptInRevokeKeepsTheDeviceIdAndResetIsSeparate() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport) { $0.consent = .optIn }
        client.start()
        client.setTrackingEnabled(true)
        let id = client.deviceId
        client.track("e")
        flushAndWait(client)
        let before = transport.requests.count

        client.setTrackingEnabled(false)
        settle(client)
        XCTAssertFalse(defaults.bool(forKey: RavensightClient.optInKey))
        XCTAssertEqual(client.deviceId, id, "saying no keeps the id")
        XCTAssertEqual(defaults.string(forKey: RavensightClient.deviceIdKey), id)
        XCTAssertFalse(client.track("after_no"))
        flushAndWait(client)
        XCTAssertEqual(transport.requests.count, before)

        XCTAssertEqual(client.resetDeviceId(), "", "reset before a yes forgets and mints nothing")
        XCTAssertNil(defaults.string(forKey: RavensightClient.deviceIdKey))
        XCTAssertEqual(client.deviceId, "")
    }

    func testSavedChoiceFollowsTheConsentMode() {
        XCTAssertTrue(RavensightClient.savedChoice(defaults, consent: .optOut))
        XCTAssertFalse(RavensightClient.savedChoice(defaults, consent: .optIn))
        RavensightClient.saveTrackingEnabled(true, defaults: defaults, consent: nil)
        XCTAssertTrue(RavensightClient.savedChoice(defaults, consent: .optIn))
        RavensightClient.saveTrackingEnabled(false, defaults: defaults, consent: nil)
        XCTAssertFalse(RavensightClient.savedChoice(defaults, consent: .optIn))
        XCTAssertFalse(RavensightClient.savedChoice(defaults, consent: .optOut))
    }

    // MARK: 3. Distribution

    func testDistributionIsSentOnTheSessionBody() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport) { $0.distribution = "  testflight  " }
        client.start()
        client.track("e")
        flushAndWait(client)
        XCTAssertEqual(sessionBody(transport)?["distribution"] as? String, "testflight")
    }

    func testInvalidDistributionIsIgnored() {
        XCTAssertEqual(RavensightCore.validDistribution(String(repeating: "a", count: 40)), String(repeating: "a", count: 40))
        XCTAssertNil(RavensightCore.validDistribution(String(repeating: "a", count: 41)))
        XCTAssertNil(RavensightCore.validDistribution("bad\nlabel"))
        XCTAssertNil(RavensightCore.validDistribution("bad\u{7f}"))
        XCTAssertNil(RavensightCore.validDistribution("   "))
        XCTAssertNil(RavensightCore.validDistribution(nil))

        var core = makeCore(distribution: String(repeating: "x", count: 41))
        boot(&core)
        core.track(name: "e", data: nil, nowMs: nowMs)
        let request = openSession(&core)
        let body = request?.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertNotNil(body?["deviceId"])
        XCTAssertNil(body?["distribution"])
    }

    // MARK: 4. A refused key ends the run

    func testSessionForbiddenEndsTheRunAndDeletesTheSavedQueue() {
        let transport = FakeTransport()
        transport.sessionStatus = 403
        transport.sessionError = "invalid_api_key"
        let client = makeClient(transport: transport) { $0.persistQueue = true }
        client.start()
        client.track("a")
        client.track("b")
        flushAndWait(client)
        XCTAssertEqual(client.statusReason, "invalid_key")
        XCTAssertEqual(client.queuedEventCount, 0, "queue cleared")
        XCTAssertTrue(queueFiles().isEmpty, "nothing left to save")
        let before = transport.requests.count
        XCTAssertFalse(client.track("c"))
        flushAndWait(client)
        client.handleWillTerminate(holdSeconds: 0.2)
        settle(client)
        XCTAssertEqual(transport.requests.count, before, "no retry loop, not even an explicit flush or the quit")
        XCTAssertTrue(queueFiles().isEmpty)
    }

    func testPlaytestRefusalAndKillSwitchAreNotKeyRefusals() {
        var core = makeCore()
        boot(&core)
        core.track(name: "e", data: nil, nowMs: nowMs)
        guard case .send(_, .session) = core.nextStep(nowMs: nowMs) else { return XCTFail("expected a session request") }
        let effects = core.handle(
            response: RavensightResponse(status: 403, body: json(["error": "playtest_job_closed"])),
            for: .session, nowMs: nowMs
        )
        XCTAssertEqual(effects, [.stopped("playtest_job_closed")])
        XCTAssertFalse(core.keyRefused)
    }

    func testBatchUnauthorizedStillRefreshesTheSession() {
        var core = makeCore()
        boot(&core)
        core.track(name: "e", data: nil, nowMs: nowMs)
        _ = openSession(&core)
        guard case .send(_, .batch(let count)) = core.nextStep(nowMs: nowMs) else { return XCTFail("expected a batch") }
        _ = core.handle(response: RavensightResponse(status: 401), for: .batch(count: count), nowMs: nowMs)
        XCTAssertNil(core.stopReason)
        XCTAssertFalse(core.keyRefused)
        guard case .send(_, .session) = core.nextStep(nowMs: nowMs) else { return XCTFail("expected a fresh session") }
        XCTAssertEqual(core.pendingEvents.count, 1)
    }

    // MARK: 5. Jitter

    private func firstBackoffWait(random: Double) -> Int64 {
        var core = makeCore()
        core.random = { random }
        boot(&core)
        core.track(name: "e", data: nil, nowMs: nowMs)
        guard case .send(_, .session) = core.nextStep(nowMs: nowMs) else {
            XCTFail("expected a session request")
            return 0
        }
        _ = core.handle(response: RavensightResponse(status: 500), for: .session, nowMs: nowMs)
        return core.nextAttemptAtMs - nowMs
    }

    func testBackoffJitterStaysWithinTwentyPercent() {
        XCTAssertEqual(firstBackoffWait(random: 0), 8_000)
        XCTAssertEqual(firstBackoffWait(random: 0.5), 10_000, "a fixed 0.5 is the old backoff exactly")
        XCTAssertEqual(firstBackoffWait(random: 0.999_999), 12_000, accuracy: 1)
        for _ in 0..<200 {
            let wait = firstBackoffWait(random: Double.random(in: 0..<1))
            XCTAssertGreaterThanOrEqual(wait, 8_000)
            XCTAssertLessThanOrEqual(wait, 12_000)
        }
    }

    func testJitterNeverPassesTheCeiling() {
        var core = makeCore()
        core.random = { 0.999_999 }
        boot(&core)
        core.track(name: "e", data: nil, nowMs: nowMs)
        for _ in 0..<12 {
            guard case .send(_, .session) = core.nextStep(nowMs: nowMs, ignoringBackoff: true) else {
                return XCTFail("expected a session request")
            }
            _ = core.handle(response: RavensightResponse(status: 500), for: .session, nowMs: nowMs)
            XCTAssertLessThanOrEqual(core.nextAttemptAtMs - nowMs, RavensightCore.maxBackoffMs)
        }
    }

    func testRetryAfterIsHonouredExactly() {
        var core = makeCore()
        core.random = { 0 }
        boot(&core)
        core.track(name: "e", data: nil, nowMs: nowMs)
        guard case .send(_, .session) = core.nextStep(nowMs: nowMs) else { return XCTFail("expected a session request") }
        _ = core.handle(response: RavensightResponse(status: 429, retryAfter: "60"), for: .session, nowMs: nowMs)
        XCTAssertEqual(core.nextAttemptAtMs - nowMs, 60_000)
    }

    // MARK: 6. rs_event_id

    func testEveryEventCarriesAWellFormedUniqueId() {
        var core = makeCore()
        for index in 0..<5 { core.track(name: "e", data: ["i": index], nowMs: nowMs) }
        let ids = core.pendingEvents.compactMap { $0.data["rs_event_id"] as? String }
        XCTAssertEqual(ids.count, 5)
        XCTAssertEqual(Set(ids).count, 5)
        for id in ids {
            XCTAssertTrue(RavensightEventIds.isValid(id), id)
            XCTAssertTrue(id.hasPrefix("dev_0123456789ab-"), "first 16 characters of the device id")
            XCTAssertTrue(id.contains("-a1b2c3d4-"), "the launch nonce")
        }
        XCTAssertEqual(ids.first, "dev_0123456789ab-\(String(1_700_000_000, radix: 16))-a1b2c3d4-1")
    }

    func testCallerValueUnderTheKeyIsReplaced() {
        var core = makeCore()
        core.track(name: "e", data: ["rs_event_id": "mine"], nowMs: nowMs)
        XCTAssertNotEqual(core.pendingEvents.first?.data["rs_event_id"] as? String, "mine")
    }

    func testNonceIsEightHexFromTheSecureSource() {
        let nonces = (0..<20).map { _ in RavensightEventIds.secureNonce() }
        for nonce in nonces {
            XCTAssertEqual(nonce.count, 8)
            XCTAssertNotNil(nonce.range(of: "^[0-9a-f]{8}$", options: .regularExpression))
        }
        XCTAssertGreaterThan(Set(nonces).count, 1)
    }

    func testPrefixKeepsOnlyAllowedCharacters() {
        XCTAssertEqual(RavensightEventIds.prefix(for: "pt-run.42/x"), "pt-run42x")
        XCTAssertEqual(RavensightEventIds.prefix(for: ""), "")
        let ids = RavensightEventIds(deviceId: "pt-run.42/x é", startSec: 1)
        XCTAssertTrue(RavensightEventIds.isValid(ids.next()))
        XCTAssertTrue(RavensightEventIds.isValid(RavensightEventIds(deviceId: "", startSec: 0).next()))
    }

    func testAResendCarriesTheSameIds() {
        var core = makeCore()
        boot(&core)
        for index in 0..<3 { core.track(name: "e", data: ["i": index], nowMs: nowMs) }
        _ = openSession(&core)
        guard case .send(let first, .batch(let count)) = core.nextStep(nowMs: nowMs) else { return XCTFail("expected a batch") }
        _ = core.handle(response: RavensightResponse(status: 500), for: .batch(count: count), nowMs: nowMs)
        guard case .send(let second, .batch) = core.nextStep(nowMs: nowMs, ignoringBackoff: true) else { return XCTFail("expected a resend") }
        XCTAssertEqual(batchIds(first).count, 3)
        XCTAssertEqual(batchIds(first), batchIds(second))
    }

    func testExitEventKeepsItsIdAcrossRetries() {
        var core = makeCore()
        boot(&core)
        core.setPendingExit(.init(sessionToken: "old", timestamp: 100, retry: true))
        guard case .send(let first, .exit) = core.nextStep(nowMs: nowMs) else { return XCTFail("expected the exit") }
        _ = core.handle(response: RavensightResponse(status: 0), for: .exit(retry: true), nowMs: nowMs)
        guard case .send(let second, .exit) = core.nextStep(nowMs: nowMs, ignoringBackoff: true) else { return XCTFail("expected a retry") }
        XCTAssertEqual(batchIds(first).count, 1)
        XCTAssertTrue(RavensightEventIds.isValid(batchIds(first)[0]))
        XCTAssertEqual(batchIds(first), batchIds(second))
    }

    func testRestoreKeepsSavedIdsAndStampsOldOnes() {
        var core = makeCore()
        core.restore(
            events: [
                RavensightEvent(name: "kept", data: ["rs_event_id": "saved-id-1"], timestamp: 1),
                RavensightEvent(name: "from_0_3", data: [:], timestamp: 2),
            ],
            sessionToken: nil, expiresAtMs: 0, nowMs: nowMs
        )
        let ids = core.pendingEvents.compactMap { $0.data["rs_event_id"] as? String }
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids[0], "saved-id-1")
        XCTAssertTrue(RavensightEventIds.isValid(ids[1]))
    }

    func testIdsSurviveThePersistedQueueAndReload() {
        // First launch: events queued, never sent (the app dies first).
        let first = makeClient(transport: FakeTransport()) { $0.persistQueue = true }
        XCTAssertTrue(first.track("a", data: ["x": 1]))
        XCTAssertTrue(first.track("b"))
        settle(first)
        var savedIds: [String] = []
        let read = expectation(description: "read")
        first.onWorkQueue {
            savedIds = first.core.pendingEvents.compactMap { $0.data["rs_event_id"] as? String }
            read.fulfill()
        }
        wait(for: [read], timeout: 2)
        XCTAssertEqual(savedIds.count, 2)
        XCTAssertEqual(queueFiles().count, 1)

        // Next launch: the same events go out with the same ids.
        let transport = FakeTransport()
        let second = makeClient(transport: transport) { $0.persistQueue = true }
        second.start()
        flushAndWait(second)
        let sent = sentEvents(transport)
        XCTAssertEqual(sent.map { $0.name }, ["a", "b"])
        XCTAssertEqual(sent.compactMap { $0.data["rs_event_id"] as? String }, savedIds)
    }

    func testClientSentEventsCarryIds() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport) { $0.trackLifecycleEvents = true }
        client.start()
        client.track("level_completed", data: ["level": 1])
        flushAndWait(client)
        let sent = sentEvents(transport)
        XCTAssertEqual(sent.map { $0.name }, ["game_started", "level_completed"])
        for event in sent {
            XCTAssertTrue(RavensightEventIds.isValid(event.data["rs_event_id"] as? String ?? ""))
        }
        XCTAssertEqual(sent[1].data["level"] as? Int, 1)
    }

    // MARK: 7. The 8 KB cap

    func testOversizeEventIsDroppedWithTheFailureCallback() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)
        var outcomes: [RavensightFlushOutcome] = []
        let reported = expectation(description: "onFlush")
        client.onFlush = { outcome in
            if outcome.error == "event_too_large" {
                outcomes.append(outcome)
                reported.fulfill()
            }
        }
        client.start()
        XCTAssertFalse(client.track("huge", data: ["blob": String(repeating: "x", count: 8_200)]))
        XCTAssertTrue(client.track("small", data: ["blob": String(repeating: "x", count: 100)]))
        wait(for: [reported], timeout: 2)
        flushAndWait(client)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.sent, 0)
        XCTAssertEqual(client.stats.droppedEvents, 1)
        XCTAssertEqual(sentEvents(transport).map { $0.name }, ["small"], "never sent")
    }

    func testCapIsMeasuredOnTheDataWithItsId() {
        var core = makeCore()
        // Find the largest blob that still fits once the id is added.
        let probe = RavensightCore.eventBytes(["blob": "", "rs_event_id": "dev_0123456789ab-6553f100-a1b2c3d4-1"])
        let fits = RavensightCore.maxEventBytes - probe
        XCTAssertTrue(core.track(name: "fits", data: ["blob": String(repeating: "y", count: fits)], nowMs: nowMs))
        XCTAssertEqual(RavensightCore.eventBytes(core.pendingEvents[0].data), RavensightCore.maxEventBytes)
        XCTAssertFalse(core.track(name: "over", data: ["blob": String(repeating: "y", count: fits + 1)], nowMs: nowMs))
        XCTAssertEqual(core.pendingEvents.count, 1)
        XCTAssertEqual(core.stats.dropped, 1)
        XCTAssertEqual(RavensightCore.eventBytes(["path": "a/b"]), 14, "slashes are not escaped")
    }
}
