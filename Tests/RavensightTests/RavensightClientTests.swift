import XCTest
@testable import Ravensight

/// A scripted transport: answers requests by URL suffix, records everything.
private final class FakeTransport: RavensightTransport {
    private let lock = NSLock()
    private var recorded: [RavensightRequest] = []

    var trackingEnabled = true
    var batchStatus = 202
    var sessionToken = "sess_fake"

    var requests: [RavensightRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func requests(suffix: String) -> [RavensightRequest] {
        return requests.filter { $0.url.hasSuffix(suffix) }
    }

    func send(_ request: RavensightRequest, completion: @escaping (RavensightResponse) -> Void) {
        lock.lock()
        recorded.append(request)
        lock.unlock()

        let body: Data?
        let status: Int
        if request.url.hasSuffix("/settings") {
            status = 200
            body = try? JSONSerialization.data(withJSONObject: ["trackingEnabled": trackingEnabled])
        } else if request.url.hasSuffix("/session") {
            status = 201
            body = try? JSONSerialization.data(withJSONObject: ["token": sessionToken, "expiresIn": 86_400])
        } else if request.url.hasSuffix("/track/batch") {
            status = batchStatus
            body = nil
        } else if request.url.hasSuffix("/feedback") {
            status = 201
            body = nil
        } else if request.url.hasSuffix("/agent/suggestions") {
            status = 200
            body = try? JSONSerialization.data(withJSONObject: [
                "suggestions": [["title": "Shorten level 3"]],
            ])
        } else {
            status = 404
            body = nil
        }
        completion(RavensightResponse(status: status, body: body))
    }
}

/// End to end tests of the client driver (serial queue, pump, timers) over a
/// fake transport. The protocol details themselves are covered by the core
/// tests.
final class RavensightClientTests: XCTestCase {
    private func makeClient(
        transport: FakeTransport,
        lifecycleEvents: Bool = false
    ) -> RavensightClient {
        var configuration = RavensightConfiguration(ingestKey: "gt_live_test")
        configuration.apiUrl = "https://fake.test"
        configuration.gameVersion = "9.9.9"
        configuration.trackLifecycleEvents = lifecycleEvents
        configuration.flushInterval = 0 // tests flush explicitly
        return RavensightClient(configuration: configuration, transport: transport, now: nil)
    }

    private func waitUntil(
        _ timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("condition not met within \(timeout)s", file: file, line: line)
    }

    func testBootChecksSettingsThenOpensSessionAndDelivers() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)
        client.start()

        client.track("level_completed", data: ["level": 1])
        client.track("player_died")

        waitUntil { client.queuedEventCount == 0 && client.isReady }

        XCTAssertEqual(transport.requests(suffix: "/settings").count, 1)
        XCTAssertEqual(transport.requests(suffix: "/session").count, 1)
        let batches = transport.requests(suffix: "/track/batch")
        XCTAssertFalse(batches.isEmpty)
        XCTAssertEqual(batches.first?.headers["X-Session-Token"], "sess_fake")

        let sent = batches.flatMap { request -> [[String: Any]] in
            guard let body = request.body,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                return []
            }
            return object["events"] as? [[String: Any]] ?? []
        }
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.first?["event"] as? String, "level_completed")
    }

    func testKillSwitchStopsEverything() {
        let transport = FakeTransport()
        transport.trackingEnabled = false
        let client = makeClient(transport: transport)
        client.start()

        waitUntil { !client.isTrackingEnabled }

        client.track("ignored")
        let done = expectation(description: "flush settles")
        client.flush { done.fulfill() }
        wait(for: [done], timeout: 2)

        XCTAssertTrue(transport.requests(suffix: "/session").isEmpty)
        XCTAssertTrue(transport.requests(suffix: "/track/batch").isEmpty)
        XCTAssertFalse(client.track("still_ignored"))
    }

    func testFlushCompletionFiresEvenWhenIdle() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)
        client.start()

        let done = expectation(description: "flush completion")
        client.flush { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testSubmitFeedbackWithoutSessionFailsFast() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)
        // Deliberately not started: no session can exist yet.

        let done = expectation(description: "feedback completion")
        client.submitFeedback("hello") { result in
            if case .failure(let error) = result {
                XCTAssertEqual(error.code, "no_session")
            } else {
                XCTFail("expected no_session failure")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testSubmitFeedbackDeliversWithSession() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)
        client.start()
        client.track("warmup")
        waitUntil { client.isReady }

        let done = expectation(description: "feedback completion")
        client.submitFeedback("The boss fight drags", category: "balance", rating: 3) { result in
            if case .failure(let error) = result {
                XCTFail("expected success, got \(error)")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 2)

        let feedback = transport.requests(suffix: "/feedback")
        XCTAssertEqual(feedback.count, 1)
        XCTAssertEqual(feedback.first?.headers["X-Session-Token"], "sess_fake")
    }

    func testEmptyFeedbackRejectedLocally() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)
        client.start()

        let done = expectation(description: "feedback completion")
        client.submitFeedback("   ") { result in
            if case .failure(let error) = result {
                XCTAssertEqual(error.code, "empty_message")
            } else {
                XCTFail("expected empty_message failure")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertTrue(transport.requests(suffix: "/feedback").isEmpty)
    }

    func testFetchSuggestions() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)

        let done = expectation(description: "suggestions completion")
        client.fetchSuggestions { result in
            switch result {
            case .success(let suggestions):
                XCTAssertEqual(suggestions.first?["title"] as? String, "Shorten level 3")
            case .failure(let error):
                XCTFail("expected suggestions, got \(error)")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 2)

        let calls = transport.requests(suffix: "/agent/suggestions")
        XCTAssertEqual(calls.first?.headers["X-API-Key"], "gt_live_test")
    }

    func testSetEnabledFalseDropsQueueAndBlocksTracking() {
        let transport = FakeTransport()
        transport.batchStatus = 500 // keep events stuck in the queue
        let client = makeClient(transport: transport)
        client.start()
        client.track("stuck")

        waitUntil { client.queuedEventCount == 1 }
        client.setEnabled(false)
        waitUntil { client.queuedEventCount == 0 }
        XCTAssertFalse(client.isEnabled)
        XCTAssertFalse(client.track("ignored"))
    }

    func testLifecycleStartEventTracked() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport, lifecycleEvents: true)
        client.start()

        waitUntil {
            transport.requests(suffix: "/track/batch").contains { request in
                guard let body = request.body,
                      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let events = object["events"] as? [[String: Any]] else { return false }
                return events.contains { $0["event"] as? String == "game_started" }
            }
        }
    }
}
