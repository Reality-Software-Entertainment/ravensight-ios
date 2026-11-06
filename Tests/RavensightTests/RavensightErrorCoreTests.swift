import XCTest
@testable import Ravensight

/// The protocol core's part of error capture: the errorCapture switches on
/// the settings and session answers, gameplay events ahead of automatic
/// errors at the queue cap, and 413 handled like 400.
final class RavensightErrorCoreTests: XCTestCase {
    private let nowMs: Int64 = 1_000_000_000

    private func makeCore(maxQueueSize: Int = 500) -> RavensightCore {
        var core = RavensightCore(config: RavensightCoreConfig(
            ingestKey: "gt_live_test_key",
            apiUrl: "https://api.example.com",
            deviceId: "dev_test",
            maxQueueSize: maxQueueSize
        ))
        core.random = { 0.5 }
        return core
    }

    private func json(_ object: [String: Any]) -> Data {
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func autoError(_ message: String) -> [String: Any] {
        return ["rs_kind": "error", "rs_severity": "error", "rs_source": "crash", "rs_message": message]
    }

    private func boot(_ core: inout RavensightCore, settings: [String: Any] = ["trackingEnabled": true]) {
        _ = core.handle(response: RavensightResponse(status: 200, body: json(settings)), for: .settings, nowMs: nowMs)
    }

    private func openSession(_ core: inout RavensightCore, extra: [String: Any] = [:]) {
        var body: [String: Any] = ["token": "sess", "expiresIn": 86_400]
        for (key, value) in extra { body[key] = value }
        _ = core.handle(response: RavensightResponse(status: 201, body: json(body)), for: .session, nowMs: nowMs)
    }

    func testErrorCaptureIsOnWithNoTrailUntilAnAnswerSaysOtherwise() {
        var core = makeCore()
        XCTAssertTrue(core.errorCaptureEnabled)
        XCTAssertFalse(core.errorTrailEnabled)
        XCTAssertFalse(core.errorCaptureAnswered)
        boot(&core)
        XCTAssertTrue(core.errorCaptureAnswered, "an answer without the key still counts as an answer")
        XCTAssertTrue(core.errorCaptureEnabled)
        XCTAssertFalse(core.errorTrailEnabled)
    }

    func testSettingsAnswerSwitchesCaptureOffAndTrailOn() {
        var core = makeCore()
        boot(&core, settings: ["trackingEnabled": true, "errorCapture": ["enabled": false, "trail": true]])
        XCTAssertFalse(core.errorCaptureEnabled)
        XCTAssertTrue(core.errorTrailEnabled)
    }

    func testSessionAnswerUpdatesTheSwitches() {
        var core = makeCore()
        boot(&core)
        openSession(&core, extra: ["errorCapture": ["enabled": true, "trail": true]])
        XCTAssertTrue(core.errorTrailEnabled)
        openSession(&core, extra: ["errorCapture": ["enabled": false]])
        XCTAssertFalse(core.errorCaptureEnabled)
        XCTAssertFalse(core.errorTrailEnabled, "a missing trail flag is off")
    }

    func testAFailedSettingsCheckIsNotAnAnswer() {
        var core = makeCore()
        _ = core.handle(response: .networkFailure("offline"), for: .settings, nowMs: nowMs)
        XCTAssertFalse(core.errorCaptureAnswered)
    }

    func testAutomaticErrorRecognition() {
        XCTAssertTrue(RavensightCore.isAutomaticError(autoError("x")))
        XCTAssertFalse(RavensightCore.isAutomaticError(["rs_kind": "error", "rs_source": "manual"]))
        XCTAssertFalse(RavensightCore.isAutomaticError(["rs_kind": "error"]), "trackError sends no source")
        XCTAssertFalse(RavensightCore.isAutomaticError(["rs_source": "crash"]))
    }

    func testAFullQueueDropsTheIncomingAutomaticError() {
        var core = makeCore(maxQueueSize: 3)
        for index in 0..<3 { core.track(name: "play_\(index)", data: nil, nowMs: nowMs) }
        XCTAssertFalse(core.track(name: "error", data: autoError("boom"), nowMs: nowMs))
        XCTAssertEqual(core.pendingEvents.map { $0.name }, ["play_0", "play_1", "play_2"])
        XCTAssertEqual(core.stats.dropped, 1)
    }

    func testAFullQueueDropsTheOldestAutomaticErrorBeforeAnyGameplayEvent() {
        var core = makeCore(maxQueueSize: 3)
        core.track(name: "play_0", data: nil, nowMs: nowMs)
        core.track(name: "error", data: autoError("one"), nowMs: nowMs)
        core.track(name: "play_1", data: nil, nowMs: nowMs)
        XCTAssertTrue(core.track(name: "play_2", data: nil, nowMs: nowMs))
        XCTAssertEqual(core.pendingEvents.map { $0.name }, ["play_0", "play_1", "play_2"])
    }

    func testAManualErrorIsGameplayAtTheCap() {
        var core = makeCore(maxQueueSize: 2)
        core.track(name: "error", data: ["rs_kind": "error", "rs_message": "manual"], nowMs: nowMs)
        core.track(name: "play_0", data: nil, nowMs: nowMs)
        core.track(name: "play_1", data: nil, nowMs: nowMs)
        XCTAssertEqual(core.pendingEvents.map { $0.name }, ["play_0", "play_1"], "oldest first, as before")
    }

    func test413SplitsTheBatchThenDropsTheOneBadEvent() {
        var core = makeCore()
        boot(&core)
        openSession(&core)
        core.track(name: "a", data: nil, nowMs: nowMs)
        core.track(name: "b", data: nil, nowMs: nowMs)
        guard case .send(_, .batch(let first)) = core.nextStep(nowMs: nowMs) else { return XCTFail("batch") }
        XCTAssertEqual(first, 2)
        XCTAssertEqual(core.handle(response: RavensightResponse(status: 413), for: .batch(count: 2), nowMs: nowMs), [])
        guard case .send(_, .batch(let second)) = core.nextStep(nowMs: nowMs) else {
            return XCTFail("a 413 is split at once, not backed off")
        }
        XCTAssertEqual(second, 1)
        let effects = core.handle(response: RavensightResponse(status: 413), for: .batch(count: 1), nowMs: nowMs)
        XCTAssertEqual(effects, [.eventDropped("http_413")])
        XCTAssertEqual(core.pendingEvents.map { $0.name }, ["b"])
        guard case .send = core.nextStep(nowMs: nowMs) else { return XCTFail("the rest is sent, not held back") }
    }

    func testRestored413IsHandedToTheLiveQueue() {
        var core = makeCore()
        boot(&core)
        core.restore(
            events: [RavensightEvent(name: "old", data: ["rs_event_id": "e1"], timestamp: 1)],
            sessionToken: "old_sess", expiresAtMs: nowMs + 3_600_000, nowMs: nowMs)
        XCTAssertNotNil(core.restoredBatch)
        _ = core.handle(response: RavensightResponse(status: 413), for: .restored(count: 1), nowMs: nowMs)
        XCTAssertNil(core.restoredBatch)
        XCTAssertEqual(core.pendingEvents.map { $0.name }, ["old"])
    }
}
