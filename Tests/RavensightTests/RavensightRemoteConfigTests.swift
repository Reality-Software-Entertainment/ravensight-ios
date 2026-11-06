import XCTest
@testable import Ravensight

final class RavensightRemoteConfigTests: XCTestCase {
    let etag = "\"" + String(repeating: "a", count: 64) + "\""
    func document(_ values: [String: Any] = ["speed": 3, "hints": false, "rules": ["bonus": 2]], experiments: [[String: String]] = [["key": "difficulty", "variant": "easy"]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["values": values, "experiments": experiments, "etag": etag])
    }
    func client(_ transport: FakeTransport, _ defaults: UserDefaults) -> RavensightClient {
        var config = RavensightConfiguration(ingestKey: "public")
        config.apiUrl = "https://fake.test"
        config.trackLifecycleEvents = false
        config.flushInterval = 0
        config.persistQueue = false
        return RavensightClient(configuration: config, transport: transport, now: nil, defaults: defaults, environment: [:], isBackgroundLaunch: { false }, installsLifecycleObservers: false)
    }
    func fetched(_ client: RavensightClient) -> RavensightConfigResult {
        let ready = expectation(description: "config")
        var result: RavensightConfigResult!
        client.fetchConfig { value in result = value; ready.fulfill() }
        wait(for: [ready], timeout: 2)
        return result
    }
    func testReservedPropertyNamesAndExperimentStringLabels() {
        for word in ["constructor", "prototype"] {
            XCTAssertNil(RavensightConfigDocument.parse(document([word: 1])))
            XCTAssertNil(RavensightConfigDocument.parse(document(["nested": [word: 1]])))
            XCTAssertNotNil(RavensightConfigDocument.parse(document([:], experiments: [["key": word, "variant": word]])))
        }
    }
    func testTypedFallbackValidationAndContainerCopies() {
        let doc = RavensightConfigDocument.parse(document())!
        XCTAssertEqual(RavensightConfigDocument.get(doc.values["speed"], fallback: 0), 3)
        XCTAssertEqual(RavensightConfigDocument.get(doc.values["speed"], fallback: 0.0), 3.0)
        XCTAssertFalse(RavensightConfigDocument.get(doc.values["hints"], fallback: true))
        XCTAssertTrue(RavensightConfigDocument.get(doc.values["speed"], fallback: true))
        XCTAssertEqual(RavensightConfigDocument.get(doc.values["hints"], fallback: 9), 9)
        XCTAssertEqual(RavensightConfigDocument.get(doc.values["speed"], fallback: "fallback"), "fallback")
        XCTAssertEqual(RavensightConfigDocument.get(NSNumber(value: 2.5), fallback: 9), 9)
        XCTAssertNil(RavensightConfigDocument.parse(document(["rules": ["__proto__": true]])))
        XCTAssertNil(RavensightConfigDocument.parse(document(experiments: [["key": "difficulty", "variant": "bad value"]])))
        var rules: [String: Any] = RavensightConfigDocument.get(doc.values["rules"], fallback: [:])
        rules["bonus"] = 99
        XCTAssertEqual((doc.values["rules"] as? [String: Int])?["bonus"], 2)
    }
    func testFetchCacheETagAndExposureOnExistingEndpoint() {
        let name = "config-tests.\(UUID())", transport = FakeTransport()
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let data = document()
        transport.override = { request in
            if request.url.contains("/ingest/config?") { return RavensightResponse(status: request.headers["If-None-Match"] == nil ? 200 : 304, body: request.headers["If-None-Match"] == nil ? data : nil) }
            return nil
        }
        let sdk = client(transport, defaults)
        XCTAssertEqual(fetched(sdk).source, "network")
        XCTAssertEqual(sdk.getConfig("speed", default: 0), 3)
        XCTAssertEqual(fetched(sdk).source, "cache")
        let request = transport.requests.first!
        XCTAssertEqual(URLComponents(string: request.url)?.path, "/api/v1/ingest/config")
        XCTAssertEqual(request.headers["X-API-Key"], "public")
        sdk.workQueue.sync {
            XCTAssertEqual(sdk.core.configExperiments, ["difficulty": "easy"])
            // The typed read above exposed the experiment: one rs_exposure.
            XCTAssertEqual(sdk.core.pendingEvents.filter { $0.name == "rs_exposure" }.count, 1)
            // A well-formed game value is kept; a malformed one is replaced.
            sdk.core.track(name: "level", data: ["rs_exp_difficulty": "forged"], nowMs: 0)
            XCTAssertEqual(sdk.core.pendingEvents.last?.data["rs_exp_difficulty"] as? String, "forged")
            sdk.core.track(name: "level", data: ["rs_exp_difficulty": "Bad Value"], nowMs: 0)
            XCTAssertEqual(sdk.core.pendingEvents.last?.data["rs_exp_difficulty"] as? String, "easy")
        }
        let offline = FakeTransport()
        let restored = client(offline, defaults)
        XCTAssertEqual(restored.getConfig("speed", default: 0), 3)
        XCTAssertEqual(fetched(restored).source, "cache")
        _ = restored.resetDeviceId()
        restored.workQueue.sync {}
        XCTAssertEqual(restored.getConfig("speed", default: 0), 0)
    }
    func testLateOptOutReplyIsDiscardedAndConcurrentFetchesShareRequest() {
        let name = "config-tests.\(UUID())", transport = FakeTransport()
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        // Exact query suffix is unknown until construction; hold every config via its build suffix.
        let sdk = client(transport, defaults)
        transport.holdSuffix = "gameVersion=1.0.0"
        // Use a custom transport override for other requests; only config is manually held.
        let query = sdk.workQueue.sync { sdk.core.config.gameVersion }
        transport.holdSuffix = "gameVersion=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)"
        let a = expectation(description: "a"), b = expectation(description: "b")
        sdk.fetchConfig { result in XCTAssertEqual(result.source, "default"); a.fulfill() }
        sdk.fetchConfig { result in XCTAssertEqual(result.source, "default"); b.fulfill() }
        sdk.workQueue.sync {}
        XCTAssertEqual(transport.heldCount, 1)
        sdk.setTrackingEnabled(false)
        sdk.workQueue.sync {}
        transport.release(RavensightResponse(status: 200, body: document()))
        wait(for: [a,b], timeout: 2)
        XCTAssertEqual(sdk.getConfig("speed", default: 0), 0)
        XCTAssertNil(defaults.data(forKey: "ravensight_config_data"))
    }
}
