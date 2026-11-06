@testable import Ravensight
import XCTest

/// The delivery, ads and attribution, exposure and device field contracts:
/// the shared vectors (Fixtures/delivery-vectors.json, a copy of the server's
/// docs/sdk/delivery-vectors.json), the queue file, the response table, and
/// the client helpers.
final class RavensightWaveTests: XCTestCase {
    private let nowMs: Int64 = 1_767_225_600_000

    private func vectors() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/delivery-vectors", withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// A vector value: a string, or {repeat, count} expanded.
    private func expand(_ value: Any?) -> Any? {
        if let spec = value as? [String: Any], let unit = spec["repeat"] as? String, let count = spec["count"] as? Int {
            return String(repeating: unit, count: count)
        }
        return value
    }

    private func makeCore(maxQueueSize: Int = 500, device: [String: String] = [:]) -> RavensightCore {
        var config = RavensightCoreConfig(
            ingestKey: "gt_pub_wave", apiUrl: "https://api.example.com", gameVersion: "2.0.0",
            platform: "test", deviceId: "dev_wave", maxQueueSize: maxQueueSize
        )
        config.device = device
        var core = RavensightCore(config: config)
        core.random = { 1.0 }
        return core
    }

    private func json(_ object: [String: Any]) -> Data {
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func body(_ request: RavensightRequest) -> [String: Any] {
        guard var data = request.body else { return [:] }
        if request.headers["Content-Encoding"] == "gzip", let plain = RavensightWire.gunzip(data) { data = plain }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func events(_ request: RavensightRequest) -> [[String: Any]] {
        return body(request)["events"] as? [[String: Any]] ?? []
    }

    /// Settings check, then a session whose answer carries origin (and
    /// signing when given).
    private func open(_ core: inout RavensightCore, session: String = "ses_one", signing: [String: Any]? = nil) {
        if case .send(_, .settings) = core.nextStep(nowMs: nowMs) {
            _ = core.handle(response: RavensightResponse(status: 200, body: json(["trackingEnabled": true])), for: .settings, nowMs: nowMs)
        }
        core.markSessionWanted()
        guard case .send(_, .session) = core.nextStep(nowMs: nowMs) else { return XCTFail("expected a session") }
        var answer: [String: Any] = [
            "token": "tok_" + session, "expiresIn": 3600,
            "origin": ["session": session, "build": "2.0.0", "platform": "test", "stamp": "o1.a.b"],
        ]
        if let signing = signing { answer["signing"] = signing }
        _ = core.handle(response: RavensightResponse(status: 201, body: json(answer)), for: .session, nowMs: nowMs)
    }

    private func nextBatch(_ core: inout RavensightCore, ignoringBackoff: Bool = false) -> (RavensightRequest, Int)? {
        guard case .send(let request, .batch(let count)) = core.nextStep(nowMs: nowMs, ignoringBackoff: ignoringBackoff) else { return nil }
        return (request, count)
    }

    // MARK: Vectors

    func testSigningHeaderVectors() throws {
        let signing = try XCTUnwrap(vectors()["signing"] as? [String: Any])
        let secret = try XCTUnwrap(signing["secret"] as? String)
        let cases = try XCTUnwrap(signing["header"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 4)
        for item in cases {
            let timestamp = Int64(item["timestamp"] as! Int)
            let body = Data((item["body"] as! String).utf8)
            XCTAssertEqual(RavensightWire.signatureHeader(secret: secret, timestamp: timestamp, body: body),
                           item["header"] as? String, item["name"] as? String ?? "")
        }
    }

    func testSigningBeaconVector() throws {
        let signing = try XCTUnwrap(vectors()["signing"] as? [String: Any])
        let secret = try XCTUnwrap(signing["secret"] as? String)
        for item in try XCTUnwrap(signing["beacon"] as? [[String: Any]]) {
            let built = RavensightWire.beaconEnvelope(sessionToken: "SESSION_TOKEN", secret: secret,
                                                       timestamp: Int64(item["t"] as! Int), body: item["inner"] as! String)
            XCTAssertEqual(NSDictionary(dictionary: built), NSDictionary(dictionary: item["envelope"] as! [String: Any]))
        }
    }

    func testAnyKeyEventSizeVectors() throws {
        let block = try XCTUnwrap(vectors()["anyKeyEventSize"] as? [String: Any])
        let cases = try XCTUnwrap(block["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 6)
        for item in cases {
            var data: [String: Any] = [:]
            for (key, value) in item["data"] as! [String: Any] { data[key] = expand(value) }
            let refused = RavensightWire.countedBytes(data) > RavensightCore.maxEventBytes
            XCTAssertEqual(refused, item["expect"] is String, item["name"] as? String ?? "")
        }
    }

    func testGzipRoundTripsAndIsRealGzip() throws {
        let plain = Data(String(repeating: "x", count: 5000).utf8)
        let packed = try XCTUnwrap(RavensightWire.gzip(plain))
        XCTAssertEqual(Array(packed.prefix(2)), [0x1f, 0x8b])
        XCTAssertLessThan(packed.count, plain.count)
        XCTAssertEqual(RavensightWire.gunzip(packed), plain)
        XCTAssertEqual(RavensightWire.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    // MARK: Queue file

    func testQueueFileVersion2KeepsOriginsAndNoTokens() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rs-wave-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try XCTUnwrap(RavensightQueueStore.defaultFileURL(ingestKey: "gt_pub_test", directory: dir))
        XCTAssertEqual(url.lastPathComponent, "queue-e0347efbebb7d40b.json")
        let store = RavensightQueueStore(fileURL: url)
        let origin: [String: Any] = ["session": "ses_a", "build": "1.0", "platform": "ios", "stamp": "o1.x.y"]
        let events = [
            RavensightEvent(name: "a", data: ["rs_event_id": "a"], timestamp: nowMs - 2, origin: origin),
            RavensightEvent(name: "b", data: ["rs_event_id": "b"], timestamp: nowMs - 1),
        ]
        XCTAssertTrue(store.save(RavensightQueueStore.groups(events)))
        let text = try String(contentsOf: url)
        XCTAssertTrue(text.contains("\"version\":2"))
        XCTAssertFalse(text.contains("sessionToken"))
        let loaded = store.load(nowMs: nowMs)
        XCTAssertEqual(loaded.groups.count, 2)
        let flat = loaded.groups.flatMap { $0.events }
        XCTAssertEqual(flat.map { $0.name }, ["a", "b"])
        XCTAssertEqual(flat[0].origin?["stamp"] as? String, "o1.x.y")
        XCTAssertNil(flat[1].origin)
        XCTAssertTrue(flat.allSatisfy { $0.restored })
    }

    func testQueueFileReadsVersion1AndDropsEventsPast89Days() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rs-wave-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("queue.json")
        let nowSec = nowMs / 1000
        let v1: [String: Any] = ["version": 1, "groups": [[
            "sessionToken": "t", "expiresAtMs": 0,
            "events": [
                ["event": "old", "timestamp": nowSec - 90 * 86_400, "data": [:]],
                ["event": "kept", "timestamp": nowSec - 10, "data": [:]],
            ],
        ]]]
        try json(v1).write(to: url)
        let loaded = RavensightQueueStore(fileURL: url).load(nowMs: nowMs)
        XCTAssertEqual(loaded.dropped, 1)
        let kept = loaded.groups.flatMap { $0.events }
        XCTAssertEqual(kept.map { $0.name }, ["kept"])
        XCTAssertEqual(kept.first?.timestamp, (nowSec - 10) * 1000, "seconds read as milliseconds")
        try Data("{\"version\":3,\"groups\":[]}".utf8).write(to: url)
        XCTAssertTrue(RavensightQueueStore(fileURL: url).load(nowMs: nowMs).groups.isEmpty)
    }

    // MARK: Origins

    func testEventsTrackedBeforeTheSessionGetItsOriginAndLaterSessionsSendIt() {
        var core = makeCore()
        core.track(name: "early", data: nil, nowMs: nowMs)
        open(&core, session: "ses_one")
        XCTAssertEqual(core.pendingEvents.first?.origin?["session"] as? String, "ses_one")
        guard let (request, _) = nextBatch(&core) else { return XCTFail("expected a batch") }
        XCTAssertNil(events(request).first?["origin"], "the current session needs no origin")
        // A later session sends it with its own origin, verbatim.
        core.invalidateSession()
        open(&core, session: "ses_two")
        guard let (later, _) = nextBatch(&core) else { return XCTFail("expected a batch") }
        let origin = events(later).first?["origin"] as? [String: Any]
        XCTAssertEqual(origin?["session"] as? String, "ses_one")
        XCTAssertEqual(origin?["stamp"] as? String, "o1.a.b")
    }

    // MARK: Signing and gzip

    func testBatchesAreSignedOverTheUncompressedBodyAndGzippedFrom1KB() throws {
        var core = makeCore()
        let secret = "dGVzdC1zZWNyZXQtZm9yLWRlbGl2ZXJ5LWNvbnRyYWN0"
        open(&core, signing: ["algorithm": "HMAC-SHA256", "version": 1, "secret": secret, "serverTime": nowMs / 1000 + 1000])
        core.track(name: "small", data: nil, nowMs: nowMs)
        let (small, _) = try XCTUnwrap(nextBatch(&core))
        XCTAssertNil(small.headers["Content-Encoding"])
        let timestamp = try XCTUnwrap(small.headers["X-Ravensight-Timestamp"].flatMap { Int64($0) })
        XCTAssertEqual(timestamp, nowMs / 1000 + 1000, "the device clock corrected by serverTime")
        XCTAssertEqual(small.headers["X-Ravensight-Signature"],
                       RavensightWire.signatureHeader(secret: secret, timestamp: timestamp, body: small.body!))
        _ = core.handle(response: RavensightResponse(status: 202), for: .batch(count: 1), nowMs: nowMs)

        core.track(name: "big", data: ["blob": String(repeating: "x", count: 1500)], nowMs: nowMs)
        let (big, _) = try XCTUnwrap(nextBatch(&core))
        XCTAssertEqual(big.headers["Content-Encoding"], "gzip")
        let plain = try XCTUnwrap(RavensightWire.gunzip(big.body!))
        XCTAssertEqual(big.headers["X-Ravensight-Signature"],
                       RavensightWire.signatureHeader(secret: secret, timestamp: timestamp, body: plain))
        // A 415 sends plain from then on.
        _ = core.handle(response: RavensightResponse(status: 415), for: .batch(count: 1), nowMs: nowMs)
        let (retry, _) = try XCTUnwrap(nextBatch(&core))
        XCTAssertNil(retry.headers["Content-Encoding"])
    }

    func testALiveSessionWithoutSigningIsNotSigned() throws {
        var core = makeCore()
        open(&core)
        core.track(name: "a", data: nil, nowMs: nowMs)
        let (request, _) = try XCTUnwrap(nextBatch(&core))
        XCTAssertNil(request.headers["X-Ravensight-Signature"])
    }

    // MARK: Response table

    func testIndexedAndPlain400s() throws {
        var core = makeCore()
        open(&core)
        for name in ["a", "bad", "c"] { core.track(name: name, data: nil, nowMs: nowMs) }
        _ = try XCTUnwrap(nextBatch(&core))
        _ = core.handle(response: RavensightResponse(status: 400, body: json(["error": "invalid_event", "index": 1])),
                        for: .batch(count: 3), nowMs: nowMs)
        XCTAssertEqual(core.pendingEvents.map { $0.name }, ["a", "c"])
        _ = try XCTUnwrap(nextBatch(&core))
        _ = core.handle(response: RavensightResponse(status: 400, body: json(["error": "invalid_json"])),
                        for: .batch(count: 2), nowMs: nowMs)
        XCTAssertTrue(core.pendingEvents.isEmpty, "a 400 without an index drops the request's events")
        XCTAssertEqual(core.stats.dropped, 3)
    }

    func testRetryAfterIsNeverCutShortByAFlush() throws {
        var core = makeCore()
        open(&core)
        core.track(name: "a", data: nil, nowMs: nowMs)
        _ = try XCTUnwrap(nextBatch(&core))
        _ = core.handle(response: RavensightResponse(status: 429, retryAfter: "30"), for: .batch(count: 1), nowMs: nowMs)
        XCTAssertEqual(core.nextStep(nowMs: nowMs, ignoringBackoff: true), .wait(untilMs: nowMs + 30_000))
        // An ordinary backoff is cut by a flush.
        _ = core.nextStep(nowMs: nowMs + 30_000)
        var other = makeCore()
        open(&other)
        other.track(name: "a", data: nil, nowMs: nowMs)
        _ = try XCTUnwrap(nextBatch(&other))
        _ = other.handle(response: RavensightResponse(status: 500), for: .batch(count: 1), nowMs: nowMs)
        XCTAssertNotNil(nextBatch(&other, ignoringBackoff: true))
    }

    // MARK: Errors behind gameplay

    func testAutomaticErrorsQueueBehindGameplayAndGoFirstAtTheCap() {
        var core = makeCore(maxQueueSize: 3)
        let automatic: [String: Any] = ["rs_kind": "error", "rs_severity": "error", "rs_message": "x", "rs_source": "crash"]
        core.track(name: "err_1", data: automatic, nowMs: nowMs)
        core.track(name: "play_1", data: nil, nowMs: nowMs)
        core.track(name: "manual", data: ["rs_kind": "error", "rs_severity": "error", "rs_message": "y"], nowMs: nowMs)
        XCTAssertEqual(core.pendingEvents.map { $0.name }, ["play_1", "manual", "err_1"],
                       "gameplay (a manual error included) goes ahead of an automatic error")
        core.track(name: "play_2", data: nil, nowMs: nowMs)
        XCTAssertEqual(core.pendingEvents.map { $0.name }, ["play_1", "manual", "play_2"], "the error is evicted first")
        XCTAssertFalse(core.track(name: "err_2", data: automatic, nowMs: nowMs), "only gameplay queued: the error is dropped")
        XCTAssertEqual(core.stats.dropped, 2)
    }

    func testAGameplayEventNeverLandsInsideABatchInFlight() throws {
        var core = makeCore()
        open(&core)
        core.track(name: "err", data: ["rs_kind": "error", "rs_severity": "error", "rs_message": "x", "rs_source": "log"], nowMs: nowMs)
        let (_, count) = try XCTUnwrap(nextBatch(&core))
        core.noteInFlight(count)
        core.track(name: "play", data: nil, nowMs: nowMs)
        _ = core.handle(response: RavensightResponse(status: 202), for: .batch(count: count), nowMs: nowMs)
        XCTAssertEqual(core.pendingEvents.map { $0.name }, ["play"])
    }

    func testA413SplitsLikeBatchTooLarge() throws {
        var core = makeCore()
        open(&core)
        for index in 0..<4 { core.track(name: "e\(index)", data: nil, nowMs: nowMs) }
        _ = try XCTUnwrap(nextBatch(&core))
        _ = core.handle(response: RavensightResponse(status: 413), for: .batch(count: 4), nowMs: nowMs)
        let (_, count) = try XCTUnwrap(nextBatch(&core))
        XCTAssertEqual(count, 2)
        XCTAssertEqual(core.pendingEvents.count, 4)
    }

    // MARK: Device fields

    func testDeviceFieldsGoOnTheSession() throws {
        var core = makeCore(device: ["model": "iPhone15,2", "osVersion": "17.4.1"])
        _ = core.handle(response: RavensightResponse(status: 200, body: json(["trackingEnabled": true])), for: .settings, nowMs: nowMs)
        core.track(name: "a", data: nil, nowMs: nowMs)
        guard case .send(let request, .session) = core.nextStep(nowMs: nowMs) else { return XCTFail("expected a session") }
        let device = body(request)["device"] as? [String: String]
        XCTAssertEqual(device, ["model": "iPhone15,2", "osVersion": "17.4.1"])
        let fields = RavensightClient.deviceFields()
        XCTAssertFalse(fields["model"]?.isEmpty ?? true)
        XCTAssertFalse(fields["osVersion"]?.isEmpty ?? true)
        XCTAssertNil(fields["gpu"])
        XCTAssertEqual(RavensightClient.clean("  a\u{1}b \n"), "ab")
        XCTAssertEqual(RavensightClient.clean(String(repeating: "g", count: 300)).count, 128)
    }

    // MARK: Exposure

    func testExposureFollowsTheFirstTypedRead() {
        var core = makeCore()
        core.configExperimentDevice = "dev_wave"
        core.configExperiments = ["difficulty": "easy", "shop": "b"]
        core.track(name: "before", data: nil, nowMs: nowMs)
        XCTAssertNil(core.pendingEvents.last?.data["rs_exp_difficulty"], "a fetch alone is not an exposure")
        XCTAssertTrue(core.expose(nowMs: nowMs))
        XCTAssertFalse(core.expose(nowMs: nowMs), "one rs_exposure per run")
        let exposure = core.pendingEvents.last
        XCTAssertEqual(exposure?.name, "rs_exposure")
        XCTAssertEqual(exposure?.data["rs_exp_difficulty"] as? String, "easy")
        XCTAssertEqual(exposure?.data["rs_exp_shop"] as? String, "b")
        core.track(name: "after", data: nil, nowMs: nowMs)
        XCTAssertEqual(core.pendingEvents.last?.data["rs_exp_shop"] as? String, "b")
        core.configExperiments = ["shop": "b"] // difficulty stopped
        core.track(name: "after_stop", data: nil, nowMs: nowMs)
        XCTAssertNil(core.pendingEvents.last?.data["rs_exp_difficulty"])
        XCTAssertEqual(core.pendingEvents.last?.data["rs_exp_shop"] as? String, "b")
        XCTAssertEqual(core.pendingEvents.first?.name, "before")
        XCTAssertNil(core.pendingEvents.first?.data["rs_exp_shop"], "a queued event keeps the tags it was queued with")
        core.replaceDeviceId("dev_wave")
        core.track(name: "new_run", data: nil, nowMs: nowMs)
        XCTAssertNil(core.pendingEvents.last?.data["rs_exp_shop"], "a new run starts untagged")
    }

    // MARK: Ads

    func testMicrosAreDecimalArithmetic() {
        XCTAssertEqual(RavensightAd.microsFromDecimalString("0.0015"), "1500")
        XCTAssertEqual(RavensightAd.microsFromDecimalString("1.23456789"), "1234568")
        XCTAssertEqual(RavensightAd.microsFromDecimalString("0.9999995"), "1000000")
        XCTAssertEqual(RavensightAd.microsFromDecimalString("12"), "12000000")
        XCTAssertNil(RavensightAd.microsFromDecimalString("-1"))
        XCTAssertNil(RavensightAd.microsFromDecimalString("1e-3"))
        XCTAssertNil(RavensightAd.microsFromDecimalString("1."))
        XCTAssertEqual(RavensightAd.microsFromDouble(0.0015), "1500")
        XCTAssertEqual(RavensightAd.microsFromDouble(1.23456789), "1234568")
        XCTAssertEqual(RavensightAd.microsFromDouble(0.000001), "1")
        XCTAssertEqual(RavensightAd.microsFromDouble(2.5), "2500000")
        XCTAssertNil(RavensightAd.microsFromDouble(-1))
    }

    func testFormatMappingAndMediationAdapters() {
        XCTAssertEqual(RavensightAd.mapFormat("MREC"), "banner")
        XCTAssertEqual(RavensightAd.mapFormat("INTER"), "interstitial")
        XCTAssertEqual(RavensightAd.mapFormat("rewarded_video"), "rewarded")
        XCTAssertEqual(RavensightAd.mapFormat("Rewarded Video"), "rewarded")
        XCTAssertEqual(RavensightAd.mapFormat("REWARDED_INTER"), "rewarded")
        XCTAssertEqual(RavensightAd.mapFormat("NATIVE"), "native")
        XCTAssertEqual(RavensightAd.mapFormat("APP_OPEN"), "app_open")
        XCTAssertEqual(RavensightAd.mapFormat("CAROUSEL"), "other")
        let admob = RavensightAd.fromAdMob(valueMicros: 1500, currencyCode: "usd", adSourceName: nil, format: "rewarded", placement: "shop")
        XCTAssertEqual(admob.network, "admob")
        XCTAssertEqual(admob.revenueMicros, "1500")
        XCTAssertEqual(admob.currency, "USD")
        let max = RavensightAd.fromAppLovinMax(revenue: 0.0015, networkName: "AppLovin", format: "INTER", placement: nil)
        XCTAssertEqual(max.revenueMicros, "1500")
        XCTAssertEqual(max.currency, "USD")
        XCTAssertEqual(RavensightAd.fromIronSource(revenue: 1.23456789, adNetwork: "ironSource", adUnit: "Rewarded Video", placement: nil).revenueMicros, "1234568")
        XCTAssertEqual(RavensightAd.fromTopOn(publisherRevenue: 0.02, currency: "cny", networkName: "Pangle", adType: "BANNER", placement: "home").currency, "CNY")
    }

    func testAdEventDataHasExactlyTheSevenKeysAndRefusesBrokenRevenue() throws {
        let data = try XCTUnwrap(RavensightAd(network: "admob", format: "rewarded", result: "shown", placement: "level_end",
                                              revenueMicros: "1500", currency: "USD").eventData())
        XCTAssertEqual(Set(data.keys), ["rs_kind", "rs_ad_network", "rs_ad_format", "rs_ad_result", "rs_ad_placement", "rs_revenue_micros", "rs_currency"])
        XCTAssertEqual(data["rs_revenue_micros"] as? String, "1500")
        XCTAssertNil(RavensightAd(network: "admob", format: "rewarded", result: "shown", revenueMicros: "1500").eventData(), "no currency")
        XCTAssertNil(RavensightAd(network: "admob", format: "rewarded", result: "clicked", revenueMicros: "1500", currency: "USD").eventData())
        XCTAssertNil(RavensightAd(network: "admob", format: "rewarded", result: "shown", revenueMicros: "0.0015", currency: "USD").eventData())
        XCTAssertNil(RavensightAd(network: "admob", format: "video", result: "shown").eventData())
        let click = try XCTUnwrap(RavensightAd(network: "admob", format: "rewarded", result: "clicked").eventData())
        XCTAssertNil(click["rs_revenue_micros"])
    }

    func testAttributionIsSentOncePerInstallAcrossRestarts() {
        let suite = "rs-wave-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func client(_ transport: FakeTransport) -> RavensightClient {
            var config = RavensightConfiguration(ingestKey: "gt_live_test")
            config.apiUrl = "https://fake.test"
            config.trackLifecycleEvents = false
            config.flushInterval = 0
            config.persistQueue = false
            return RavensightClient(configuration: config, transport: transport, now: nil, defaults: defaults,
                                    environment: [:], isBackgroundLaunch: { false }, installsLifecycleObservers: false)
        }
        let attribution = RavensightAttribution(source: "store_referrer", campaign: "spring", touchTime: Date(timeIntervalSince1970: 1_767_225_600))
        let transport = FakeTransport()
        let first = client(transport)
        XCTAssertTrue(first.setAttribution(attribution))
        XCTAssertFalse(first.setAttribution(attribution))
        XCTAssertFalse(client(transport).setAttribution(attribution), "a restart does not send it again")
        XCTAssertFalse(first.setAttribution(RavensightAttribution(source: " ")))
        first.start()
        let done = expectation(description: "flushed")
        first.flush { done.fulfill() }
        wait(for: [done], timeout: 5)
        let sent = transport.sentPayloads().filter { $0["event"] as? String == "rs_attribution" }
        XCTAssertEqual(sent.count, 1)
        let data = sent.first?["data"] as? [String: Any]
        XCTAssertEqual(data?["rs_attr_source"] as? String, "store_referrer")
        XCTAssertEqual(data?["rs_campaign"] as? String, "spring")
        XCTAssertEqual((data?["rs_touch_time"] as? NSNumber)?.int64Value, 1_767_225_600_000)
        XCTAssertNil(data?["rs_adset"])
        _ = first.resetDeviceId()
        XCTAssertFalse(defaults.bool(forKey: RavensightClient.attributionKey), "a reset forgets the flag")
    }
}
