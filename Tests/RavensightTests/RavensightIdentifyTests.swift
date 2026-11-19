import XCTest
@testable import Ravensight

/// identify(_:) and resetIdentity(), built to the identify contract
/// (revision 2) and checked against its binding vectors in
/// Fixtures/identify-vectors.json, never against hand typed values.
final class RavensightIdentifyTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var queueDirectory: URL!
    private let clock = FakeClock()
    private var vectors: [String: Any] = [:]

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "io.ravensight.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        queueDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ravensight-tests-\(UUID().uuidString)", isDirectory: true)
        let url = try XCTUnwrap(Bundle.module.url(forResource: "identify-vectors", withExtension: "json", subdirectory: "Fixtures"))
        vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(vectors["version"] as? Int, 2)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: queueDirectory)
        Ravensight.resetForTesting()
        super.tearDown()
    }

    // MARK: Helpers

    private var salt: String { return vectors["salt"] as? String ?? "" }

    private var sequence: [[String: Any]] { return vectors["sequence"] as? [[String: Any]] ?? [] }

    /// The accountHash a sequence step expects to see sent.
    private func sentHash(_ step: Int) -> String {
        let expect = sequence[step]["expect"] as? [String: Any]
        let sends = expect?["sends"] as? [[String: Any]]
        return sends?.first?["accountHash"] as? String ?? "missing"
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
        configuration.optional = true
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

    private func saltedTransport(prefix: String, salt: String? = nil) -> FakeTransport {
        let transport = FakeTransport()
        transport.sessionPrefix = prefix
        transport.identifySalt = salt ?? self.salt
        return transport
    }

    /// (session token, accountHash) of every identify request, in order.
    private func identifies(_ transport: FakeTransport) -> [(session: String, hash: String)] {
        return transport.requests(suffix: "/identify").map { request in
            let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return (request.headers["X-Session-Token"] ?? "", body?["accountHash"] as? String ?? "")
        }
    }

    private var stored: [String: String]? {
        return defaults.dictionary(forKey: RavensightClient.identityKey) as? [String: String]
    }

    private func storedDictionary(_ step: Int) -> [String: String]? {
        let expect = sequence[step]["expect"] as? [String: Any]
        return expect?["stored"] as? [String: String]
    }

    // MARK: Conformance 1: the hash

    func testEveryAcceptVectorHashesToItsWire() throws {
        let accept = try XCTUnwrap(vectors["accept"] as? [[String: Any]])
        XCTAssertFalse(accept.isEmpty)
        var checked = 0
        for item in accept {
            // A whole number cannot be passed to identify(_ accountId: String).
            guard let accountId = item["accountId"] as? String, item["integer"] as? Bool != true else { continue }
            let note = item["note"] as? String ?? ""
            XCTAssertNil(RavensightIdentity.refusal(accountId), note)
            let wire = RavensightIdentity.accountHash(accountId: accountId, salt: salt)
            XCTAssertEqual(wire, item["wire"] as? String, note)
            XCTAssertEqual("px_" + wire.prefix(32), item["playerId"] as? String, note)
            checked += 1
        }
        XCTAssertEqual(checked, accept.count - 1)
    }

    func testTwoSaltsGiveTwoWiresForOneAccount() throws {
        let differ = try XCTUnwrap(vectors["salts_differ"] as? [String: String])
        let id = try XCTUnwrap(differ["accountId"])
        XCTAssertEqual(RavensightIdentity.accountHash(accountId: id, salt: differ["salt_a"]!), differ["wire_a"])
        XCTAssertEqual(RavensightIdentity.accountHash(accountId: id, salt: differ["salt_b"]!), differ["wire_b"])
        XCTAssertNotEqual(differ["wire_a"], differ["wire_b"])
    }

    // MARK: Conformance 2: refusals

    func testEveryRefuseVectorIsRefusedWithNothingSentOrStoredAndTheDeviceKept() throws {
        let refuse = try XCTUnwrap(vectors["refuse"] as? [[String: Any]])
        let transport = saltedTransport(prefix: "s")
        let client = makeClient(transport: transport)
        client.start()
        client.track("a")
        flushAndWait(client)
        let device = client.deviceId
        var checked = 0
        for item in refuse {
            // null and fractions cannot be passed as a Swift String.
            guard let accountId = item["accountId"] as? String else { continue }
            let note = item["note"] as? String ?? ""
            XCTAssertEqual(RavensightIdentity.refusal(accountId), item["reason"] as? String, note)
            XCTAssertFalse(client.identify(accountId), note)
            checked += 1
        }
        settle(client)
        XCTAssertEqual(checked, refuse.filter { $0["accountId"] is String }.count)
        XCTAssertGreaterThan(checked, 0)
        XCTAssertTrue(identifies(transport).isEmpty)
        XCTAssertNil(stored)
        XCTAssertFalse(client.isIdentified)
        XCTAssertFalse(client.identityHeld)
        XCTAssertEqual(client.deviceId, device)
    }

    func testAnAccountIdIsNeverTrimmed() throws {
        let accept = try XCTUnwrap(vectors["accept"] as? [[String: Any]])
        let spaced = try XCTUnwrap(accept.first { ($0["accountId"] as? String)?.hasPrefix(" ") == true })
        let transport = saltedTransport(prefix: "s")
        let client = makeClient(transport: transport)
        client.start()
        XCTAssertTrue(client.identify(spaced["accountId"] as! String))
        flushAndWait(client)
        XCTAssertEqual(identifies(transport).map { $0.hash }, [spaced["wire"] as! String])
    }

    // MARK: Conformance 3: the sequence

    func testTheSequenceHolds() throws {
        XCTAssertEqual(sequence.count, 12)

        // 0. identify before any session opens: held in memory only.
        let first = saltedTransport(prefix: "S1")
        var client = makeClient(transport: first)
        XCTAssertTrue(client.identify("u1"))
        settle(client)
        XCTAssertTrue(client.identityHeld)
        XCTAssertNil(stored)
        XCTAssertTrue(first.requests.isEmpty)

        // 1. S1 opens with the salt: hashed, stored and sent once.
        client.start()
        settle(client)
        XCTAssertEqual(identifies(first).map { $0.session }, ["S1_1"])
        XCTAssertEqual(identifies(first).map { $0.hash }, [sentHash(1)])
        XCTAssertEqual(stored, storedDictionary(1))
        XCTAssertFalse(client.identityHeld)
        XCTAssertTrue(client.isIdentified)

        // 2. Same account again in S1: nothing.
        let device1 = client.deviceId
        XCTAssertTrue(client.identify("u1"))
        client.track("a")
        flushAndWait(client)
        XCTAssertEqual(identifies(first).count, 1)
        XCTAssertEqual(client.deviceId, device1)

        // 3. Relaunch: S2 opens with the same salt and identifies with no call.
        let second = saltedTransport(prefix: "S2")
        client = makeClient(transport: second)
        client.start()
        settle(client)
        XCTAssertEqual(identifies(second).map { $0.session }, ["S2_1"])
        XCTAssertEqual(identifies(second).map { $0.hash }, [sentHash(3)])

        // 4. An email is refused: nothing sent or changed.
        let device2 = client.deviceId
        XCTAssertFalse(client.identify("player@example.com"))
        settle(client)
        XCTAssertEqual(identifies(second).count, 1)
        XCTAssertEqual(stored, storedDictionary(4))
        XCTAssertEqual(client.deviceId, device2)

        // 5. Another account: a fresh device and session, then sent there.
        XCTAssertTrue(client.identify("u2"))
        settle(client)
        XCTAssertNotEqual(client.deviceId, device2)
        XCTAssertEqual(identifies(second).map { $0.session }, ["S2_1", "S2_2"])
        XCTAssertEqual(identifies(second).last?.hash, sentHash(5))
        XCTAssertEqual(stored, storedDictionary(5))

        // 6. resetIdentity: fresh device, nothing stored, nothing sent.
        let device3 = client.deviceId
        client.resetIdentity()
        settle(client)
        XCTAssertNotEqual(client.deviceId, device3)
        XCTAssertNil(stored)
        XCTAssertFalse(client.isIdentified)
        client.track("b")
        flushAndWait(client)
        XCTAssertEqual(second.requests(suffix: "/session").count, 3)
        XCTAssertEqual(identifies(second).count, 2)

        // 7. resetIdentity with nothing stored: nothing at all.
        let device4 = client.deviceId
        client.resetIdentity()
        settle(client)
        XCTAssertEqual(client.deviceId, device4)
        XCTAssertNil(stored)
        XCTAssertEqual(identifies(second).count, 2)

        // 8. identify u3, answered 429 needs_funds: kept, never retried in a loop.
        second.identifyStatus = 429
        second.identifyError = "quota_exceeded"
        XCTAssertTrue(client.identify("u3"))
        settle(client)
        XCTAssertEqual(identifies(second).map { $0.session }.last, "S2_3")
        XCTAssertEqual(identifies(second).last?.hash, sentHash(8))
        XCTAssertEqual(stored, storedDictionary(8))
        for _ in 0..<3 {
            client.track("c")
            flushAndWait(client)
        }
        XCTAssertEqual(identifies(second).count, 3)

        // Retried at the next session (a relaunch).
        let retry = saltedTransport(prefix: "S2b")
        client = makeClient(transport: retry)
        client.start()
        settle(client)
        XCTAssertEqual(identifies(retry).map { $0.hash }, [sentHash(8)])

        // 9. Relaunch under a different salt: the stored identity is deleted, never sent.
        let other = saltedTransport(prefix: "S5", salt: (vectors["salts_differ"] as? [String: String])?["salt_b"])
        client = makeClient(transport: other)
        client.start()
        client.track("d")
        flushAndWait(client)
        XCTAssertTrue(identifies(other).isEmpty)
        XCTAssertNil(stored)
        XCTAssertFalse(client.isIdentified)

        // 10. An answer with no salt: unavailable this launch, the held id dropped.
        let older = FakeTransport()
        older.sessionPrefix = "S6"
        client = makeClient(transport: older)
        XCTAssertTrue(client.identify("u4"))
        client.start()
        client.track("e")
        flushAndWait(client)
        XCTAssertTrue(identifies(older).isEmpty)
        XCTAssertNil(stored)
        XCTAssertFalse(client.identityHeld)
        XCTAssertFalse(client.isIdentified)

        // 11. Opt out deletes the stored identity.
        let last = saltedTransport(prefix: "S7")
        client = makeClient(transport: last)
        client.start()
        XCTAssertTrue(client.identify("u5"))
        flushAndWait(client)
        XCTAssertNotNil(stored)
        client.setTrackingEnabled(false)
        settle(client)
        XCTAssertNil(stored)
        XCTAssertFalse(client.isIdentified)
        XCTAssertEqual(identifies(last).count, 1)
    }

    func testResetDeviceIdKeepsTheIdentityAndTheNextSessionIdentifiesAgain() {
        let transport = saltedTransport(prefix: "s")
        let client = makeClient(transport: transport)
        client.start()
        client.identify("u1")
        flushAndWait(client)
        let kept = stored
        XCTAssertNotNil(kept)
        client.resetDeviceId()
        client.track("a")
        flushAndWait(client)
        XCTAssertEqual(stored, kept)
        XCTAssertEqual(identifies(transport).map { $0.session }, ["s_1", "s_2"])
    }

    func testAnswersThatEndIdentifyForTheLaunch() {
        for (status, error) in [(404, "not_found"), (400, "invalid_account_hash")] {
            let transport = saltedTransport(prefix: "s")
            transport.identifyStatus = status
            transport.identifyError = error
            let client = makeClient(transport: transport)
            client.start()
            client.identify("u1")
            flushAndWait(client)
            XCTAssertNotNil(stored, "\(status)")
            client.resetDeviceId() // a new session in the same launch
            client.track("a")
            flushAndWait(client)
            XCTAssertEqual(transport.requests(suffix: "/session").count, 2)
            XCTAssertEqual(identifies(transport).count, 1, "\(status) \(error)")
            defaults.removeObject(forKey: RavensightClient.identityKey)
        }
    }

    func testAnswersThatRetryAtTheNextSession() {
        let cases: [(Int, String)] = [(400, "no_session"), (409, "session_taken"), (409, "synthetic_session"),
                                      (429, "identify_limited"), (429, "rate_limited"), (503, "unavailable"), (0, "offline")]
        for (status, error) in cases {
            let transport = saltedTransport(prefix: "s")
            transport.identifyStatus = status
            transport.identifyError = error
            if status == 0 {
                transport.override = { $0.url.hasSuffix("/identify") ? .networkFailure("offline") : nil }
            }
            let client = makeClient(transport: transport)
            client.start()
            client.identify("u1")
            client.track("a")
            flushAndWait(client)
            client.track("b")
            flushAndWait(client)
            XCTAssertEqual(identifies(transport).count, 1, "no loop on \(error)")
            client.resetDeviceId()
            client.track("c")
            flushAndWait(client)
            XCTAssertEqual(identifies(transport).count, 2, "retried at the next session on \(error)")
            XCTAssertNotNil(stored, error)
            defaults.removeObject(forKey: RavensightClient.identityKey)
        }
    }

    func testALate200AfterResetIdentityDoesNotMarkTheNewSessionIdentified() {
        let transport = saltedTransport(prefix: "s")
        let client = makeClient(transport: transport)
        client.start()
        transport.holdSuffix = "/identify"
        client.identify("u1")
        flushAndWait(client)
        XCTAssertEqual(transport.heldCount, 1)
        client.resetIdentity()
        client.track("a")
        flushAndWait(client)
        XCTAssertEqual(transport.requests(suffix: "/session").count, 2)
        transport.release(RavensightResponse(status: 200, body: Data(#"{"playerId":"px_x","linked":true,"verified":false,"repeat":false}"#.utf8)))
        settle(client)
        XCTAssertFalse(client.isIdentified)
        XCTAssertNil(stored)
        // The new session was never identified, so a sign-in now is sent in it.
        client.identify("u2")
        settle(client)
        XCTAssertEqual(identifies(transport).map { $0.session }, ["s_1", "s_2"])
    }

    // MARK: Conformance 4: the request

    func testTheRequestCarriesTheKeyTheSessionAndOnlyTheHash() throws {
        let transport = saltedTransport(prefix: "s")
        let client = makeClient(transport: transport)
        client.start()
        client.identify("12345")
        flushAndWait(client)
        let request = try XCTUnwrap(transport.requests(suffix: "/identify").first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, "https://fake.test/api/v1/identify")
        XCTAssertEqual(request.headers["X-API-Key"], "gt_live_test")
        XCTAssertEqual(request.headers["X-Session-Token"], "s_1")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
        let accept = try XCTUnwrap(vectors["accept"] as? [[String: Any]])
        XCTAssertEqual(body.keys.sorted(), ["accountHash"])
        XCTAssertEqual(body["accountHash"] as? String, accept.first?["wire"] as? String)
        // The raw id is not in the body, the headers or what is saved.
        let raw = String(decoding: request.body ?? Data(), as: UTF8.self)
        XCTAssertFalse(raw.contains("12345\""))
        XCTAssertFalse(raw.contains(client.deviceId))
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains("\"12345\""))
    }

    func testIdentifyNeverEntersTheEventQueue() {
        let transport = saltedTransport(prefix: "s")
        let client = makeClient(transport: transport)
        client.start()
        client.track("a")
        client.identify("u1")
        flushAndWait(client)
        XCTAssertEqual(client.queuedEventCount, 0)
        XCTAssertEqual(transport.sentEvents().map { $0.name }, ["a"])
        XCTAssertEqual(client.stats.queued, 1)
    }

    // MARK: Conformance 5: nothing without a key or before consent

    func testInertWithoutAKey() {
        let transport = saltedTransport(prefix: "s")
        let client = makeClient(transport: transport, ingestKey: "")
        client.start()
        XCTAssertTrue(client.identify("u1"))
        XCTAssertFalse(client.identify("a@b"))
        settle(client)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertNil(stored)
        XCTAssertTrue(client.identityHeld)
        client.resetIdentity()
        XCTAssertFalse(client.identityHeld)
        XCTAssertNil(defaults.string(forKey: RavensightClient.deviceIdKey))
    }

    func testOptInHoldsTheIdInMemoryUntilTheYes() {
        let transport = saltedTransport(prefix: "s")
        let client = makeClient(transport: transport, ingestKey: "gt_pub_test") { $0.consent = .optIn }
        client.start()
        XCTAssertTrue(client.identify("u1"))
        client.track("a")
        settle(client)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertNil(stored)
        XCTAssertTrue(client.identityHeld)
        client.setTrackingEnabled(true)
        settle(client)
        XCTAssertEqual(identifies(transport).map { $0.hash }, [sentHash(1)])
        XCTAssertEqual(stored?["accountHash"], sentHash(1))
        XCTAssertFalse(client.identityHeld)
    }

    func testWithdrawingConsentDropsAHeldId() {
        let transport = saltedTransport(prefix: "s")
        let client = makeClient(transport: transport, ingestKey: "gt_pub_test") { $0.consent = .optIn }
        client.start()
        client.identify("u1")
        client.setTrackingEnabled(false)
        client.setTrackingEnabled(true)
        settle(client)
        XCTAssertTrue(identifies(transport).isEmpty)
        XCTAssertNil(stored)
    }

    func testASyntheticRunNeverStoresOrSends() {
        let transport = saltedTransport(prefix: "s")
        let client = makeClient(transport: transport, environment: [
            "RAVENSIGHT_PLAYTEST_TOKEN": "pt_token", "RAVENSIGHT_PLAYTEST_RUN_ID": "run_7",
        ])
        client.start()
        XCTAssertTrue(client.identify("u1"))
        client.track("a")
        flushAndWait(client)
        XCTAssertTrue(identifies(transport).isEmpty)
        XCTAssertNil(stored)
    }

    // MARK: Facade

    func testFacadeBeforeStartAndAfter() {
        XCTAssertFalse(Ravensight.identify("a@b"))
        XCTAssertFalse(Ravensight.isIdentified)
        Ravensight.resetIdentity() // a no-op, never a crash
        let transport = saltedTransport(prefix: "s")
        let client = makeClient(transport: transport)
        _ = Ravensight.start(client.configuration) { _ in client }
        XCTAssertTrue(Ravensight.identify("u1"))
        flushAndWait(client)
        XCTAssertTrue(Ravensight.isIdentified)
        Ravensight.resetIdentity()
        settle(client)
        XCTAssertFalse(Ravensight.isIdentified)
    }
}
