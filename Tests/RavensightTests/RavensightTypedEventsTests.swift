import XCTest
@testable import Ravensight

/// Typed event helpers: the pure builders, the facade through a client with
/// the fake transport, and the health sampler and its single send.
final class RavensightTypedEventsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var nowMs: Int64 = 1_800_000_000_000
    private var sources: [FakeFrameSource] = []

    final class FakeFrameSource: RavensightFrameSource {
        var invalidated = false
        func invalidate() { invalidated = true }
    }

    override func setUp() {
        super.setUp()
        suiteName = "io.ravensight.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        Ravensight.resetForTesting()
    }

    override func tearDown() {
        Ravensight.resetForTesting()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: Builders

    func testPurchaseExactPropertySetAndCurrencyUpperCase() {
        let built = RavensightTypedEvents.purchase(
            amount: 499, currency: "usd", itemType: "gems", itemId: "pack_small",
            cart: "c1", transactionId: "t1", name: nil, extra: nil)
        XCTAssertEqual(built.name, "purchase")
        XCTAssertEqual(Set(built.data.keys), [
            "rs_kind", "rs_amount", "rs_currency", "rs_item_type", "rs_item_id", "rs_cart", "rs_transaction_id",
        ])
        XCTAssertEqual(built.data["rs_kind"] as? String, "purchase")
        XCTAssertEqual(built.data["rs_amount"] as? Int, 499)
        XCTAssertEqual(built.data["rs_currency"] as? String, "USD")
        XCTAssertEqual(built.data["rs_item_type"] as? String, "gems")
        XCTAssertEqual(built.data["rs_item_id"] as? String, "pack_small")
    }

    func testPurchaseOptionalKeysAbsentAndStringAmountPassesThrough() {
        let built = RavensightTypedEvents.purchase(
            amount: "1999", currency: "eur", itemType: "t", itemId: "i",
            cart: nil, transactionId: nil, name: nil, extra: nil)
        XCTAssertEqual(Set(built.data.keys), ["rs_kind", "rs_amount", "rs_currency", "rs_item_type", "rs_item_id"])
        XCTAssertEqual(built.data["rs_amount"] as? String, "1999")
        XCTAssertEqual(built.data["rs_currency"] as? String, "EUR")
    }

    func testResourceExactPropertySetAndNameByFlow() {
        let source = RavensightTypedEvents.resource(
            flow: "source", resource: "gold", amount: 12.5, itemType: nil, itemId: nil, name: nil, extra: nil)
        XCTAssertEqual(source.name, "resource_source")
        XCTAssertEqual(Set(source.data.keys), ["rs_kind", "rs_flow", "rs_resource", "rs_amount"])
        XCTAssertEqual(source.data["rs_amount"] as? Double, 12.5)
        let sink = RavensightTypedEvents.resource(
            flow: "sink", resource: "gold", amount: 3, itemType: "potion", itemId: "p1", name: nil, extra: nil)
        XCTAssertEqual(sink.name, "resource_sink")
        XCTAssertEqual(Set(sink.data.keys), [
            "rs_kind", "rs_flow", "rs_resource", "rs_amount", "rs_item_type", "rs_item_id",
        ])
        XCTAssertEqual(sink.data["rs_kind"] as? String, "resource")
    }

    func testProgressionExactPropertySetAndNameByStatus() {
        let start = RavensightTypedEvents.progression(
            status: "start", p1: "world1", p2: nil, p3: nil, score: nil, name: nil, extra: nil)
        XCTAssertEqual(start.name, "progression_start")
        XCTAssertEqual(Set(start.data.keys), ["rs_kind", "rs_status", "rs_p1"])
        let done = RavensightTypedEvents.progression(
            status: "complete", p1: "w", p2: "l", p3: "r", score: 99, name: nil, extra: nil)
        XCTAssertEqual(done.name, "progression_complete")
        XCTAssertEqual(Set(done.data.keys), ["rs_kind", "rs_status", "rs_p1", "rs_p2", "rs_p3", "rs_score"])
        XCTAssertEqual(done.data["rs_score"] as? Double, 99)
        XCTAssertEqual(RavensightTypedEvents.progression(
            status: "fail", p1: "w", p2: nil, p3: nil, score: nil, name: nil, extra: nil).name, "progression_fail")
    }

    func testErrorCutsMessageAndStack() {
        let long = String(repeating: "m", count: 500)
        let stack = String(repeating: "s", count: 5000)
        let built = RavensightTypedEvents.error(
            severity: "critical", message: long, stack: stack, name: nil, extra: nil)
        XCTAssertEqual(built.name, "error")
        XCTAssertEqual(Set(built.data.keys), ["rs_kind", "rs_severity", "rs_message", "rs_stack"])
        XCTAssertEqual((built.data["rs_message"] as? String)?.count, 200)
        XCTAssertEqual((built.data["rs_stack"] as? String)?.count, 2000)
        let short = RavensightTypedEvents.error(severity: "info", message: "ok", stack: nil, name: nil, extra: nil)
        XCTAssertEqual(short.data["rs_message"] as? String, "ok")
        XCTAssertNil(short.data["rs_stack"])
    }

    func testReservedKeysWinAndExtrasSurvive() {
        let built = RavensightTypedEvents.error(
            severity: "error", message: "boom", stack: nil, name: nil,
            extra: ["rs_kind": "none", "rs_message": "spoofed", "level": "castle"])
        XCTAssertEqual(built.data["rs_kind"] as? String, "error")
        XCTAssertEqual(built.data["rs_message"] as? String, "boom")
        XCTAssertEqual(built.data["level"] as? String, "castle")
    }

    func testNameOverride() {
        XCTAssertEqual(RavensightTypedEvents.purchase(
            amount: 1, currency: "usd", itemType: "a", itemId: "b", cart: nil, transactionId: nil,
            name: "iap", extra: nil).name, "iap")
        XCTAssertEqual(RavensightTypedEvents.resource(
            flow: "sink", resource: "r", amount: 1, itemType: nil, itemId: nil, name: "spend", extra: nil).name, "spend")
        XCTAssertEqual(RavensightTypedEvents.progression(
            status: "start", p1: "p", p2: nil, p3: nil, score: nil, name: "begin", extra: nil).name, "begin")
        XCTAssertEqual(RavensightTypedEvents.error(
            severity: "info", message: "m", stack: nil, name: "oops", extra: nil).name, "oops")
    }

    func testBadInputPassesThroughWithoutThrowing() {
        let built = RavensightTypedEvents.purchase(
            amount: "4.99", currency: "dollars", itemType: "", itemId: "", cart: nil, transactionId: nil,
            name: nil, extra: nil)
        XCTAssertEqual(built.data["rs_amount"] as? String, "4.99")
        XCTAssertEqual(built.data["rs_currency"] as? String, "DOLLARS")
        let flow = RavensightTypedEvents.resource(
            flow: "bogus", resource: "r", amount: 1, itemType: nil, itemId: nil, name: nil, extra: nil)
        XCTAssertEqual(flow.data["rs_flow"] as? String, "bogus")
        XCTAssertEqual(flow.name, "resource_source")
    }

    // MARK: Facade through a client with the fake transport

    private func startClient(
        _ transport: FakeTransport, performance: Bool = false, enabled: Bool = true
    ) -> RavensightClient {
        var configuration = RavensightConfiguration(ingestKey: "gt_live_test")
        configuration.apiUrl = "https://fake.test"
        configuration.gameVersion = "9.9.9"
        configuration.trackLifecycleEvents = false
        configuration.flushInterval = 0
        configuration.performance = performance
        configuration.enabled = enabled
        return Ravensight.start(configuration, makeClient: {
            let client = RavensightClient(
                configuration: $0, transport: transport, now: { self.nowMs },
                defaults: self.defaults, environment: [:], isBackgroundLaunch: { false },
                installsLifecycleObservers: false)
            client.makeFrameSource = { _ in
                let source = FakeFrameSource()
                self.sources.append(source)
                return source
            }
            return client
        })
    }

    private func settle(_ client: RavensightClient) {
        for _ in 0..<25 {
            let done = expectation(description: "barrier")
            client.onWorkQueue { done.fulfill() }
            wait(for: [done], timeout: 2)
        }
    }

    private func flush(_ client: RavensightClient) {
        let done = expectation(description: "flush")
        client.flush { done.fulfill() }
        wait(for: [done], timeout: 2)
        settle(client)
    }

    private func sentEvents(_ transport: FakeTransport) -> [[String: Any]] {
        return transport.requests(suffix: "/track/batch").flatMap { request -> [[String: Any]] in
            guard let body = request.body,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { return [] }
            return object["events"] as? [[String: Any]] ?? []
        }
    }

    func testFacadeSendsTypedEventsThroughTheOrdinaryTrackPath() {
        let transport = FakeTransport()
        let client = startClient(transport)
        XCTAssertTrue(Ravensight.trackPurchase(
            amount: 499, currency: "usd", itemType: "gems", itemId: "g1"))
        XCTAssertTrue(Ravensight.trackResource(flow: "sink", resource: "gold", amount: 5))
        XCTAssertTrue(Ravensight.trackProgression(status: "complete", p1: "w1", score: 10))
        XCTAssertTrue(Ravensight.trackError(severity: "warning", message: "slow"))
        flush(client)
        let events = sentEvents(transport)
        XCTAssertEqual(events.compactMap { $0["event"] as? String },
                       ["purchase", "resource_sink", "progression_complete", "error"])
        let props = events[0]["data"] as? [String: Any]
        XCTAssertEqual(props?["rs_currency"] as? String, "USD")
        XCTAssertEqual(props?["rs_amount"] as? Int, 499)
    }

    func testHelpersReturnFalseBeforeStart() {
        XCTAssertFalse(Ravensight.trackError(severity: "info", message: "m"))
        XCTAssertFalse(Ravensight.trackPurchase(amount: "1", currency: "usd", itemType: "a", itemId: "b"))
    }

    func testSessionRequestCarriesSdkName() {
        let transport = FakeTransport()
        let client = startClient(transport)
        Ravensight.track("x")
        flush(client)
        let body = transport.requests(suffix: "/session").first?.body
        let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(object?["sdk"] as? String, "ios/\(Ravensight.sdkVersion)")
        XCTAssertEqual(Ravensight.sdkVersion, "0.4.0")
    }

    // MARK: Health

    func testSamplerPercentilesFromKnownSamples() {
        let sampler = RavensightHealthSampler()
        for fps in 1...10 {
            sampler.offer(frameSeconds: 1 / Double(fps), at: Double(fps) * 2)
        }
        let summary = sampler.summary()
        XCTAssertEqual(summary?.median ?? 0, 5.5, accuracy: 1e-9)
        XCTAssertEqual(summary?.p10 ?? 0, 1, accuracy: 1e-9)
        let odd = RavensightHealthSampler()
        for (i, fps) in [60.0, 30, 59, 61, 58].enumerated() {
            odd.offer(frameSeconds: 1 / fps, at: Double(i) * 2)
        }
        XCTAssertEqual(odd.summary()?.median ?? 0, 59, accuracy: 1e-9)
        XCTAssertEqual(odd.summary()?.p10 ?? 0, 30, accuracy: 1e-9)
    }

    func testSamplerTakesAtMostOneSamplePerSecondAndKeepsAtMost600() {
        let sampler = RavensightHealthSampler()
        for i in 0..<100 { sampler.offer(frameSeconds: 1.0 / 60, at: Double(i) * 0.01) }
        XCTAssertEqual(sampler.sampleCount, 1)
        let big = RavensightHealthSampler()
        for i in 0..<700 { big.offer(frameSeconds: 1.0 / 60, at: Double(i) * 1.5) }
        XCTAssertEqual(big.sampleCount, 600)
        XCTAssertNil(RavensightHealthSampler().summary())
    }

    private func healthEvents(_ transport: FakeTransport) -> [[String: Any]] {
        return sentEvents(transport).filter { ($0["event"] as? String) == "health" }
    }

    func testHealthSentOnceOnBackgroundWithSamples() {
        let transport = FakeTransport()
        let client = startClient(transport, performance: true)
        for i in 1...10 {
            client.healthSampler.offer(frameSeconds: 1 / Double(i), at: Double(i) * 2)
        }
        client.handleDidEnterBackground()
        settle(client)
        client.handleDidEnterBackground()
        flush(client)
        let events = healthEvents(transport)
        XCTAssertEqual(events.count, 1)
        let data = events[0]["data"] as? [String: Any]
        XCTAssertEqual(data?["rs_kind"] as? String, "health")
        XCTAssertEqual(data?["rs_fps_median"] as? Double ?? 0, 5.5, accuracy: 1e-9)
        XCTAssertEqual(data?["rs_fps_p10"] as? Double ?? 0, 1, accuracy: 1e-9)
        XCTAssertNotNil(data?["rs_memory_mb"])
        XCTAssertNotNil(data?["rs_boot_ms"])
    }

    func testNoHealthWithoutSamplesOrWithoutOptIn() {
        let transport = FakeTransport()
        let client = startClient(transport, performance: true)
        client.handleDidEnterBackground()
        flush(client)
        XCTAssertTrue(healthEvents(transport).isEmpty)

        Ravensight.resetForTesting()
        let other = FakeTransport()
        let off = startClient(other, performance: false)
        off.healthSampler.offer(frameSeconds: 1 / 60, at: 10)
        off.handleDidEnterBackground()
        flush(off)
        XCTAssertTrue(healthEvents(other).isEmpty)
    }

    // MARK: Frame source lifecycle

    private func waitUntil(_ condition: @escaping () -> Bool, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("condition not met", line: line)
    }

    func testFrameSourceFollowsStopDisableAndOptOut() {
        let client = startClient(FakeTransport(), performance: true)
        waitUntil { self.sources.count == 1 }
        XCTAssertFalse(sources[0].invalidated)
        client.stopAllTelemetry()
        waitUntil { self.sources[0].invalidated }
        client.resumeTelemetry()
        waitUntil { self.sources.count == 2 }
        client.setEnabled(false)
        waitUntil { self.sources[1].invalidated }
        client.setEnabled(true)
        waitUntil { self.sources.count == 3 }
        client.setTrackingEnabled(false)
        waitUntil { self.sources[2].invalidated }
        client.setTrackingEnabled(true)
        waitUntil { self.sources.count == 4 }
        XCTAssertFalse(sources[3].invalidated)
    }

    func testNoFrameSourceWhenDisabledOrPerformanceOff() {
        _ = startClient(FakeTransport(), performance: true, enabled: false)
        let off = startClient(FakeTransport(), performance: false)
        settle(off)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(sources.isEmpty)
    }

    func testDroppingTheClientInvalidatesTheFrameSource() {
        weak var weakClient: RavensightClient?
        autoreleasepool {
            let client = startClient(FakeTransport(), performance: true)
            weakClient = client
        }
        waitUntil { self.sources.count == 1 }
        Ravensight.resetForTesting()
        waitUntil { weakClient == nil && self.sources[0].invalidated }
    }

    func testGapLongerThanASecondIsNotASample() {
        let sampler = RavensightHealthSampler()
        sampler.offer(frameSeconds: 1.0 / 60, at: 1)
        sampler.offer(frameSeconds: 600, at: 700) // returning from the background
        sampler.offer(frameSeconds: 1.5, at: 800)
        XCTAssertEqual(sampler.sampleCount, 1)
        XCTAssertEqual(sampler.summary()?.p10 ?? 0, 60, accuracy: 1e-9)
    }

    // MARK: Nothing leaves while tracking is off

    private func assertQuiet(_ client: RavensightClient, _ transport: FakeTransport, line: UInt = #line) {
        client.healthSampler.offer(frameSeconds: 1.0 / 60, at: 100)
        settle(client)
        let before = transport.requests.count
        XCTAssertFalse(Ravensight.trackPurchase(amount: 1, currency: "usd", itemType: "a", itemId: "b"), line: line)
        XCTAssertFalse(Ravensight.trackPurchase(amount: "1", currency: "usd", itemType: "a", itemId: "b"), line: line)
        XCTAssertFalse(Ravensight.trackResource(flow: "sink", resource: "r", amount: 1), line: line)
        XCTAssertFalse(Ravensight.trackProgression(status: "start", p1: "p"), line: line)
        XCTAssertFalse(Ravensight.trackError(severity: "info", message: "m"), line: line)
        client.handleDidEnterBackground()
        flush(client)
        XCTAssertEqual(transport.requests.count, before, line: line)
        XCTAssertEqual(client.queuedEventCount, 0, line: line)
        XCTAssertEqual(client.stats.pending, 0, line: line)
    }

    func testNothingQueuedOrSentWhenStopped() {
        let transport = FakeTransport()
        let client = startClient(transport, performance: true)
        client.stopAllTelemetry()
        settle(client)
        assertQuiet(client, transport)
    }

    func testNothingQueuedOrSentWhenOptedOut() {
        let transport = FakeTransport()
        let client = startClient(transport, performance: true)
        client.setTrackingEnabled(false)
        settle(client)
        assertQuiet(client, transport)
    }

    func testNothingSentAtAllWhenStartedDisabled() {
        let transport = FakeTransport()
        let client = startClient(transport, performance: true, enabled: false)
        assertQuiet(client, transport)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: New session re-arms health

    func testHealthRearmsWithFreshSamplesAfterTheSessionTimeout() {
        let transport = FakeTransport()
        let client = startClient(transport, performance: true)
        client.healthSampler.offer(frameSeconds: 1.0 / 20, at: 10)
        client.handleDidEnterBackground()
        settle(client)
        nowMs += 3_600_000 // past the 30 minute sessionTimeout
        client.handleWillEnterForeground()
        settle(client)
        client.healthSampler.offer(frameSeconds: 1.0 / 60, at: 20)
        client.handleDidEnterBackground()
        flush(client)
        let events = healthEvents(transport)
        XCTAssertEqual(events.count, 2)
        let first = events[0]["data"] as? [String: Any]
        let second = events[1]["data"] as? [String: Any]
        XCTAssertEqual(first?["rs_fps_median"] as? Double ?? 0, 20, accuracy: 1e-9)
        XCTAssertEqual(second?["rs_fps_median"] as? Double ?? 0, 60, accuracy: 1e-9)
    }
}
