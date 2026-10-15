import XCTest
@testable import Ravensight

/// 0.3.0: the stop-all control, synthetic identity, the persisted queue,
/// and queued versus delivered (stats, lastDelivery, onFlush). Same fake
/// transport and clock as RavensightClientTests, a throwaway UserDefaults
/// suite and a throwaway queue directory per test.
final class RavensightControlTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var queueDirectory: URL!
    private let clock = FakeClock()

    private let playtestEnvironment = [
        "RAVENSIGHT_PLAYTEST_TOKEN": "pt_token",
        "RAVENSIGHT_PLAYTEST_RUN_ID": "run_7",
    ]

    override func setUp() {
        super.setUp()
        suiteName = "io.ravensight.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        queueDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ravensight-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: queueDirectory)
        Ravensight.resetForTesting()
        super.tearDown()
    }

    private func makeClient(
        transport: FakeTransport,
        environment: [String: String] = [:],
        configure: (inout RavensightConfiguration) -> Void = { _ in }
    ) -> RavensightClient {
        var configuration = RavensightConfiguration(ingestKey: "gt_live_test")
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
            queueDirectory: queueDirectory
        )
        client.persistDelay = persistDelay
        // The file is read on the work queue; wait for it like a caller of
        // the public properties would see it settle.
        let loaded = expectation(description: "loaded")
        client.onWorkQueue { loaded.fulfill() }
        wait(for: [loaded], timeout: 2)
        return client
    }

    /// Writes immediately unless a test is about the coalescing itself.
    private var persistDelay: TimeInterval = 0

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

    /// Lets main queue deliveries (onFlush, completions) run.
    private func drainMain() {
        let done = expectation(description: "main drained")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    private func feedbackCode(_ client: RavensightClient) -> String? {
        var code: String?
        let done = expectation(description: "feedback")
        client.submitFeedback("hello", category: "bug") { result in
            if case .failure(let error) = result { code = error.code }
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        return code
    }

    private func sessionDeviceIds(_ transport: FakeTransport) -> [String] {
        return transport.requests(suffix: "/session").compactMap { request in
            request.body
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0["deviceId"] as? String }
        }
    }

    private var queueFiles: [URL] {
        return (try? FileManager.default.contentsOfDirectory(at: queueDirectory, includingPropertiesForKeys: nil)) ?? []
    }

    private func savedEventNames() -> [String] {
        guard let url = queueFiles.first(where: { $0.pathExtension == "json" }),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = object["groups"] as? [[String: Any]] else { return [] }
        return groups.flatMap { ($0["events"] as? [[String: Any]] ?? []).compactMap { $0["event"] as? String } }
    }

    // MARK: Stop-all control

    func testStopAllTelemetryStopsANormalSessionAndSavesNothing() {
        let transport = FakeTransport()
        transport.batchStatus = 503 // "a" stays queued until the stop
        let client = makeClient(transport: transport)
        client.start()
        XCTAssertTrue(client.track("a"))
        flushAndWait(client)
        XCTAssertEqual(client.queuedEventCount, 1)

        client.stopAllTelemetry()
        XCTAssertFalse(client.track("b"), "refused the moment the call returns")
        settle(client)
        XCTAssertEqual(client.queuedEventCount, 0, "the queue is cleared")
        XCTAssertEqual(client.statusReason, "disabled")
        let before = transport.requests.count
        flushAndWait(client)
        XCTAssertEqual(feedbackCode(client), "disabled")
        XCTAssertEqual(transport.requests.count, before, "no request of any kind while stopped")
        XCTAssertFalse(defaults.bool(forKey: RavensightClient.optOutKey), "nothing is saved")

        client.resumeTelemetry()
        transport.batchStatus = 202
        XCTAssertTrue(client.track("c"))
        flushAndWait(client)
        XCTAssertEqual(transport.sentEvents().map { $0.name }.filter { $0 != "a" }, ["c"])
        XCTAssertEqual(transport.sentEvents().last?.name, "c", "the discarded a is never resent")

        // A new launch is not stopped: stopAllTelemetry persists nothing.
        let next = makeClient(transport: FakeTransport())
        XCTAssertTrue(next.isEnabled)
        XCTAssertNil(next.statusReason)
    }

    func testStopAllTelemetryStopsASyntheticSessionThatTheOptOutDoesNot() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport, environment: playtestEnvironment)
        client.start()

        // The player's opt-out is ignored by a synthetic run.
        client.setTrackingEnabled(false)
        XCTAssertTrue(client.track("still_running"))
        flushAndWait(client)
        XCTAssertEqual(transport.sentEvents().map { $0.name }, ["still_running"])

        // The stop-all control is not.
        client.stopAllTelemetry()
        XCTAssertFalse(client.track("after_stop"))
        let before = transport.requests.count
        flushAndWait(client)
        XCTAssertEqual(transport.requests.count, before)
        XCTAssertEqual(client.statusReason, "disabled")

        client.resumeTelemetry()
        XCTAssertTrue(client.track("resumed"))
        flushAndWait(client)
        XCTAssertEqual(transport.sentEvents().last?.name, "resumed")
    }

    func testResumeDoesNotOverrideASavedOptOut() {
        let transport = FakeTransport()
        RavensightClient.saveTrackingEnabled(false, defaults: defaults)
        let client = makeClient(transport: transport)
        client.start()
        client.stopAllTelemetry()
        client.resumeTelemetry()
        XCTAssertFalse(client.track("a"))
        flushAndWait(client)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(client.statusReason, "disabled")
    }

    func testFacadeStopAllBeforeStartHoldsForThisProcess() {
        Ravensight.resetForTesting()
        Ravensight.stopAllTelemetry()
        let transport = FakeTransport()
        var configuration = RavensightConfiguration(ingestKey: "gt_live_test")
        configuration.trackLifecycleEvents = false
        let client = Ravensight.start(configuration) { configuration in
            RavensightClient(
                configuration: configuration, transport: transport, now: nil,
                defaults: self.defaults, environment: [:],
                isBackgroundLaunch: { false }, installsLifecycleObservers: false
            )
        }
        XCTAssertFalse(client.isEnabled)
        XCTAssertFalse(Ravensight.track("a"))
        Ravensight.resumeTelemetry()
        XCTAssertTrue(Ravensight.track("b"))
        XCTAssertFalse(defaults.bool(forKey: RavensightClient.optOutKey))
    }

    // MARK: Synthetic identity

    func testNormalSessionIdentity() {
        let transport = FakeTransport()
        let client = makeClient(transport: transport)
        XCTAssertFalse(client.isSynthetic)
        XCTAssertNil(client.playtestDeviceId)
        XCTAssertTrue(client.deviceId.hasPrefix("dev_"))
        XCTAssertEqual(defaults.string(forKey: RavensightClient.deviceIdKey), client.deviceId)
        client.start()
        client.track("a")
        flushAndWait(client)
        XCTAssertEqual(sessionDeviceIds(transport), [client.deviceId])
    }

    func testPlaytestLaunchThenNormalLaunchKeepsTheDurableId() {
        let first = makeClient(transport: FakeTransport())
        let durable = first.deviceId
        XCTAssertTrue(durable.hasPrefix("dev_"))

        let playtestTransport = FakeTransport()
        let playtest = makeClient(transport: playtestTransport, environment: playtestEnvironment)
        XCTAssertTrue(playtest.isSynthetic)
        XCTAssertEqual(playtest.deviceId, durable, "the app still sees the durable id")
        XCTAssertEqual(playtest.playtestDeviceId, "pt-run_7")
        playtest.start()
        playtest.track("a")
        flushAndWait(playtest)
        XCTAssertEqual(sessionDeviceIds(playtestTransport), ["pt-run_7"], "the wire carries the synthetic id")
        XCTAssertEqual(defaults.string(forKey: RavensightClient.deviceIdKey), durable, "never overwritten")

        let normalTransport = FakeTransport()
        let normal = makeClient(transport: normalTransport)
        XCTAssertEqual(normal.deviceId, durable)
        XCTAssertNil(normal.playtestDeviceId)
        normal.start()
        normal.track("b")
        flushAndWait(normal)
        XCTAssertEqual(sessionDeviceIds(normalTransport), [durable])
    }

    func testResetDuringPlaytestSavesANewDurableIdAndNeverReturnsTheSyntheticOne() {
        let durable = makeClient(transport: FakeTransport()).deviceId

        let transport = FakeTransport()
        let playtest = makeClient(transport: transport, environment: playtestEnvironment)
        playtest.start()
        playtest.track("before")
        flushAndWait(playtest)

        let fresh = playtest.resetDeviceId()
        XCTAssertTrue(fresh.hasPrefix("dev_"))
        XCTAssertNotEqual(fresh, durable)
        XCTAssertFalse(fresh.hasPrefix("pt-"))
        XCTAssertEqual(defaults.string(forKey: RavensightClient.deviceIdKey), fresh)
        XCTAssertEqual(playtest.deviceId, fresh, "the app sees the new durable id")
        XCTAssertEqual(playtest.playtestDeviceId, "pt-run_7", "the run keeps its synthetic id")

        // The synthetic run carries on under its own session and id.
        playtest.track("after")
        flushAndWait(playtest)
        XCTAssertEqual(transport.sentEvents().map { $0.name }, ["before", "after"])
        XCTAssertEqual(sessionDeviceIds(transport), ["pt-run_7"], "no new session, no durable id on the wire")

        let next = makeClient(transport: FakeTransport())
        XCTAssertEqual(next.deviceId, fresh, "the next normal launch uses the new durable id")
    }

    func testPlaytestOnAFreshInstallHasNoDurableIdUntilReset() {
        let playtest = makeClient(transport: FakeTransport(), environment: playtestEnvironment)
        XCTAssertEqual(playtest.deviceId, "")
        XCTAssertNil(defaults.string(forKey: RavensightClient.deviceIdKey))
        let fresh = playtest.resetDeviceId()
        XCTAssertEqual(playtest.deviceId, fresh)
        XCTAssertEqual(defaults.string(forKey: RavensightClient.deviceIdKey), fresh)
    }

    // MARK: Persisted queue

    func testPersistQueueIsOffByDefault() {
        let client = makeClient(transport: FakeTransport())
        client.track("a")
        settle(client)
        XCTAssertTrue(queueFiles.isEmpty)
    }

    func testPersistedQueueSurvivesARestart() {
        let first = makeClient(transport: FakeTransport()) { $0.persistQueue = true }
        // Never started: a force quit before anything left.
        first.track("a")
        first.track("b", data: ["n": 2])
        first.track("c")
        settle(first)
        XCTAssertEqual(savedEventNames(), ["a", "b", "c"])

        let transport = FakeTransport()
        let second = makeClient(transport: transport) { $0.persistQueue = true }
        XCTAssertEqual(second.queuedEventCount, 3)
        XCTAssertEqual(second.stats.restored, 3)
        second.start()
        second.track("d")
        flushAndWait(second)
        XCTAssertEqual(transport.sentEvents().map { $0.name }, ["a", "b", "c", "d"])
        XCTAssertTrue(queueFiles.filter { $0.pathExtension == "json" }.isEmpty, "an empty queue deletes the file")
    }

    func testRestoredEventsGoOutUnderTheSessionTheyWereQueuedIn() {
        let firstTransport = FakeTransport()
        firstTransport.sessionPrefix = "old"
        firstTransport.batchStatus = 503 // held, so they are still queued at the force quit
        let first = makeClient(transport: firstTransport) { $0.persistQueue = true }
        first.start()
        first.track("last_words")
        flushAndWait(first)
        XCTAssertEqual(first.sessionToken, "old_1")

        let transport = FakeTransport()
        transport.sessionPrefix = "new"
        let second = makeClient(transport: transport) { $0.persistQueue = true }
        second.start()
        second.track("fresh")
        flushAndWait(second)
        let sent = transport.sentEvents()
        XCTAssertEqual(sent.first { $0.name == "last_words" }?.token, "old_1")
        XCTAssertEqual(sent.first { $0.name == "fresh" }?.token, "new_1")
    }

    func testRestoredEventsWhoseSessionExpiredJoinTheNewSession() {
        let firstTransport = FakeTransport()
        firstTransport.sessionPrefix = "old"
        firstTransport.batchStatus = 503
        let first = makeClient(transport: firstTransport) { $0.persistQueue = true }
        first.start()
        first.track("stale")
        flushAndWait(first)

        clock.advance(seconds: 2 * 86_400) // the old session (one day) is gone
        let transport = FakeTransport()
        transport.sessionPrefix = "new"
        let second = makeClient(transport: transport) { $0.persistQueue = true }
        second.start()
        flushAndWait(second)
        XCTAssertEqual(transport.sentEvents().map { $0.token }, ["new_1"])
    }

    func testPersistedQueueKeepsAtMost500Events() {
        let client = makeClient(transport: FakeTransport()) {
            $0.persistQueue = true
            $0.maxQueueSize = 800
        }
        for index in 0..<600 { client.track("e\(index)") }
        settle(client)
        let names = savedEventNames()
        XCTAssertEqual(names.count, 500)
        XCTAssertEqual(names.first, "e100", "the newest are kept")
        XCTAssertEqual(names.last, "e599")
        XCTAssertEqual(queueFiles.count, 1, "atomic writes leave no temporary file behind")
    }

    func testOptOutDiscardsThePersistedQueue() {
        let client = makeClient(transport: FakeTransport()) { $0.persistQueue = true }
        client.track("a")
        settle(client)
        XCTAssertFalse(queueFiles.isEmpty)
        client.setTrackingEnabled(false)
        settle(client)
        XCTAssertTrue(queueFiles.isEmpty)
    }

    func testASavedOptOutDeletesTheFileAtLaunch() {
        let first = makeClient(transport: FakeTransport()) { $0.persistQueue = true }
        first.track("a")
        settle(first)
        RavensightClient.saveTrackingEnabled(false, defaults: defaults)
        let second = makeClient(transport: FakeTransport()) { $0.persistQueue = true }
        XCTAssertEqual(second.queuedEventCount, 0)
        XCTAssertTrue(queueFiles.isEmpty)
    }

    func testStopAllAndResetDiscardThePersistedQueue() {
        let client = makeClient(transport: FakeTransport()) { $0.persistQueue = true }
        client.track("a")
        settle(client)
        client.stopAllTelemetry()
        settle(client)
        XCTAssertTrue(queueFiles.isEmpty)

        client.resumeTelemetry()
        client.track("b")
        settle(client)
        XCTAssertFalse(queueFiles.isEmpty)
        client.resetDeviceId()
        settle(client)
        XCTAssertTrue(queueFiles.isEmpty)
    }

    /// The game's own switch turned on later in the run (a consent screen
    /// answered yes): the earlier launch's events are loaded then. A stop
    /// or opt-out before that deletes them instead (next two tests).
    func testAClientBuiltDisabledThenEnabledLoadsTheQueue() {
        let first = makeClient(transport: FakeTransport()) { $0.persistQueue = true }
        first.track("kept")
        settle(first)

        let transport = FakeTransport()
        let second = makeClient(transport: transport) {
            $0.persistQueue = true
            $0.enabled = false
        }
        XCTAssertEqual(second.queuedEventCount, 0)
        XCTAssertEqual(savedEventNames(), ["kept"], "left on disk while disabled")
        second.start()
        second.setEnabled(true)
        flushAndWait(second)
        XCTAssertEqual(transport.sentEvents().map { $0.name }, ["kept"])
    }

    func testAStopBeforeStartDeletesAQueueStillWaitingToLoad() {
        let first = makeClient(transport: FakeTransport()) { $0.persistQueue = true }
        first.track("previous_process")
        settle(first)

        let transport = FakeTransport()
        let second = makeClient(transport: transport) {
            $0.persistQueue = true
            $0.enabled = false
        }
        second.stopAllTelemetry()
        settle(second)
        XCTAssertTrue(queueFiles.isEmpty, "a stop keeps nothing")
        second.start()
        second.resumeTelemetry()
        flushAndWait(second)
        XCTAssertTrue(transport.sentEvents().isEmpty, "the previous process's events are never sent")
        XCTAssertEqual(second.stats.restored, 0)
    }

    func testAnOptOutBeforeStartDeletesAQueueStillWaitingToLoad() {
        let first = makeClient(transport: FakeTransport()) { $0.persistQueue = true }
        first.track("previous_process")
        settle(first)

        let transport = FakeTransport()
        let second = makeClient(transport: transport) {
            $0.persistQueue = true
            $0.enabled = false
        }
        second.setTrackingEnabled(false)
        settle(second)
        XCTAssertTrue(queueFiles.isEmpty)
        second.setTrackingEnabled(true)
        second.start()
        second.setEnabled(true)
        flushAndWait(second)
        XCTAssertTrue(transport.sentEvents().isEmpty)
    }

    func testResetDeletesTheOldIdentitysQueueFileInEveryPath() {
        // Normal session, with the file still waiting to load.
        let first = makeClient(transport: FakeTransport()) { $0.persistQueue = true }
        first.track("old_identity")
        settle(first)
        let disabled = makeClient(transport: FakeTransport()) {
            $0.persistQueue = true
            $0.enabled = false
        }
        disabled.resetDeviceId()
        settle(disabled)
        XCTAssertTrue(queueFiles.isEmpty)

        // Synthetic session: the file a normal launch left behind goes too.
        let again = makeClient(transport: FakeTransport()) { $0.persistQueue = true }
        again.track("old_identity")
        settle(again)
        XCTAssertFalse(queueFiles.isEmpty)
        let playtest = makeClient(transport: FakeTransport(), environment: playtestEnvironment) {
            $0.persistQueue = true
        }
        XCTAssertFalse(queueFiles.isEmpty, "a synthetic run leaves it alone until a reset")
        playtest.resetDeviceId()
        settle(playtest)
        XCTAssertTrue(queueFiles.isEmpty)
    }

    func testDeleteAllRemovesEveryQueueFileBeforeStart() throws {
        try FileManager.default.createDirectory(at: queueDirectory, withIntermediateDirectories: true)
        let keep = queueDirectory.appendingPathComponent("unrelated.txt")
        try Data("x".utf8).write(to: keep)
        for key in ["gt_live_a", "gt_live_b"] {
            let url = RavensightQueueStore.defaultFileURL(ingestKey: key, directory: queueDirectory)!
            try Data("{}".utf8).write(to: url)
        }
        RavensightQueueStore.deleteAll(directory: queueDirectory)
        XCTAssertEqual(queueFiles.map { $0.lastPathComponent }, ["unrelated.txt"])
    }

    func testWritesAreCoalescedAndBackgroundWritesAtOnce() {
        persistDelay = 0.25
        let client = makeClient(transport: FakeTransport()) { $0.persistQueue = true }
        for index in 0..<5 { client.track("e\(index)") }
        settle(client)
        XCTAssertEqual(client.queueWrites, 0, "not yet: the burst is still being coalesced")
        let written = expectation(description: "coalesced write")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { written.fulfill() }
        wait(for: [written], timeout: 2)
        settle(client)
        XCTAssertEqual(client.queueWrites, 1)
        XCTAssertEqual(savedEventNames().count, 5)

        client.track("before_background")
        client.handleDidEnterBackground()
        settle(client)
        XCTAssertEqual(savedEventNames().last, "before_background", "background writes without waiting")
    }

    func testEventsTooOldToRestoreCountAsDropped() throws {
        try FileManager.default.createDirectory(at: queueDirectory, withIntermediateDirectories: true)
        let url = RavensightQueueStore.defaultFileURL(ingestKey: "gt_live_test", directory: queueDirectory)!
        let nowSec = clock.nowMs / 1000
        let file: [String: Any] = ["version": 1, "groups": [[
            "expiresAtMs": 0,
            "events": [
                ["event": "ancient", "data": [:], "timestamp": nowSec - 100 * 86_400],
                ["event": "recent", "data": [:], "timestamp": nowSec - 60],
            ],
        ]]]
        try JSONSerialization.data(withJSONObject: file).write(to: url)
        let client = makeClient(transport: FakeTransport()) { $0.persistQueue = true }
        XCTAssertEqual(client.stats.restored, 1)
        XCTAssertEqual(client.stats.droppedEvents, 1)
        XCTAssertEqual(client.stats.queued, 0, "restored events were queued by an earlier launch")
    }

    func testASyntheticSessionNeverPersists() {
        let client = makeClient(transport: FakeTransport(), environment: playtestEnvironment) {
            $0.persistQueue = true
        }
        client.track("a")
        settle(client)
        XCTAssertTrue(queueFiles.isEmpty)
    }

    func testAMalformedQueueFileIsIgnored() throws {
        try FileManager.default.createDirectory(at: queueDirectory, withIntermediateDirectories: true)
        let url = RavensightQueueStore.defaultFileURL(ingestKey: "gt_live_test", directory: queueDirectory)!
        try Data("not json".utf8).write(to: url)
        let client = makeClient(transport: FakeTransport()) { $0.persistQueue = true }
        XCTAssertEqual(client.queuedEventCount, 0)
    }

    // MARK: Queued versus delivered

    func testStatsSeparateQueuedFromDelivered() {
        let transport = FakeTransport()
        transport.batchStatus = 500
        let client = makeClient(transport: transport)
        var outcomes: [RavensightFlushOutcome] = []
        client.onFlush = { outcomes.append($0) }
        client.start()
        XCTAssertTrue(client.track("a"))
        XCTAssertTrue(client.track("b"))
        flushAndWait(client)
        drainMain()

        XCTAssertEqual(client.stats.queued, 2)
        XCTAssertEqual(client.stats.delivered, 0)
        XCTAssertEqual(client.stats.pending, 2)
        XCTAssertEqual(client.lastDelivery?.result, .failed(status: 500))
        XCTAssertEqual(outcomes.last, RavensightFlushOutcome(sent: 0, status: 500, error: "http_500", pending: 2))

        transport.batchStatus = 202
        flushAndWait(client)
        drainMain()
        XCTAssertEqual(client.stats.delivered, 2)
        XCTAssertEqual(client.stats.pending, 0)
        XCTAssertEqual(client.lastDelivery?.result, .accepted)
        XCTAssertEqual(outcomes.last, RavensightFlushOutcome(sent: 2, status: 202, error: nil, pending: 0))
        XCTAssertTrue(outcomes.last?.succeeded ?? false)
    }

    func testOfflineDeliveryIsReported() {
        let transport = FakeTransport()
        transport.sessionStatus = 0
        transport.sessionError = "network_error"
        let client = makeClient(transport: transport)
        var outcomes: [RavensightFlushOutcome] = []
        client.onFlush = { outcomes.append($0) }
        client.start()
        client.track("a")
        flushAndWait(client)
        drainMain()
        XCTAssertEqual(client.lastDelivery?.result, .offline)
        XCTAssertEqual(outcomes.last?.status, 0)
        XCTAssertEqual(outcomes.last?.sent, 0)
        XCTAssertEqual(outcomes.last?.pending, 1)
        XCTAssertEqual(client.stats.delivered, 0)
    }

    func testDroppedEventsAreCounted() {
        let client = makeClient(transport: FakeTransport()) { $0.maxQueueSize = 3 }
        for index in 0..<5 { client.track("e\(index)") }
        settle(client)
        XCTAssertEqual(client.stats.queued, 5)
        XCTAssertEqual(client.stats.droppedEvents, 2)
        XCTAssertEqual(client.stats.pending, 3)
        XCTAssertNil(client.lastDelivery)
    }
}
