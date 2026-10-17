import XCTest
@testable import Ravensight

/// A scripted transport: answers requests by URL suffix, records everything.
/// Completions run synchronously, like an instant network.
final class FakeTransport: RavensightTransport {
    private let lock = NSLock()
    private var recorded: [RavensightRequest] = []
    private var sessionCount = 0

    var trackingEnabled = true
    /// Session tokens are "<prefix>_<n>".
    var sessionPrefix = "sess"
    var settingsStatus = 200
    var sessionStatus = 201
    var sessionError: String?
    var batchStatus = 202
    var batchError: String?
    /// Requests whose completion is never called (a hung network).
    var hang = false
    /// Answers a request before the scripted routes, when it returns one.
    var override: ((RavensightRequest) -> RavensightResponse?)?
    /// Requests to this suffix wait until release(_:) answers them.
    var holdSuffix: String?
    private var held: [(RavensightResponse) -> Void] = []

    var heldCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return held.count
    }

    /// Answers every held request with this response.
    func release(_ response: RavensightResponse) {
        lock.lock()
        let waiting = held
        held = []
        holdSuffix = nil
        lock.unlock()
        for completion in waiting { completion(response) }
    }

    var requests: [RavensightRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func requests(suffix: String) -> [RavensightRequest] {
        return requests.filter { $0.url.hasSuffix(suffix) }
    }

    /// Every event sent in a batch, with the session token it went under.
    func sentEvents() -> [(name: String, timestamp: Int64, token: String)] {
        return requests(suffix: "/track/batch").flatMap { request -> [(name: String, timestamp: Int64, token: String)] in
            guard let body = request.body,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let events = object["events"] as? [[String: Any]] else { return [] }
            return events.map {
                (
                    name: $0["event"] as? String ?? "",
                    timestamp: ($0["timestamp"] as? NSNumber)?.int64Value ?? 0,
                    token: request.headers["X-Session-Token"] ?? ""
                )
            }
        }
    }

    func send(_ request: RavensightRequest, completion: @escaping (RavensightResponse) -> Void) {
        lock.lock()
        recorded.append(request)
        let hung = hang
        if let suffix = holdSuffix, request.url.hasSuffix(suffix) {
            held.append(completion)
            lock.unlock()
            return
        }
        let custom = override
        lock.unlock()
        if hung { return }
        if let custom = custom, let response = custom(request) {
            completion(response)
            return
        }

        func json(_ object: [String: Any]) -> Data? {
            return try? JSONSerialization.data(withJSONObject: object)
        }

        if request.url.hasSuffix("/settings") {
            completion(RavensightResponse(
                status: settingsStatus,
                body: settingsStatus == 200 ? json(["trackingEnabled": trackingEnabled]) : json(["error": "invalid_api_key"])
            ))
        } else if request.url.hasSuffix("/session") {
            if sessionStatus == 201 {
                lock.lock()
                sessionCount += 1
                let token = "\(sessionPrefix)_\(sessionCount)"
                lock.unlock()
                completion(RavensightResponse(status: 201, body: json(["token": token, "expiresIn": 86_400])))
            } else {
                completion(RavensightResponse(status: sessionStatus, body: json(["error": sessionError ?? "refused"])))
            }
        } else if request.url.hasSuffix("/track/batch") {
            completion(RavensightResponse(
                status: batchStatus,
                body: batchError.flatMap { json(["error": $0]) }
            ))
        } else if request.url.hasSuffix("/feedback") {
            completion(RavensightResponse(status: 201))
        } else if request.url.hasSuffix("/agent/suggestions") {
            completion(RavensightResponse(status: 200, body: json([
                "suggestions": [["title": "Shorten level 3"]],
            ])))
        } else {
            completion(RavensightResponse(status: 404))
        }
    }
}

/// A clock the test moves by hand.
final class FakeClock {
    private let lock = NSLock()
    private var current: Int64 = 1_800_000_000_000

    var nowMs: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(seconds: Int64) {
        lock.lock()
        current += seconds * 1000
        lock.unlock()
    }
}

