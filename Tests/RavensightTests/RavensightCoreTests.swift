import XCTest
@testable import Ravensight

/// Drives the pure protocol state machine with a fake clock and hand built
/// responses. No URLSession, no timers, no threads.
final class RavensightCoreTests: XCTestCase {
    private var nowMs: Int64 = 1_000_000_000

    private func makeCore(maxQueueSize: Int = 500) -> RavensightCore {
        return RavensightCore(config: RavensightCoreConfig(
            ingestKey: "gt_live_test_key",
            apiUrl: "https://api.example.com",
            gameVersion: "2.3.4",
            platform: "test",
            deviceId: "dev_test",
            maxQueueSize: maxQueueSize
        ))
    }

    private func jsonBody(_ object: [String: Any]) -> Data {
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func decode(_ data: Data?) -> [String: Any] {
        guard let data = data else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Answers the boot settings check.
    private func boot(_ core: inout RavensightCore, trackingEnabled: Bool = true) {
        guard case .send(let request, .settings) = core.nextStep(nowMs: nowMs) else {
            return XCTFail("expected a settings check first")
        }
        XCTAssertEqual(request.method, "GET")
        XCTAssertTrue(request.url.hasSuffix("/api/v1/settings"))
        let response = RavensightResponse(
            status: 200,
            body: jsonBody(["trackingEnabled": trackingEnabled])
        )
        _ = core.handle(response: response, for: .settings, nowMs: nowMs)
    }

    /// Answers the next step, which must be a session request, with a fresh
    /// long lived session.
    private func openSession(_ core: inout RavensightCore, token: String = "sess_token") {
        guard case .send(let request, .session) = core.nextStep(nowMs: nowMs) else {
            return XCTFail("expected a session request")
        }
        XCTAssertEqual(request.method, "POST")
        XCTAssertTrue(request.url.hasSuffix("/api/v1/session"))
        let response = RavensightResponse(
            status: 201,
            body: jsonBody(["token": token, "expiresIn": 86_400])
        )
        let effects = core.handle(response: response, for: .session, nowMs: nowMs)
        XCTAssertEqual(effects, [.sessionReady])
    }

    /// Answers the next step, which must be a batch of the given size, and
    /// returns the request for inspection.
    @discardableResult
    private func expectBatch(
        _ core: inout RavensightCore,
        count: Int,
        respond status: Int,
        body: Data? = nil,
        retryAfter: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (RavensightRequest, [RavensightCore.Effect]) {
        guard case .send(let request, .batch(let actual)) = core.nextStep(nowMs: nowMs) else {
            XCTFail("expected a batch request", file: file, line: line)
            return (RavensightRequest(method: "", url: ""), [])
        }
        XCTAssertEqual(actual, count, "batch size", file: file, line: line)
        let effects = core.handle(
            response: RavensightResponse(status: status, body: body, retryAfter: retryAfter),
            for: .batch(count: actual),
            nowMs: nowMs
        )
        return (request, effects)
    }

    // MARK: Boot and kill switch

    func testFirstStepIsSettingsCheck() {
        let core = makeCore()
        guard case .send(let request, .settings) = core.nextStep(nowMs: nowMs) else {
            return XCTFail("expected settings check")
        }
        XCTAssertEqual(request.url, "https://api.example.com/api/v1/settings")
        XCTAssertEqual(request.headers["X-API-Key"], "gt_live_test_key")
        XCTAssertNil(request.body)
    }

    func testKillSwitchDisablesTrackingAndClearsQueue() {
        var core = makeCore()
        core.track(name: "one", data: nil, nowMs: nowMs)
        core.track(name: "two", data: nil, nowMs: nowMs)

        boot(&core, trackingEnabled: false)
        // Re-answer manually to check the effect surfaced.
        XCTAssertFalse(core.trackingEnabled)
        XCTAssertTrue(core.pendingEvents.isEmpty)
        XCTAssertEqual(core.nextStep(nowMs: nowMs), .idle)
        XCTAssertFalse(core.track(name: "three", data: nil, nowMs: nowMs))
    }

    func testKillSwitchEmitsTrackingDisabledEffect() {
        var core = makeCore()
        guard case .send(_, .settings) = core.nextStep(nowMs: nowMs) else {
            return XCTFail("expected settings check")
        }
        let effects = core.handle(
            response: RavensightResponse(status: 200, body: jsonBody(["trackingEnabled": false])),
            for: .settings,
            nowMs: nowMs
        )
        XCTAssertEqual(effects, [.trackingDisabled])
    }

    func testSettingsFailureAssumesTrackingEnabled() {
        var core = makeCore()
        core.track(name: "boot", data: nil, nowMs: nowMs)
        guard case .send(_, .settings) = core.nextStep(nowMs: nowMs) else {
            return XCTFail("expected settings check")
        }
        _ = core.handle(response: .networkFailure("offline"), for: .settings, nowMs: nowMs)
        XCTAssertTrue(core.trackingEnabled)
        guard case .send(_, .session) = core.nextStep(nowMs: nowMs) else {
            return XCTFail("expected session creation after settings failure")
        }
    }

    // MARK: Session

    func testSessionRequestCarriesDeviceAndVersion() {
        var core = makeCore()
        core.track(name: "boot", data: nil, nowMs: nowMs)
        boot(&core)
        guard case .send(let request, .session) = core.nextStep(nowMs: nowMs) else {
            return XCTFail("expected session request")
        }
        XCTAssertEqual(request.headers["X-API-Key"], "gt_live_test_key")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        let body = decode(request.body)
        XCTAssertEqual(body["deviceId"] as? String, "dev_test")
        XCTAssertEqual(body["gameVersion"] as? String, "2.3.4")
        XCTAssertEqual(body["platform"] as? String, "test")
    }

    func testSessionExpiryFromAbsoluteExpiresAt() {
        var core = makeCore()
        core.track(name: "boot", data: nil, nowMs: nowMs)
        boot(&core)
        guard case .send(_, .session) = core.nextStep(nowMs: nowMs) else {
            return XCTFail("expected session request")
        }
        let expiresAtSeconds = nowMs / 1000 + 7200
        _ = core.handle(
            response: RavensightResponse(status: 201, body: jsonBody([
                "token": "sess_abc", "expiresAt": expiresAtSeconds,
            ])),
            for: .session,
            nowMs: nowMs
        )
        XCTAssertEqual(core.sessionExpiresAtMs, expiresAtSeconds * 1000)
        XCTAssertTrue(core.isSessionValid(nowMs: nowMs))
    }

    func testSessionExpiryDefaultsToOneDay() {
        XCTAssertEqual(
            RavensightCore.resolveExpiryMs(["token": "t"], nowMs: nowMs),
            nowMs + 86_400_000
        )
        XCTAssertEqual(
            RavensightCore.resolveExpiryMs(["expiresIn": 3600], nowMs: nowMs),
            nowMs + 3_600_000
        )
    }

    func testSessionExpiresNearDeadline() {
        var core = makeCore()
        core.track(name: "boot", data: nil, nowMs: nowMs)
        boot(&core)
        openSession(&core)
        let expiry = core.sessionExpiresAtMs
        XCTAssertTrue(core.isSessionValid(nowMs: expiry - 6000))
        XCTAssertFalse(core.isSessionValid(nowMs: expiry - 1000), "expiry skew applies")
        XCTAssertFalse(core.isSessionValid(nowMs: expiry + 1))
    }

    func testMalformedSessionResponseSchedulesRetry() {
        var core = makeCore()
        core.track(name: "boot", data: nil, nowMs: nowMs)
        boot(&core)
        guard case .send(_, .session) = core.nextStep(nowMs: nowMs) else {
            return XCTFail("expected session request")
        }
        let effects = core.handle(
            response: RavensightResponse(status: 201, body: jsonBody(["nope": true])),
            for: .session,
            nowMs: nowMs
        )
        XCTAssertEqual(effects, [.sessionFailed("http_201")])
        XCTAssertEqual(core.nextStep(nowMs: nowMs), .wait(untilMs: nowMs + 10_000))
    }

    func testSessionRateLimitHonorsRetryAfter() {
        var core = makeCore()
        core.track(name: "boot", data: nil, nowMs: nowMs)
        boot(&core)
        guard case .send(_, .session) = core.nextStep(nowMs: nowMs) else {
            return XCTFail("expected session request")
        }
        let effects = core.handle(
            response: RavensightResponse(status: 429, body: jsonBody(["error": "slow_down"]), retryAfter: "42"),
            for: .session,
            nowMs: nowMs
        )
        XCTAssertEqual(effects, [.sessionFailed("slow_down")])
        XCTAssertEqual(core.nextStep(nowMs: nowMs), .wait(untilMs: nowMs + 42_000))
    }

    // MARK: Batching

    func testEventsFlushInBatchesOfFifty() {
        var core = makeCore()
        boot(&core)
        for index in 0..<120 {
            core.track(name: "event_\(index)", data: nil, nowMs: nowMs)
        }
        openSession(&core)

        var flushed = 0
        for expected in [50, 50, 20] {
            let (request, effects) = expectBatch(&core, count: expected, respond: 202)
            XCTAssertEqual(request.headers["X-Session-Token"], "sess_token")
            XCTAssertEqual(effects, [.eventsFlushed(expected)])
            let events = decode(request.body)["events"] as? [[String: Any]]
            XCTAssertEqual(events?.count, expected)
            flushed += expected
        }
        XCTAssertEqual(flushed, 120)
        XCTAssertEqual(core.nextStep(nowMs: nowMs), .idle)
        XCTAssertTrue(core.pendingEvents.isEmpty)
    }

    func testEventPayloadShape() {
        var core = makeCore()
        boot(&core)
        core.track(name: "level_completed", data: ["level": 3, "hard": true], nowMs: nowMs)
        openSession(&core)

        let (request, _) = expectBatch(&core, count: 1, respond: 202)
        let events = decode(request.body)["events"] as? [[String: Any]]
        let event = events?.first
        XCTAssertEqual(event?["event"] as? String, "level_completed")
        XCTAssertEqual(event?["timestamp"] as? Int64, nowMs / 1000)
        let data = event?["data"] as? [String: Any]
        XCTAssertEqual(data?["level"] as? Int, 3)
        XCTAssertEqual(data?["hard"] as? Bool, true)
    }

    func testEventsSurviveUntilAccepted() {
        var core = makeCore()
        boot(&core)
        core.track(name: "keep_me", data: nil, nowMs: nowMs)
        openSession(&core)

        let (_, effects) = expectBatch(&core, count: 1, respond: 500)
        XCTAssertEqual(effects, [.flushFailed("http_500")])
        XCTAssertEqual(core.pendingEvents.count, 1, "failed events stay queued")

        nowMs += 10_000
        let (_, retryEffects) = expectBatch(&core, count: 1, respond: 202)
        XCTAssertEqual(retryEffects, [.eventsFlushed(1)])
        XCTAssertTrue(core.pendingEvents.isEmpty)
    }

    // MARK: 401 requeue

    func testUnauthorizedRequeuesBatchAndReopensSession() {
        var core = makeCore()
        boot(&core)
        for index in 0..<3 {
            core.track(name: "event_\(index)", data: nil, nowMs: nowMs)
        }
        openSession(&core, token: "sess_old")

        let (_, effects) = expectBatch(&core, count: 3, respond: 401)
        XCTAssertEqual(effects, [])
        XCTAssertEqual(core.pendingEvents.count, 3, "the batch stays queued")
        XCTAssertFalse(core.isSessionValid(nowMs: nowMs))

        openSession(&core, token: "sess_new")
        let (request, retryEffects) = expectBatch(&core, count: 3, respond: 202)
        XCTAssertEqual(request.headers["X-Session-Token"], "sess_new")
        XCTAssertEqual(retryEffects, [.eventsFlushed(3)])
    }

    func testRepeatedUnauthorizedBacksOffInsteadOfSpinning() {
        var core = makeCore()
        boot(&core)
        core.track(name: "event", data: nil, nowMs: nowMs)
        openSession(&core, token: "sess_1")
        expectBatch(&core, count: 1, respond: 401)
        openSession(&core, token: "sess_2")
        expectBatch(&core, count: 1, respond: 401)
        // Two re opens in a row are allowed; the third 401 backs off.
        openSession(&core, token: "sess_3")
        expectBatch(&core, count: 1, respond: 401)

        guard case .wait = core.nextStep(nowMs: nowMs) else {
            return XCTFail("expected a backoff wait after repeated 401s")
        }
        XCTAssertEqual(core.pendingEvents.count, 1, "nothing was lost")
    }

    // MARK: Backoff

    func testRetryAfterHeaderHonoredOnBatch() {
        var core = makeCore()
        boot(&core)
        core.track(name: "event", data: nil, nowMs: nowMs)
        openSession(&core)

        let (_, effects) = expectBatch(&core, count: 1, respond: 429, retryAfter: "7")
        XCTAssertEqual(effects, [.flushFailed("rate_limited")])
        XCTAssertEqual(core.nextStep(nowMs: nowMs), .wait(untilMs: nowMs + 7_000))
        XCTAssertEqual(core.nextStep(nowMs: nowMs + 6_999), .wait(untilMs: nowMs + 7_000))
        guard case .send(_, .batch) = core.nextStep(nowMs: nowMs + 7_000) else {
            return XCTFail("expected a batch once the Retry-After window closed")
        }
    }

    func testExponentialBackoffDoublesToFiveMinuteCeiling() {
        var core = makeCore()
        boot(&core)
        core.track(name: "event", data: nil, nowMs: nowMs)
        openSession(&core)

        let expectedWaits: [Int64] = [10_000, 20_000, 40_000, 80_000, 160_000, 300_000, 300_000]
        for expected in expectedWaits {
            expectBatch(&core, count: 1, respond: 503)
            guard case .wait(let untilMs) = core.nextStep(nowMs: nowMs) else {
                return XCTFail("expected backoff wait")
            }
            XCTAssertEqual(untilMs - nowMs, expected)
            nowMs = untilMs
        }
    }

    func testBackoffResetsAfterSuccess() {
        var core = makeCore()
        boot(&core)
        core.track(name: "one", data: nil, nowMs: nowMs)
        openSession(&core)

        expectBatch(&core, count: 1, respond: 500)
        nowMs += 10_000
        expectBatch(&core, count: 1, respond: 500)
        nowMs += 20_000
        expectBatch(&core, count: 1, respond: 202)

        core.track(name: "two", data: nil, nowMs: nowMs)
        expectBatch(&core, count: 1, respond: 500)
        guard case .wait(let untilMs) = core.nextStep(nowMs: nowMs) else {
            return XCTFail("expected backoff wait")
        }
        XCTAssertEqual(untilMs - nowMs, 10_000, "backoff restarted at 10s after a success")
    }

    func testNetworkFailureBacksOff() {
        var core = makeCore()
        boot(&core)
        core.track(name: "event", data: nil, nowMs: nowMs)
        openSession(&core)

        let (_, effects) = expectBatch(&core, count: 1, respond: 0)
        XCTAssertEqual(effects, [.flushFailed("network_error")])
        XCTAssertEqual(core.nextStep(nowMs: nowMs), .wait(untilMs: nowMs + 10_000))
    }

    func testExplicitFlushIgnoresBackoffOnce() {
        var core = makeCore()
        boot(&core)
        core.track(name: "event", data: nil, nowMs: nowMs)
        openSession(&core)
        expectBatch(&core, count: 1, respond: 500)

        XCTAssertEqual(core.nextStep(nowMs: nowMs), .wait(untilMs: nowMs + 10_000))
        guard case .send(_, .batch) = core.nextStep(nowMs: nowMs, ignoringBackoff: true) else {
            return XCTFail("an explicit flush should bypass the backoff window")
        }
    }

    // MARK: Queue cap

    func testQueueCapDropsOldestFirst() {
        var core = makeCore(maxQueueSize: 5)
        boot(&core)
        for index in 0..<8 {
            core.track(name: "event_\(index)", data: nil, nowMs: nowMs)
        }
        XCTAssertEqual(core.pendingEvents.count, 5)
        XCTAssertEqual(core.pendingEvents.first?.name, "event_3", "oldest were dropped")
        XCTAssertEqual(core.pendingEvents.last?.name, "event_7", "newest survive")
        XCTAssertEqual(core.stats.dropped, 3)
    }

    func testDefaultQueueCapIsFiveHundred() {
        var core = makeCore()
        boot(&core)
        for index in 0..<600 {
            core.track(name: "event_\(index)", data: nil, nowMs: nowMs)
        }
        XCTAssertEqual(core.pendingEvents.count, 500)
        XCTAssertEqual(core.pendingEvents.first?.name, "event_100")
    }

    // MARK: Oversize batch splitting on 400

    func testOversizeBatchHalvesDownToOneAndDropsThePoisonEvent() {
        var core = makeCore()
        boot(&core)
        for index in 0..<50 {
            core.track(name: "event_\(index)", data: nil, nowMs: nowMs)
        }
        openSession(&core)

        for expected in [50, 25, 12, 6, 3, 1] {
            let (_, effects) = expectBatch(&core, count: expected, respond: 400)
            if expected > 1 {
                XCTAssertEqual(effects, [])
            } else {
                XCTAssertEqual(effects, [.eventDropped("http_400")])
            }
        }

        XCTAssertEqual(core.pendingEvents.count, 49, "only the rejected event was dropped")
        XCTAssertEqual(core.pendingEvents.first?.name, "event_1")
        // The limit is restored, so the rest go out as one full batch again.
        let (_, effects) = expectBatch(&core, count: 49, respond: 202)
        XCTAssertEqual(effects, [.eventsFlushed(49)])
    }

    func testBatchLimitRestoredAfterSuccessfulSplit() {
        var core = makeCore()
        boot(&core)
        for index in 0..<60 {
            core.track(name: "event_\(index)", data: nil, nowMs: nowMs)
        }
        openSession(&core)

        expectBatch(&core, count: 50, respond: 400)
        expectBatch(&core, count: 25, respond: 202)
        // A successful send restores the full 50 event limit.
        expectBatch(&core, count: 35, respond: 202)
        XCTAssertTrue(core.pendingEvents.isEmpty)
    }

    // MARK: Local opt out

    func testDisablingLocallyClearsQueueAndStopsTracking() {
        var core = makeCore()
        boot(&core)
        core.track(name: "queued", data: nil, nowMs: nowMs)
        core.setEnabled(false)

        XCTAssertTrue(core.pendingEvents.isEmpty)
        XCTAssertFalse(core.track(name: "ignored", data: nil, nowMs: nowMs))
        XCTAssertEqual(core.nextStep(nowMs: nowMs), .idle)

        core.setEnabled(true)
        XCTAssertTrue(core.track(name: "welcome_back", data: nil, nowMs: nowMs))
    }

    // MARK: Session wanted (feedback path)

    func testMarkSessionWantedOpensSessionWithEmptyQueue() {
        var core = makeCore()
        boot(&core)
        XCTAssertEqual(core.nextStep(nowMs: nowMs), .idle)

        core.markSessionWanted()
        openSession(&core)
        XCTAssertEqual(core.nextStep(nowMs: nowMs), .idle, "nothing else to do once the session exists")
    }

    // MARK: Helpers under test

    func testNormalizeApiUrl() {
        XCTAssertEqual(
            RavensightCore.normalizeApiUrl("https://api.ravensight.io"),
            "https://api.ravensight.io/api/v1"
        )
        XCTAssertEqual(
            RavensightCore.normalizeApiUrl("https://api.ravensight.io/"),
            "https://api.ravensight.io/api/v1"
        )
        XCTAssertEqual(
            RavensightCore.normalizeApiUrl("https://api.ravensight.io/api/v1"),
            "https://api.ravensight.io/api/v1"
        )
        XCTAssertEqual(
            RavensightCore.normalizeApiUrl("https://api.ravensight.io/api/v1/"),
            "https://api.ravensight.io/api/v1"
        )
        XCTAssertEqual(
            RavensightCore.normalizeApiUrl(""),
            "https://api.ravensight.io/api/v1"
        )
        XCTAssertEqual(
            RavensightCore.normalizeApiUrl("  https://self.example.com/api/v1//  "),
            "https://self.example.com/api/v1"
        )
        XCTAssertEqual(
            RavensightCore.normalizeApiUrl("https://self.example.com///"),
            "https://self.example.com/api/v1"
        )
        XCTAssertEqual(
            RavensightCore.normalizeApiUrl("   "),
            "https://api.ravensight.io/api/v1"
        )
        XCTAssertEqual(RavensightClient.defaultApiUrl, "https://api.ravensight.io", "the default is the bare host")
    }

    func testRetryAfterParsing() {
        XCTAssertEqual(RavensightResponse.parseRetryAfterMs("30"), 30_000)
        XCTAssertEqual(RavensightResponse.parseRetryAfterMs(" 2 "), 2_000)
        XCTAssertEqual(RavensightResponse.parseRetryAfterMs("1.5"), 1_500)
        XCTAssertEqual(RavensightResponse.parseRetryAfterMs(nil), 0)
        XCTAssertEqual(RavensightResponse.parseRetryAfterMs(""), 0)
        XCTAssertEqual(RavensightResponse.parseRetryAfterMs("-5"), 0)
        XCTAssertEqual(
            RavensightResponse.parseRetryAfterMs("Wed, 21 Oct 2026 07:28:00 GMT"), 0,
            "HTTP-date form falls back to exponential backoff"
        )
    }

    func testErrorCodeExtraction() {
        let response = RavensightResponse(status: 429, body: jsonBody(["error": "quota_exceeded"]))
        XCTAssertEqual(response.errorCode(fallback: "rate_limited"), "quota_exceeded")

        let empty = RavensightResponse(status: 500)
        XCTAssertEqual(empty.errorCode(fallback: "http_500"), "http_500")
    }

    func testSanitizeJSONStringifiesUnsupportedValues() {
        let sanitized = RavensightCore.sanitizeJSON([
            "text": "hello",
            "number": 42,
            "flag": true,
            "nested": ["list": [1, "two", false]],
            "when": Date(timeIntervalSince1970: 0),
        ]) as? [String: Any]

        XCTAssertEqual(sanitized?["text"] as? String, "hello")
        XCTAssertEqual(sanitized?["number"] as? Int, 42)
        XCTAssertEqual(sanitized?["flag"] as? Bool, true)
        XCTAssertNotNil(sanitized?["when"] as? String, "a Date is stringified, not dropped")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(sanitized ?? [:]))
    }

    func testFeedbackRequestShape() {
        let core = makeCore()
        let request = core.feedbackRequest(
            message: "The boss fight drags", category: "balance", rating: 3, token: "sess_token"
        )
        XCTAssertEqual(request.method, "POST")
        XCTAssertTrue(request.url.hasSuffix("/api/v1/feedback"))
        XCTAssertEqual(request.headers["X-Session-Token"], "sess_token")
        let body = decode(request.body)
        XCTAssertEqual(body["message"] as? String, "The boss fight drags")
        XCTAssertEqual(body["category"] as? String, "balance")
        XCTAssertEqual(body["rating"] as? Int, 3)
    }

    func testFeedbackRequestOmitsOptionalFields() {
        let core = makeCore()
        let request = core.feedbackRequest(message: "hi", category: nil, rating: 0, token: "t")
        let body = decode(request.body)
        XCTAssertNil(body["category"])
        XCTAssertNil(body["rating"])
    }

    func testSuggestionsRequestUsesIngestKey() {
        let core = makeCore()
        let request = core.suggestionsRequest()
        XCTAssertEqual(request.method, "GET")
        XCTAssertTrue(request.url.hasSuffix("/api/v1/agent/suggestions"))
        XCTAssertEqual(request.headers["X-API-Key"], "gt_live_test_key")
    }

    // MARK: 0.2.0 contract

    private func makePlaytestCore() -> RavensightCore {
        return RavensightCore(config: RavensightCoreConfig(
            ingestKey: "gt_live_test_key",
            apiUrl: "https://api.example.com",
            deviceId: "pt-run_1",
            playtestToken: "pt_token"
        ))
    }

    private func forbidden(_ code: String) -> RavensightResponse {
        return RavensightResponse(status: 403, body: jsonBody(["error": code]))
    }

    func testSettingsUnauthorizedRefusesKeyAndStopsAutomaticSending() {
        var core = makeCore()
        core.track(name: "queued", data: nil, nowMs: nowMs)
        guard case .send(_, .settings) = core.nextStep(nowMs: nowMs) else {
            return XCTFail("expected settings check")
        }
        let effects = core.handle(response: RavensightResponse(status: 401), for: .settings, nowMs: nowMs)
        XCTAssertEqual(effects, [.keyRefused])
        XCTAssertEqual(core.statusReason, "invalid_key")
        XCTAssertEqual(core.nextStep(nowMs: nowMs), .idle, "no automatic retry after a refused key")
        XCTAssertEqual(core.nextStep(nowMs: nowMs + 3_600_000), .idle)
        XCTAssertEqual(core.pendingEvents.count, 1, "the queue is kept")
        XCTAssertTrue(core.track(name: "still_queues", data: nil, nowMs: nowMs))

        // An explicit flush makes one more attempt.
        guard case .send(_, .session) = core.nextStep(nowMs: nowMs, ignoringBackoff: true) else {
            return XCTFail("expected one more attempt on an explicit flush")
        }
    }

    func testSessionUnauthorizedAndUnknownForbiddenAreInvalidKey() {
        for response in [RavensightResponse(status: 401), forbidden("forbidden"), RavensightResponse(status: 403)] {
            var core = makeCore()
            boot(&core)
            core.track(name: "e", data: nil, nowMs: nowMs)
            guard case .send(_, .session) = core.nextStep(nowMs: nowMs) else {
                return XCTFail("expected a session request")
            }
            XCTAssertEqual(core.handle(response: response, for: .session, nowMs: nowMs), [.keyRefused])
            XCTAssertEqual(core.statusReason, "invalid_key")
            XCTAssertEqual(core.nextStep(nowMs: nowMs + 600_000), .idle)
        }
    }

    func testSessionForbiddenTrackingDisabledIsTheKillSwitch() {
        var core = makeCore()
        boot(&core)
        core.track(name: "e", data: nil, nowMs: nowMs)
        guard case .send(_, .session) = core.nextStep(nowMs: nowMs) else {
            return XCTFail("expected a session request")
        }
        let effects = core.handle(response: forbidden("tracking_disabled"), for: .session, nowMs: nowMs)
        XCTAssertEqual(effects, [.trackingDisabled])
        XCTAssertFalse(core.trackingEnabled)
        XCTAssertTrue(core.pendingEvents.isEmpty)
        XCTAssertEqual(core.statusReason, "tracking_disabled")
        XCTAssertEqual(core.nextStep(nowMs: nowMs, ignoringBackoff: true), .idle)
        XCTAssertFalse(core.track(name: "ignored", data: nil, nowMs: nowMs))
    }

    func testBatchForbiddenTrackingDisabledIsTheKillSwitch() {
        var core = makeCore()
        boot(&core)
        core.track(name: "e", data: nil, nowMs: nowMs)
        openSession(&core)
        let (_, effects) = expectBatch(&core, count: 1, respond: 403, body: jsonBody(["error": "tracking_disabled"]))
        XCTAssertEqual(effects, [.trackingDisabled])
        XCTAssertTrue(core.pendingEvents.isEmpty)
    }

    func testServiceUnavailableHonoursRetryAfter() {
        var core = makeCore()
        boot(&core)
        core.track(name: "e", data: nil, nowMs: nowMs)
        guard case .send(_, .session) = core.nextStep(nowMs: nowMs) else {
            return XCTFail("expected a session request")
        }
        _ = core.handle(
            response: RavensightResponse(status: 503, body: jsonBody(["error": "storage_unavailable"]), retryAfter: "60"),
            for: .session, nowMs: nowMs
        )
        XCTAssertEqual(core.nextStep(nowMs: nowMs), .wait(untilMs: nowMs + 60_000))

        nowMs += 60_000
        openSession(&core)
        expectBatch(&core, count: 1, respond: 503, retryAfter: "60")
        XCTAssertEqual(core.nextStep(nowMs: nowMs), .wait(untilMs: nowMs + 60_000))
        XCTAssertEqual(core.pendingEvents.count, 1)
    }

    func testRateLimitReasonAndOfflineReason() {
        var core = makeCore()
        boot(&core)
        core.track(name: "e", data: nil, nowMs: nowMs)
        guard case .send(_, .session) = core.nextStep(nowMs: nowMs) else {
            return XCTFail("expected a session request")
        }
        _ = core.handle(response: RavensightResponse(status: 429, retryAfter: "7"), for: .session, nowMs: nowMs)
        XCTAssertEqual(core.statusReason, "rate_limited")
        XCTAssertEqual(core.nextStep(nowMs: nowMs), .wait(untilMs: nowMs + 7_000))

        nowMs += 7_000
        guard case .send(_, .session) = core.nextStep(nowMs: nowMs) else {
            return XCTFail("expected a session request")
        }
        _ = core.handle(response: .networkFailure("down"), for: .session, nowMs: nowMs)
        XCTAssertEqual(core.statusReason, "offline")

        nowMs += 10_000
        openSession(&core)
        XCTAssertNil(core.statusReason, "a session clears the reason")
    }

    func testOptedOutOrDisabledCoreRequestsNothing() {
        var core = makeCore()
        core.setOptedOut(true)
        XCTAssertEqual(core.nextStep(nowMs: nowMs), .idle, "not even the settings check")
        XCTAssertEqual(core.nextStep(nowMs: nowMs, ignoringBackoff: true), .idle)
        XCTAssertFalse(core.track(name: "e", data: nil, nowMs: nowMs))
        XCTAssertEqual(core.statusReason, "disabled")

        var disabled = makeCore()
        disabled.setEnabled(false)
        XCTAssertEqual(disabled.nextStep(nowMs: nowMs, ignoringBackoff: true), .idle)
        XCTAssertEqual(disabled.statusReason, "disabled")
    }

    func testTrackTakesAnExplicitTimestamp() {
        var core = makeCore()
        core.track(name: "late", data: nil, nowMs: nowMs, atSec: 123)
        XCTAssertEqual(core.pendingEvents.first?.timestamp, 123)
    }

    func testReplaceDeviceIdClearsQueueAndSession() {
        var core = makeCore()
        boot(&core)
        core.track(name: "e", data: nil, nowMs: nowMs)
        openSession(&core)
        core.replaceDeviceId("dev_new")
        XCTAssertTrue(core.pendingEvents.isEmpty)
        XCTAssertNil(core.sessionToken)
        core.track(name: "f", data: nil, nowMs: nowMs)
        guard case .send(let request, .session) = core.nextStep(nowMs: nowMs) else {
            return XCTFail("expected a fresh session")
        }
        XCTAssertEqual(decode(request.body)["deviceId"] as? String, "dev_new")
    }

    // MARK: Background exit

    func testPendingExitGoesFirstUnderTheOldTokenWithItsOwnTimestamp() {
        var core = makeCore()
        core.track(name: "game_started", data: nil, nowMs: nowMs)
        core.setPendingExit(.init(sessionToken: "sess_old", timestamp: 4_242, retry: false))

        guard case .send(let request, .exit(retry: false)) = core.nextStep(nowMs: nowMs) else {
            return XCTFail("the exit goes before anything else, even the settings check")
        }
        XCTAssertTrue(request.url.hasSuffix("/api/v1/track/batch"))
        XCTAssertEqual(request.headers["X-Session-Token"], "sess_old")
        let events = decode(request.body)["events"] as? [[String: Any]]
        XCTAssertEqual(events?.count, 1)
        XCTAssertEqual(events?.first?["event"] as? String, "game_exited")
        XCTAssertEqual((events?.first?["timestamp"] as? NSNumber)?.int64Value, 4_242)

        // One attempt, whatever the answer.
        _ = core.handle(response: .networkFailure("down"), for: .exit(retry: false), nowMs: nowMs)
        XCTAssertNil(core.pendingExit)
        guard case .send(_, .settings) = core.nextStep(nowMs: nowMs) else {
            return XCTFail("then the ordinary boot")
        }
    }

    func testRetryingExitSurvivesAnOutage() {
        var core = makeCore()
        boot(&core)
        core.setPendingExit(.init(sessionToken: "sess_old", timestamp: 1, retry: true))
        _ = core.handle(response: .networkFailure("down"), for: .exit(retry: true), nowMs: nowMs)
        XCTAssertNotNil(core.pendingExit)
        guard case .wait = core.nextStep(nowMs: nowMs) else { return XCTFail("expected backoff") }
        nowMs += 10_000
        guard case .send(_, .exit(retry: true)) = core.nextStep(nowMs: nowMs) else {
            return XCTFail("expected the exit again")
        }
        _ = core.handle(response: RavensightResponse(status: 202), for: .exit(retry: true), nowMs: nowMs)
        XCTAssertNil(core.pendingExit)
    }

    func testOptedOutCoreDropsPendingExit() {
        var core = makeCore()
        core.setOptedOut(true)
        core.setPendingExit(.init(sessionToken: "sess_old", timestamp: 1, retry: false))
        XCTAssertNil(core.pendingExit)
    }

    // MARK: Playtest

    func testPlaytestHeaderOnEveryRequest() {
        var core = makePlaytestCore()
        core.track(name: "e", data: nil, nowMs: nowMs)
        var seen: [RavensightRequest] = []
        guard case .send(let settings, .settings) = core.nextStep(nowMs: nowMs) else { return XCTFail("settings") }
        seen.append(settings)
        _ = core.handle(response: RavensightResponse(status: 200, body: jsonBody(["trackingEnabled": true])), for: .settings, nowMs: nowMs)
        guard case .send(let session, .session) = core.nextStep(nowMs: nowMs) else { return XCTFail("session") }
        seen.append(session)
        XCTAssertEqual(decode(session.body)["deviceId"] as? String, "pt-run_1")
        _ = core.handle(response: RavensightResponse(status: 201, body: jsonBody(["token": "s", "expiresIn": 3600])), for: .session, nowMs: nowMs)
        guard case .send(let batch, .batch) = core.nextStep(nowMs: nowMs) else { return XCTFail("batch") }
        seen.append(batch)
        seen.append(core.feedbackRequest(message: "m", category: nil, rating: 0, token: "s"))
        seen.append(core.suggestionsRequest())
        for request in seen {
            XCTAssertEqual(request.headers["X-Ravensight-Playtest"], "pt_token", request.url)
        }
        XCTAssertNil(makeCore().suggestionsRequest().headers["X-Ravensight-Playtest"])
    }

    func testPlaytestJobClosedStopsTheRun() {
        var core = makePlaytestCore()
        boot(&core)
        core.track(name: "e", data: nil, nowMs: nowMs)
        guard case .send(_, .session) = core.nextStep(nowMs: nowMs) else { return XCTFail("session") }
        let effects = core.handle(response: forbidden("playtest_job_closed"), for: .session, nowMs: nowMs)
        XCTAssertEqual(effects, [.stopped("playtest_job_closed")])
        XCTAssertEqual(core.statusReason, "playtest_job_closed")
        XCTAssertTrue(core.pendingEvents.isEmpty)
        XCTAssertEqual(core.nextStep(nowMs: nowMs, ignoringBackoff: true), .idle)
        XCTAssertFalse(core.track(name: "f", data: nil, nowMs: nowMs))
    }

    func testInvalidPlaytestTokenStopsWithSessionFailed() {
        var core = makePlaytestCore()
        guard case .send(_, .settings) = core.nextStep(nowMs: nowMs) else { return XCTFail("settings") }
        let effects = core.handle(response: forbidden("invalid_playtest_token"), for: .settings, nowMs: nowMs)
        XCTAssertEqual(effects, [.stopped("session_failed")])
        XCTAssertEqual(core.statusReason, "session_failed")
        XCTAssertEqual(core.nextStep(nowMs: nowMs, ignoringBackoff: true), .idle)
    }

    // MARK: Feedback validation

    func testFeedbackRefusals() {
        XCTAssertEqual(RavensightCore.feedbackCategories, ["bug", "suggestion", "complaint", "praise", "playtest", "other"])
        XCTAssertNil(RavensightCore.feedbackRefusal(message: "ok", category: nil, rating: 0))
        XCTAssertNil(RavensightCore.feedbackRefusal(message: "ok", category: "", rating: 5))
        XCTAssertNil(RavensightCore.feedbackRefusal(message: "ok", category: "suggestion", rating: 1))
        XCTAssertEqual(RavensightCore.feedbackRefusal(message: "  ", category: nil, rating: 0), "empty_message")
        XCTAssertEqual(RavensightCore.feedbackRefusal(message: "ok", category: "balance", rating: 0), "invalid_category")
        XCTAssertEqual(RavensightCore.feedbackRefusal(message: "ok", category: "Bug", rating: 0), "invalid_category")
        XCTAssertEqual(RavensightCore.feedbackRefusal(message: "ok", category: nil, rating: 6), "invalid_rating")
        XCTAssertEqual(RavensightCore.feedbackRefusal(message: "ok", category: nil, rating: -1), "invalid_rating")
    }

    // MARK: Fix round 1

    func testSettingsRateLimitHonoursRetryAfter() {
        var core = makeCore()
        guard case .send(_, .settings) = core.nextStep(nowMs: nowMs) else { return XCTFail("settings") }
        _ = core.handle(response: RavensightResponse(status: 429, retryAfter: "30"), for: .settings, nowMs: nowMs)
        XCTAssertEqual(core.statusReason, "rate_limited")
        XCTAssertEqual(core.nextStep(nowMs: nowMs), .wait(untilMs: nowMs + 30_000))
        nowMs += 30_000
        guard case .send(_, .settings) = core.nextStep(nowMs: nowMs) else { return XCTFail("asked again") }
    }

    func testStaleAnswersAreRecognised() {
        var core = makeCore()
        boot(&core)
        core.track(name: "e", data: nil, nowMs: nowMs)
        let beforeReset = core.stamp
        XCTAssertFalse(core.isStale(.session, since: beforeReset))
        XCTAssertFalse(core.isStale(.batch(count: 1), since: beforeReset))

        core.replaceDeviceId("dev_new")
        XCTAssertTrue(core.isStale(.session, since: beforeReset))
        XCTAssertTrue(core.isStale(.batch(count: 1), since: beforeReset))
        XCTAssertFalse(core.isStale(.settings, since: beforeReset))

        let beforeOptOut = core.stamp
        core.setOptedOut(true)
        core.setOptedOut(false)
        XCTAssertTrue(core.isStale(.batch(count: 1), since: beforeOptOut))
        XCTAssertFalse(core.isStale(.session, since: beforeOptOut), "same identity, same session")

        core.setPendingExit(.init(sessionToken: "s", timestamp: 1, retry: true))
        let withExit = core.stamp
        XCTAssertFalse(core.isStale(.exit(retry: true), since: withExit))
        core.setOptedOut(true)
        XCTAssertTrue(core.isStale(.exit(retry: true), since: withExit))
    }

    // MARK: Restored queue (0.3.0)

    func testRestoredEventsGoUnderTheirOwnSessionThenDemoteOn401() {
        var core = makeCore()
        let old = (1...3).map { RavensightEvent(name: "old_\($0)", data: [:], timestamp: 1) }
        core.restore(events: old, sessionToken: "sess_old", expiresAtMs: nowMs + 3_600_000, nowMs: nowMs)
        XCTAssertEqual(core.pendingCount, 3)
        XCTAssertEqual(core.stats.restored, 3)
        boot(&core)

        guard case .send(let request, .restored(let count)) = core.nextStep(nowMs: nowMs) else {
            return XCTFail("restored events go first")
        }
        XCTAssertEqual(count, 3)
        XCTAssertEqual(request.headers["X-Session-Token"], "sess_old")

        _ = core.handle(response: RavensightResponse(status: 401), for: .restored(count: 3), nowMs: nowMs)
        XCTAssertNil(core.restoredBatch)
        XCTAssertEqual(core.pendingEvents.map { $0.name }, ["old_1", "old_2", "old_3"], "moved to the live queue")
        openSession(&core)
    }

    func testRestoredEventsWithAnExpiredSessionJoinTheLiveQueue() {
        var core = makeCore(maxQueueSize: 2)
        core.track(name: "live", data: nil, nowMs: nowMs)
        let old = (1...3).map { RavensightEvent(name: "old_\($0)", data: [:], timestamp: 1) }
        core.restore(events: old, sessionToken: "sess_old", expiresAtMs: nowMs - 1, nowMs: nowMs)
        XCTAssertNil(core.restoredBatch)
        XCTAssertEqual(core.pendingEvents.map { $0.name }, ["old_3", "live"], "the cap keeps the newest")
        XCTAssertEqual(core.stats.dropped, 2)
    }

    func testAcceptedCountsQueueAcceptanceOnly() {
        var core = makeCore()
        core.track(name: "a", data: nil, nowMs: nowMs)
        core.setOptedOut(true)
        core.track(name: "b", data: nil, nowMs: nowMs)
        XCTAssertEqual(core.stats.accepted, 1)
        XCTAssertEqual(core.stats.dropped, 1)
        XCTAssertEqual(core.stats.sent, 0)
    }
}