/// End to end tests of the client driver (serial queue, pump, lifecycle
/// handlers, storage) over a fake transport, a fake clock and an isolated
/// UserDefaults suite. The protocol details are covered by the core tests.
final class RavensightClientTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let clock = FakeClock()

    override func setUp() {
        super.setUp()
        suiteName = "io.ravensight.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeClient(
        transport: FakeTransport,
        lifecycleEvents: Bool = false,
        environment: [String: String] = [:],
        backgroundLaunch: Bool = false,
        configure: (inout RavensightConfiguration) -> Void = { _ in }
    ) -> RavensightClient {
        var configuration = RavensightConfiguration(ingestKey: "gt_live_test")
        configuration.apiUrl = "https://fake.test"
        configuration.gameVersion = "9.9.9"
        configuration.trackLifecycleEvents = lifecycleEvents
        configuration.flushInterval = 0 // tests flush explicitly
        configure(&configuration)
        let clock = self.clock
        return RavensightClient(
            configuration: configuration,
            transport: transport,
            now: { clock.nowMs },
            defaults: defaults,
            environment: environment,
            isBackgroundLaunch: { backgroundLaunch },
            installsLifecycleObservers: false,
            random: { 0.5 }
        )
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

    /// Lets every chained request and response on the work queue run out.
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

    private func feedbackResult(
        _ client: RavensightClient, _ message: String, category: String? = nil, rating: Int = 0
    ) -> Result<Void, RavensightError> {
        var outcome: Result<Void, RavensightError>?
        let done = expectation(description: "feedback completion")
        client.submitFeedback(message, category: category, rating: rating) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        return outcome ?? .failure(RavensightError(code: "none", status: 0, message: ""))
    }

    private func failureCode(_ result: Result<Void, RavensightError>) -> String? {
        if case .failure(let error) = result { return error.code }
        return nil
    }

    // MARK: Boot and batching

    func testBootChecksSettingsThenOpensSessionAndDelivers() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)
        client.start()
        client.track("level_completed", data: ["level": 1])
        client.track("player_died")
        flushAndWait(client)

        XCTAssertEqual(client.queuedEventCount, 0)
        XCTAssertTrue(client.isReady)
        XCTAssertNil(client.statusReason)
        XCTAssertEqual(client.sessionToken, "sess_1")
        XCTAssertEqual(transport.requests(suffix: "/settings").count, 1)
        XCTAssertEqual(transport.requests(suffix: "/session").count, 1)
        XCTAssertEqual(transport.sentEvents().map { $0.name }, ["level_completed", "player_died"])
        XCTAssertEqual(transport.sentEvents().first?.token, "sess_1")
        XCTAssertEqual(transport.requests(suffix: "/settings").first?.url, "https://fake.test/api/v1/settings")
    }

    func testTenQuickTracksMakeOneBatch() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)
        client.start()
        flushAndWait(client) // settings answered, no session yet (nothing queued)

        for index in 0..<10 { client.track("tap", data: ["i": index]) }
        settle(client)
        XCTAssertTrue(transport.requests(suffix: "/track/batch").isEmpty, "track() only enqueues")
        XCTAssertEqual(client.queuedEventCount, 10)

        flushAndWait(client)
        XCTAssertEqual(transport.requests(suffix: "/track/batch").count, 1)
        XCTAssertEqual(transport.sentEvents().count, 10)
    }

    func testFiftyQueuedSendWithoutAFlush() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)
        client.start()
        settle(client)
        for index in 0..<49 { client.track("tap", data: ["i": index]) }
        settle(client)
        XCTAssertTrue(transport.requests(suffix: "/track/batch").isEmpty)
        client.track("tap_50")
        settle(client)
        XCTAssertEqual(transport.requests(suffix: "/track/batch").count, 1)
        XCTAssertEqual(transport.sentEvents().count, 50)
    }

    func testFlushCompletionFiresEvenWhenIdle() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)
        client.start()
        let done = expectation(description: "flush completion")
        client.flush { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    // MARK: Opt-out in every order

    func testDisabledConfigurationMakesZeroRequests() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport, lifecycleEvents: true) { $0.enabled = false }
        client.start()
        XCTAssertFalse(client.track("ignored"))
        flushAndWait(client)

        var suggestions: [[String: Any]]?
        let fetched = expectation(description: "suggestions")
        client.fetchSuggestions { result in
            if case .success(let list) = result { suggestions = list }
            fetched.fulfill()
        }
        wait(for: [fetched], timeout: 2)
        XCTAssertEqual(suggestions?.count, 0, "an empty list, same callback shape")
        XCTAssertEqual(failureCode(feedbackResult(client, "hello", category: "bug")), "disabled")

        settle(client)
        XCTAssertTrue(transport.requests.isEmpty, "no request of any kind while disabled")
        XCTAssertEqual(client.statusReason, "disabled")
        XCTAssertFalse(defaults.bool(forKey: RavensightClient.optOutKey), "enabled is never persisted")

        // Enabled later in the run: game_started is queued then, once.
        client.setEnabled(true)
        client.setEnabled(true)
        flushAndWait(client)
        XCTAssertEqual(transport.sentEvents().map { $0.name }, ["game_started"])
    }

    func testOptOutBeforeStartMakesZeroRequestsAndSurvivesANewClient() {
        let transport = FakeTransport()
        let first = makeClient(transport: transport, lifecycleEvents: true)
        first.setTrackingEnabled(false) // before start, the natural consent order
        XCTAssertTrue(defaults.bool(forKey: RavensightClient.optOutKey), "written synchronously")
        first.start()
        first.track("ignored")
        flushAndWait(first)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(first.isOptedOut)
        XCTAssertEqual(first.statusReason, "disabled")

        // Next launch: the saved opt-out wins over enabled = true.
        let second = makeClient(transport: transport, lifecycleEvents: true) { $0.enabled = true }
        XCTAssertTrue(second.isOptedOut)
        second.start()
        second.track("ignored")
        flushAndWait(second)
        XCTAssertTrue(transport.requests.isEmpty)

        // Opting back in queues game_started once and starts sending.
        second.setTrackingEnabled(true)
        flushAndWait(second)
        XCTAssertFalse(defaults.bool(forKey: RavensightClient.optOutKey))
        XCTAssertEqual(transport.sentEvents().map { $0.name }, ["game_started"])
    }

    func testOptOutWrittenEvenWhenConstructedDisabled() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport) { $0.enabled = false }
        client.setTrackingEnabled(false)
        XCTAssertTrue(defaults.bool(forKey: RavensightClient.optOutKey))
    }

    func testFacadeSavesTheOptOutBeforeStart() {
        Ravensight.resetForTesting()
        XCTAssertNil(Ravensight.shared, "the facade is never started in tests")
        let standard = UserDefaults.standard
        let saved = standard.object(forKey: RavensightClient.optOutKey)
        defer {
            if let saved = saved { standard.set(saved, forKey: RavensightClient.optOutKey) }
            else { standard.removeObject(forKey: RavensightClient.optOutKey) }
        }
        Ravensight.setTrackingEnabled(false)
        XCTAssertTrue(standard.bool(forKey: RavensightClient.optOutKey))
        XCTAssertTrue(Ravensight.isOptedOut)
        Ravensight.setTrackingEnabled(true)
        XCTAssertFalse(Ravensight.isOptedOut)
    }

    func testOptOutAfterStartClearsTheQueueAndStops() {
        let transport = FakeTransport()
        transport.batchStatus = 500 // keep events stuck in the queue
        let client = makeClient(transport: transport)
        client.start()
        client.track("stuck")
        flushAndWait(client)
        XCTAssertEqual(client.queuedEventCount, 1)

        client.setTrackingEnabled(false)
        settle(client)
        let before = transport.requests.count
        XCTAssertEqual(client.queuedEventCount, 0)
        XCTAssertFalse(client.track("ignored"))
        flushAndWait(client)
        XCTAssertEqual(transport.requests.count, before)
    }

    // MARK: Device id

    func testDeviceIdIsRandomPersistedAndKeptAsSaved() {
        let transport = FakeTransport()
        let first = makeClient(transport: transport)
        let id = first.deviceId
        XCTAssertTrue(id.hasPrefix("dev_"))
        XCTAssertEqual(id.count, 36)
        XCTAssertTrue(id.dropFirst(4).allSatisfy { $0.isHexDigit })
        XCTAssertEqual(makeClient(transport: transport).deviceId, id, "persisted, not per run")

        defaults.set("legacy-id-from-0.1", forKey: RavensightClient.deviceIdKey)
        XCTAssertEqual(makeClient(transport: transport).deviceId, "legacy-id-from-0.1", "never rewritten")
    }

    func testResetDeviceIdMintsSavesClearsAndReopens() {
        let transport = FakeTransport()
        transport.batchStatus = 500
        let client = makeClient(transport: transport)
        let old = client.deviceId
        client.start()
        client.track("stuck")
        flushAndWait(client)

        let fresh = client.resetDeviceId()
        XCTAssertNotEqual(fresh, old)
        XCTAssertEqual(client.deviceId, fresh)
        XCTAssertEqual(defaults.string(forKey: RavensightClient.deviceIdKey), fresh)
        settle(client)
        XCTAssertEqual(client.queuedEventCount, 0)
        XCTAssertNil(client.sessionToken)

        transport.batchStatus = 202
        client.track("after_reset")
        flushAndWait(client)
        let lastSession = transport.requests(suffix: "/session").last
        let body = lastSession?.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(body?["deviceId"] as? String, fresh)
    }

    // MARK: Startup outcome

    func testSettingsUnauthorizedMakesOneRequestThenNone() {
        let transport = FakeTransport()
        transport.settingsStatus = 401
        let client = makeClient(transport: transport, lifecycleEvents: true)
        var reasons: [String?] = []
        client.onStatusChange = { reasons.append($0) }
        client.start()
        for index in 0..<60 { client.track("e", data: ["i": index]) }
        settle(client)
        waitUntil { reasons.count == 1 }

        XCTAssertEqual(transport.requests.count, 1, "the settings check, then nothing")
        XCTAssertEqual(client.statusReason, "invalid_key")
        XCTAssertEqual(reasons, ["invalid_key"])
        XCTAssertFalse(client.isReady)
        XCTAssertEqual(client.queuedEventCount, 0, "the queue is cleared")
        XCTAssertFalse(client.track("after"))

        var suggestionsCalled = false
        let fetched = expectation(description: "suggestions")
        client.fetchSuggestions { _ in suggestionsCalled = true; fetched.fulfill() }
        wait(for: [fetched], timeout: 2)
        XCTAssertTrue(suggestionsCalled)
        XCTAssertEqual(transport.requests.count, 1, "no suggestions request after a refused key")

        // The run is over: not even an explicit flush tries again.
        flushAndWait(client)
        settle(client)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testSessionForbiddenTrackingDisabledStopsSending() {
        let transport = FakeTransport()
        transport.sessionStatus = 403
        transport.sessionError = "tracking_disabled"
        let client = makeClient(transport: transport)
        client.start()
        client.track("first")
        flushAndWait(client)

        XCTAssertEqual(client.statusReason, "tracking_disabled")
        XCTAssertFalse(client.isTrackingEnabled)
        XCTAssertEqual(client.queuedEventCount, 0)
        let before = transport.requests.count
        XCTAssertFalse(client.track("ignored"))
        flushAndWait(client)
        XCTAssertEqual(transport.requests.count, before)
    }

    func testKillSwitchStopsEverything() {
        let transport = FakeTransport()
        transport.trackingEnabled = false
        let client = makeClient(transport: transport)
        client.start()
        settle(client)
        XCTAssertFalse(client.isTrackingEnabled)
        XCTAssertEqual(client.statusReason, "tracking_disabled")
        XCTAssertFalse(client.track("ignored"))
        flushAndWait(client)
        XCTAssertTrue(transport.requests(suffix: "/session").isEmpty)
        XCTAssertTrue(transport.requests(suffix: "/track/batch").isEmpty)
    }

    // MARK: Feedback and suggestions

    func testFeedbackValidatedLocally() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)
        client.start()
        client.track("warmup")
        flushAndWait(client)

        XCTAssertEqual(failureCode(feedbackResult(client, "   ")), "empty_message")
        XCTAssertEqual(failureCode(feedbackResult(client, "x", category: "balance")), "invalid_category")
        XCTAssertEqual(failureCode(feedbackResult(client, "x", rating: 6)), "invalid_rating")
        XCTAssertTrue(transport.requests(suffix: "/feedback").isEmpty, "no request for a local failure")

        XCTAssertNil(failureCode(feedbackResult(client, "The boss fight drags", category: "suggestion", rating: 3)))
        let sent = transport.requests(suffix: "/feedback")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.headers["X-Session-Token"], "sess_1")
        XCTAssertEqual(Ravensight.feedbackCategories, ["bug", "suggestion", "complaint", "praise", "playtest", "other"])
    }

    func testSubmitFeedbackWithoutSessionFailsFast() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)
        XCTAssertEqual(failureCode(feedbackResult(client, "hello")), "no_session")
    }

    func testFetchSuggestions() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)
        var title: String?
        let done = expectation(description: "suggestions completion")
        client.fetchSuggestions { result in
            if case .success(let suggestions) = result { title = suggestions.first?["title"] as? String }
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(title, "Shorten level 3")
        XCTAssertEqual(transport.requests(suffix: "/agent/suggestions").first?.headers["X-API-Key"], "gt_live_test")
    }

    // MARK: Lifecycle

    func testGameStartedOnceAtStart() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport, lifecycleEvents: true)
        client.start()
        client.start()
        client.track("after")
        client.setEnabled(true)
        client.setTrackingEnabled(true)
        flushAndWait(client)
        XCTAssertEqual(transport.sentEvents().map { $0.name }, ["game_started", "after"])
        XCTAssertEqual(transport.sentEvents().first?.timestamp, clock.nowMs / 1000)
    }

    func testShortBackgroundSendsNothingAndKeepsTheSession() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport, lifecycleEvents: true)
        client.start()
        flushAndWait(client)

        client.handleDidEnterBackground()
        settle(client)
        let marker = defaults.dictionary(forKey: RavensightClient.markerKey)
        XCTAssertEqual(marker?["sessionToken"] as? String, "sess_1")
        XCTAssertEqual((marker?["backgroundedAt"] as? NSNumber)?.int64Value, clock.nowMs / 1000)

        clock.advance(seconds: 29 * 60)
        client.handleWillEnterForeground()
        flushAndWait(client)
        XCTAssertNil(defaults.object(forKey: RavensightClient.markerKey), "the marker is deleted on return")
        XCTAssertEqual(transport.sentEvents().map { $0.name }, ["game_started"], "no event for a short break")
        XCTAssertEqual(client.sessionToken, "sess_1")
    }

    func testThirtyMinutesInTheBackgroundEndsTheSession() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport, lifecycleEvents: true)
        client.start()
        flushAndWait(client)

        let leftAt = clock.nowMs / 1000
        client.handleDidEnterBackground()
        settle(client)
        clock.advance(seconds: 30 * 60)
        client.handleWillEnterForeground()
        settle(client)
        flushAndWait(client)

        let events = transport.sentEvents()
        XCTAssertEqual(events.map { $0.name }, ["game_started", "game_exited", "game_started"])
        XCTAssertEqual(events[1].token, "sess_1", "game_exited goes under the old session")
        XCTAssertEqual(events[1].timestamp, leftAt, "stamped when the player left")
        XCTAssertEqual(events[2].token, "sess_2", "a new session opens")
        XCTAssertEqual(events[2].timestamp, clock.nowMs / 1000)
        XCTAssertEqual(client.sessionToken, "sess_2")
    }

    func testColdLaunchMarkerReportsTheExitOnceBeforeAnythingElse() {
        let transport = FakeTransport()
        transport.batchStatus = 500 // the one attempt fails: no retry
        let leftAt = clock.nowMs / 1000 - 600
        defaults.set([
            "sessionToken": "sess_dead",
            "expiresAt": clock.nowMs / 1000 + 3600,
            "backgroundedAt": leftAt,
        ] as [String: Any], forKey: RavensightClient.markerKey)

        let client = makeClient(transport: transport)
        client.start()
        settle(client)

        let first = transport.requests.first
        XCTAssertEqual(first?.url, "https://fake.test/api/v1/track/batch")
        XCTAssertEqual(first?.headers["X-Session-Token"], "sess_dead")
        XCTAssertEqual(transport.sentEvents().first?.name, "game_exited")
        XCTAssertEqual(transport.sentEvents().first?.timestamp, leftAt)
        XCTAssertNil(defaults.object(forKey: RavensightClient.markerKey))

        clock.advance(seconds: 600)
        flushAndWait(client)
        XCTAssertEqual(transport.sentEvents().filter { $0.token == "sess_dead" }.count, 1, "one attempt only")
    }

    func testColdLaunchMarkerSkippedWhenExpiredOrOptedOut() {
        let transport = FakeTransport()
        defaults.set([
            "sessionToken": "sess_old",
            "expiresAt": clock.nowMs / 1000 - 1,
            "backgroundedAt": clock.nowMs / 1000 - 90_000,
        ] as [String: Any], forKey: RavensightClient.markerKey)
        let expired = makeClient(transport: transport)
        expired.start()
        settle(expired)
        XCTAssertTrue(transport.requests(suffix: "/track/batch").isEmpty)
        XCTAssertNil(defaults.object(forKey: RavensightClient.markerKey))

        defaults.set([
            "sessionToken": "sess_live",
            "expiresAt": clock.nowMs / 1000 + 3600,
            "backgroundedAt": clock.nowMs / 1000 - 60,
        ] as [String: Any], forKey: RavensightClient.markerKey)
        RavensightClient.saveTrackingEnabled(false, defaults: defaults, consent: nil)
        let optedOut = makeClient(transport: transport)
        optedOut.start()
        settle(optedOut)
        XCTAssertTrue(transport.requests(suffix: "/track/batch").isEmpty)
    }

    func testBackgroundLaunchWaitsForTheFirstForeground() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport, lifecycleEvents: true, backgroundLaunch: true)
        client.start()
        client.track("queued_in_background")
        flushAndWait(client)
        XCTAssertTrue(transport.requests.isEmpty, "no settings check or session from a background launch")

        client.handleDidBecomeActive()
        flushAndWait(client)
        XCTAssertEqual(transport.requests(suffix: "/settings").count, 1)
        XCTAssertEqual(Set(transport.sentEvents().map { $0.name }), ["queued_in_background", "game_started"])
    }

    func testPauseEventsAreOptIn() {
        let transport = FakeTransport()
        let quiet = makeClient(transport: transport, lifecycleEvents: true)
        quiet.start()
        quiet.handleDidEnterBackground()
        quiet.handleWillEnterForeground()
        quiet.handleFocusLost()
        quiet.handleFocusGained()
        flushAndWait(quiet)
        XCTAssertEqual(transport.sentEvents().map { $0.name }, ["game_started"])

        let loud = FakeTransport()
        let client = makeClient(transport: loud, lifecycleEvents: true) { $0.trackPauseEvents = true }
        client.start()
        client.handleDidEnterBackground()
        client.handleWillEnterForeground()
        flushAndWait(client)
        XCTAssertEqual(loud.sentEvents().map { $0.name }, ["game_started", "game_paused", "game_resumed"])
    }

    func testTerminateSendsGameExitedOnceAndHoldsAtMostTheBudget() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport, lifecycleEvents: true)
        client.start()
        flushAndWait(client)
        client.handleWillTerminate()
        client.handleWillTerminate()
        settle(client)
        XCTAssertEqual(transport.sentEvents().map { $0.name }, ["game_started", "game_exited"])

        let hung = FakeTransport()
        hung.hang = true
        let stuck = makeClient(transport: hung, lifecycleEvents: true)
        stuck.start()
        let began = Date()
        stuck.handleWillTerminate(holdSeconds: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(began), 1.0, "the quit is never held past the budget")
    }

    // MARK: Playtest

    func testPlaytestRunUsesTheRunIdentityAndHeader() {
        let transport = FakeTransport()
        RavensightClient.saveTrackingEnabled(false, defaults: defaults, consent: nil) // ignored at boot
        let client = makeClient(transport: transport, environment: [
            "RAVENSIGHT_PLAYTEST_TOKEN": "pt_token",
            "RAVENSIGHT_PLAYTEST_RUN_ID": "run_7",
        ])
        XCTAssertTrue(client.isPlaytest)
        XCTAssertTrue(client.isSynthetic)
        XCTAssertEqual(client.playtestDeviceId, "pt-run_7")
        XCTAssertEqual(client.deviceId, "", "no durable id yet, and never the synthetic one")
        XCTAssertNil(defaults.string(forKey: RavensightClient.deviceIdKey), "the saved id is never written at boot")

        client.setTrackingEnabled(false)
        XCTAssertTrue(defaults.bool(forKey: RavensightClient.optOutKey), "storage untouched by the no-op")

        client.start()
        client.track("e")
        flushAndWait(client)
        XCTAssertFalse(transport.requests.isEmpty)
        for request in transport.requests {
            XCTAssertEqual(request.headers["X-Ravensight-Playtest"], "pt_token")
        }
        let body = transport.requests(suffix: "/session").first?.body
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(body?["deviceId"] as? String, "pt-run_7")
    }

    func testPlaytestTokenWithoutRunIdNeverRunsAsAPlayer() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport) { $0.playtestToken = "pt_token" }
        client.start()
        client.track("e")
        flushAndWait(client)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(client.statusReason, "session_failed")
    }

    func testPlaytestJobClosedStopsTheRun() {
        let transport = FakeTransport()
        transport.batchStatus = 403
        transport.batchError = "playtest_job_closed"
        let client = makeClient(transport: transport) {
            $0.playtestToken = "pt_token"
            $0.playtestRunId = "run_9"
        }
        client.start()
        client.track("e")
        flushAndWait(client)
        XCTAssertEqual(client.statusReason, "playtest_job_closed")
        XCTAssertEqual(client.queuedEventCount, 0)
        let before = transport.requests.count
        XCTAssertFalse(client.track("f"))
        flushAndWait(client)
        XCTAssertEqual(transport.requests.count, before)
    }

    // MARK: Fix round 1

    func testDeferredStartStillReportsTheColdLaunchMarker() {
        let transport = FakeTransport()
        let leftAt = clock.nowMs / 1000 - 300
        defaults.set([
            "sessionToken": "sess_swiped",
            "expiresAt": clock.nowMs / 1000 + 3600,
            "backgroundedAt": leftAt,
        ] as [String: Any], forKey: RavensightClient.markerKey)

        let client = makeClient(transport: transport, lifecycleEvents: true, backgroundLaunch: true)
        client.start()
        client.handleWillEnterForeground()
        client.handleDidBecomeActive()
        settle(client)

        XCTAssertEqual(transport.requests.first?.headers["X-Session-Token"], "sess_swiped", "sent first")
        let exits = transport.sentEvents().filter { $0.name == "game_exited" }
        XCTAssertEqual(exits.count, 1)
        XCTAssertEqual(exits.first?.token, "sess_swiped")
        XCTAssertEqual(exits.first?.timestamp, leftAt)
        XCTAssertNil(defaults.object(forKey: RavensightClient.markerKey))
    }

    @available(*, deprecated)
    private func legacyDisable() {
        Ravensight.setEnabled(false)
    }

    @available(*, deprecated)
    func testDeprecatedSetEnabledBeforeStartStillHolds() {
        Ravensight.resetForTesting()
        defer { Ravensight.resetForTesting() }
        let transport = FakeTransport()
        legacyDisable() // the 0.1 order: the toggle first, then start
        let client = Ravensight.start(RavensightConfiguration(ingestKey: "gt_live_test")) { configuration in
            var configuration = configuration
            configuration.apiUrl = "https://fake.test"
            configuration.flushInterval = 0
            return self.makeClient(transport: transport, lifecycleEvents: true) { $0 = configuration }
        }
        client.track("ignored")
        flushAndWait(client)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(client.statusReason, "disabled")
        XCTAssertFalse(defaults.bool(forKey: RavensightClient.optOutKey), "never saved")
    }

    func testSessionAnswerFromBeforeAResetIsIgnored() {
        let transport = FakeTransport()
        transport.holdSuffix = "/session"
        let client = makeClient(transport: transport)
        client.start()
        client.track("before_reset")
        client.flush()
        settle(client)
        XCTAssertEqual(transport.heldCount, 1)

        let fresh = client.resetDeviceId()
        settle(client)
        transport.release(RavensightResponse(
            status: 201,
            body: try? JSONSerialization.data(withJSONObject: ["token": "sess_old_identity", "expiresIn": 86_400])
        ))
        settle(client)
        XCTAssertNil(client.sessionToken, "the old identity's session is not adopted")

        client.track("after_reset")
        flushAndWait(client)
        let body = transport.requests(suffix: "/session").last?.body
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(body?["deviceId"] as? String, fresh)
        XCTAssertEqual(transport.sentEvents().last?.name, "after_reset")
        XCTAssertNotEqual(transport.sentEvents().last?.token, "sess_old_identity")
    }

    func testBatchAnswerFromBeforeAnOptOutDoesNotDropNewEvents() {
        let transport = FakeTransport()
        transport.holdSuffix = "/track/batch"
        let client = makeClient(transport: transport)
        client.start()
        client.track("a")
        client.flush()
        settle(client)
        XCTAssertEqual(transport.heldCount, 1)

        client.setTrackingEnabled(false)
        client.setTrackingEnabled(true)
        client.track("b")
        settle(client)
        transport.batchStatus = 500 // the follow-up send fails, so b stays visible
        transport.release(RavensightResponse(status: 202))
        settle(client)
        XCTAssertEqual(client.queuedEventCount, 1, "the stale 202 did not remove b")

        transport.batchStatus = 202
        flushAndWait(client)
        XCTAssertEqual(client.queuedEventCount, 0)
        XCTAssertEqual(transport.sentEvents().last?.name, "b")
    }
}
