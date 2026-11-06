import XCTest
@testable import Ravensight

/// Error capture through the client driver: the gate, the boot hold, the
/// game's switches, the trail, the log call, the crash file from the last
/// launch and crash diagnostics sent once each. A fake transport and a
/// temporary directory; no process-wide handler and no MetricKit (those are
/// off for every client a test builds).
final class RavensightErrorClientTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var directory: URL!
    private let clock = FakeClock()

    override func setUp() {
        super.setUp()
        suiteName = "io.ravensight.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// A transport whose settings answer carries these error switches.
    private func transport(errorCapture: [String: Any]? = nil) -> FakeTransport {
        let transport = FakeTransport()
        transport.override = { request in
            guard request.url.hasSuffix("/settings") else { return nil }
            var body: [String: Any] = ["trackingEnabled": true]
            if let errorCapture = errorCapture { body["errorCapture"] = errorCapture }
            return RavensightResponse(status: 200, body: try? JSONSerialization.data(withJSONObject: body))
        }
        return transport
    }

    private func makeClient(
        _ transport: FakeTransport,
        ingestKey: String = "gt_live_test",
        configure: (inout RavensightConfiguration) -> Void = { _ in }
    ) -> RavensightClient {
        var configuration = RavensightConfiguration(ingestKey: ingestKey)
        configuration.apiUrl = "https://fake.test"
        configuration.trackLifecycleEvents = false
        configuration.flushInterval = 0
        configure(&configuration)
        let clock = self.clock
        return RavensightClient(
            configuration: configuration,
            transport: transport,
            now: { clock.nowMs },
            defaults: defaults,
            environment: [:],
            isBackgroundLaunch: { false },
            installsLifecycleObservers: false,
            queueDirectory: directory,
            random: { 0.5 }
        )
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

    /// Runs a capture on the work queue, as a crash source would.
    private func capture(_ client: RavensightClient, _ capture: RavensightCapture) {
        client.onWorkQueue {
            client.capture(capture)
            client.stateChanged()
        }
    }

    private func crash(_ message: String, at atSec: Int64? = nil) -> RavensightCapture {
        return RavensightCapture(source: "crash", severity: "critical", message: message, stack: nil, type: "SIGSEGV", atSec: atSec)
    }

    /// The data of every event sent in a batch, in order.
    private func sentData(_ transport: FakeTransport) -> [(name: String, timestamp: Int64, data: [String: Any])] {
        return transport.requests(suffix: "/track/batch").flatMap { request -> [(name: String, timestamp: Int64, data: [String: Any])] in
            guard let body = request.body,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let events = object["events"] as? [[String: Any]] else { return [] }
            return events.map {
                (
                    name: $0["event"] as? String ?? "",
                    timestamp: ($0["timestamp"] as? NSNumber)?.int64Value ?? 0,
                    data: $0["data"] as? [String: Any] ?? [:]
                )
            }
        }
    }

    private func errors(_ transport: FakeTransport) -> [[String: Any]] {
        return sentData(transport).filter { $0.data["rs_kind"] as? String == "error" }.map { $0.data }
    }

    // MARK: Gate

    func testCaptureIsOnByDefaultOnceStarted() {
        let transport = transport()
        let client = makeClient(transport)
        XCTAssertFalse(client.isCapturingErrors, "nothing is installed before start()")
        client.start()
        settle(client)
        XCTAssertTrue(client.isCapturingErrors)
    }

    func testNothingIsInstalledWithoutAKey() {
        let transport = transport()
        let client = makeClient(transport, ingestKey: "  ") { $0.optional = true }
        client.start()
        client.log("boom", level: .error)
        XCTAssertFalse(client.isCapturingErrors)
        XCTAssertTrue(transport.requests.isEmpty, "no request without a key")
    }

    func testNothingIsInstalledBeforeConsent() {
        let transport = transport()
        let client = makeClient(transport) { $0.consent = .optIn }
        client.start()
        settle(client)
        XCTAssertFalse(client.isCapturingErrors)
        XCTAssertTrue(transport.requests.isEmpty)
        client.setTrackingEnabled(true)
        settle(client)
        XCTAssertTrue(client.isCapturingErrors, "the player's yes installs it")
    }

    func testTheOptOutOptionInstallsNothing() {
        let transport = transport()
        let client = makeClient(transport) { $0.captureErrors = false }
        client.start()
        settle(client)
        capture(client, crash("boom"))
        flush(client)
        XCTAssertFalse(client.isCapturingErrors)
        XCTAssertTrue(errors(transport).isEmpty)
    }

    func testOptingOutRemovesItAndAStopMakesItInert() {
        let transport = transport()
        let client = makeClient(transport)
        client.start()
        settle(client)
        client.setTrackingEnabled(false)
        settle(client)
        XCTAssertFalse(client.isCapturingErrors)
        client.setTrackingEnabled(true)
        settle(client)
        XCTAssertTrue(client.isCapturingErrors)
        client.stopAllTelemetry()
        settle(client)
        XCTAssertFalse(client.isCapturingErrors)
    }

    func testTheGamesSwitchOffRemovesItAndSendsNothing() {
        let transport = transport(errorCapture: ["enabled": false, "trail": false])
        let client = makeClient(transport)
        client.start()
        flush(client)
        capture(client, crash("boom"))
        client.log("bad", level: .error)
        flush(client)
        XCTAssertFalse(client.isCapturingErrors)
        XCTAssertTrue(errors(transport).isEmpty)
    }

    // MARK: Boot hold

    func testBootErrorsAreHeldThenSentOnceTheAnswerSaysOn() {
        let transport = transport()
        transport.holdSuffix = "/settings"
        let client = makeClient(transport)
        client.start()
        settle(client)
        XCTAssertTrue(client.isCapturingErrors, "installed before the answer, with a key and consent")
        for letter in ["A", "B", "C", "D", "E", "F", "G"] { capture(client, crash("boot " + letter)) }
        settle(client)
        XCTAssertTrue(transport.requests(suffix: "/track/batch").isEmpty)
        transport.release(RavensightResponse(
            status: 200, body: try? JSONSerialization.data(withJSONObject: ["trackingEnabled": true])))
        settle(client)
        flush(client)
        let sent = errors(transport).compactMap { $0["rs_message"] as? String }
        XCTAssertEqual(sent.count, 5, "at most five are held")
        XCTAssertEqual(sent, ["boot A", "boot B", "boot C", "boot D", "boot E"])
    }

    func testBootErrorsAreDiscardedWhenTheAnswerSaysOff() {
        let transport = transport(errorCapture: ["enabled": false])
        transport.holdSuffix = "/settings"
        let client = makeClient(transport)
        client.start()
        settle(client)
        capture(client, crash("boot"))
        settle(client)
        transport.release(RavensightResponse(status: 200, body: try? JSONSerialization.data(withJSONObject: [
            "trackingEnabled": true, "errorCapture": ["enabled": false],
        ])))
        settle(client)
        flush(client)
        XCTAssertTrue(errors(transport).isEmpty)
        XCTAssertFalse(client.isCapturingErrors)
    }

    // MARK: Event, caps, trail, log

    func testACaptureIsOneOrdinaryErrorEventWithTheCrashTime() {
        let transport = transport()
        let client = makeClient(transport)
        client.start()
        flush(client)
        capture(client, crash("bad access at 0x0000000000000010", at: 1_700_000_000))
        flush(client)
        let sent = sentData(transport).filter { $0.name == "error" }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.timestamp, 1_700_000_000_000, "the crash time, in milliseconds")
        let data = sent.first?.data ?? [:]
        XCTAssertEqual(data["rs_source"] as? String, "crash")
        XCTAssertEqual(data["rs_severity"] as? String, "critical")
        XCTAssertEqual(data["rs_error_type"] as? String, "SIGSEGV")
        XCTAssertNotNil(data["rs_event_id"])
        XCTAssertNil(data["rs_trail"], "the trail is off by default")
        XCTAssertNil(data["rs_fp"])
    }

    func testAStormStaysInsideTheDeviceCaps() {
        let transport = transport()
        let client = makeClient(transport)
        client.start()
        flush(client)
        for _ in 0..<50 { capture(client, crash("same crash")) }
        for index in 0..<50 { capture(client, crash("crash kind \(String(UnicodeScalar(65 + index % 26)!))")) }
        flush(client)
        XCTAssertEqual(errors(transport).count, 6, "three of the same, then the bucket of six a minute")
        XCTAssertEqual(client.errorsCaptured, 6)
        XCTAssertEqual(client.errorsCapped, 94)
    }

    func testOnceTheCapsAreSpentACaptureIsNeverScrubbed() {
        let transport = transport()
        let client = makeClient(transport)
        client.start()
        flush(client)
        for index in 0..<6 { capture(client, crash("burst \(String(UnicodeScalar(65 + index)!))")) }
        settle(client)
        var before = 0
        client.onWorkQueue { before = RavensightErrorText.scrubCalls }
        settle(client)
        for index in 0..<20 { capture(client, crash("late \(String(UnicodeScalar(65 + index)!))")) }
        settle(client)
        var after = 0
        client.onWorkQueue { after = RavensightErrorText.scrubCalls }
        settle(client)
        XCTAssertEqual(client.errorsCaptured, 6)
        XCTAssertEqual(after, before, "with the bucket empty nothing is scrubbed")
    }

    func testManyLogLinesBeforeTheAnswerNeverPushOutACrash() {
        let transport = transport()
        transport.holdSuffix = "/settings"
        let client = makeClient(transport)
        client.start()
        settle(client)
        for index in 0..<20 { client.log("noise \(String(UnicodeScalar(65 + index)!))", level: .error) }
        settle(client)
        capture(client, crash("the real one"))
        settle(client)
        transport.release(RavensightResponse(
            status: 200, body: try? JSONSerialization.data(withJSONObject: ["trackingEnabled": true])))
        settle(client)
        flush(client)
        let sent = errors(transport)
        XCTAssertTrue(sent.contains { $0["rs_message"] as? String == "the real one" && $0["rs_source"] as? String == "crash" })
    }

    func testManyTrailLinesNeverPushOutACrash() {
        let transport = transport(errorCapture: ["enabled": true, "trail": true])
        let client = makeClient(transport)
        client.start()
        flush(client)
        for index in 0..<2_000 { client.log("frame \(index)", level: .info) }
        settle(client)
        capture(client, crash("the real one"))
        flush(client)
        let sent = errors(transport)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["rs_message"] as? String, "the real one")
        XCTAssertEqual((sent.first?["rs_trail"] as? String)?.split(separator: "\n").count, 20)
    }

    func testTheTrailCarriesTrackCallsAndLogLinesWhenTheSwitchIsOn() {
        let transport = transport(errorCapture: ["enabled": true, "trail": true])
        let client = makeClient(transport)
        client.start()
        flush(client)
        client.track("level_started")
        settle(client)
        clock.advance(seconds: 2)
        client.log("loading boss from /Users/jacob/game", level: .info)
        settle(client)
        capture(client, crash("boom"))
        flush(client)
        let trail = errors(transport).first?["rs_trail"] as? String
        XCTAssertEqual(trail, "+0 track level_started\n+2000 info loading boss from ~/game")
    }

    func testTheLogCallCapturesAnErrorLineAsAWarning() {
        let transport = transport()
        let client = makeClient(transport)
        client.start()
        flush(client)
        client.log("save failed for jane@example.com", level: .error)
        client.log("just info", level: .info)
        settle(client)
        flush(client)
        let sent = errors(transport)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["rs_source"] as? String, "log")
        XCTAssertEqual(sent.first?["rs_severity"] as? String, "warning")
        XCTAssertEqual(sent.first?["rs_message"] as? String, "save failed for [email]")
    }

    func testManualTrackErrorIsUnchangedAndPassesWhenTheSwitchIsOff() {
        let transport = transport(errorCapture: ["enabled": false])
        let client = makeClient(transport)
        client.start()
        flush(client)
        let built = RavensightTypedEvents.error(
            severity: "error", message: "mail jane@example.com", stack: nil, name: nil, extra: nil)
        client.track(built.name, data: built.data)
        flush(client)
        let sent = errors(transport)
        XCTAssertEqual(sent.count, 1)
        XCTAssertNil(sent.first?["rs_source"])
        XCTAssertEqual(sent.first?["rs_message"] as? String, "mail jane@example.com", "the server scrubs manual text")
    }

    func testTheSDKsOwnFailingRequestIsNotCaptured() {
        let transport = transport()
        transport.batchStatus = 500
        let client = makeClient(transport)
        client.start()
        client.track("a")
        flush(client)
        transport.batchStatus = 202
        flush(client)
        XCTAssertTrue(errors(transport).isEmpty)
    }

    // MARK: Crash sources

    func testAnExceptionSavedByTheLastLaunchIsSentOnThisOne() throws {
        let url = try XCTUnwrap(RavensightCrashFile.defaultURL(ingestKey: "gt_live_test", directory: directory))
        RavensightCrashFile.append(RavensightCapture(
            source: "crash", severity: "critical", message: "index 3 beyond bounds",
            stack: "0 CoreFoundation", type: "NSRangeException", atSec: 1_799_990_100), to: url)
        let transport = transport()
        let client = makeClient(transport)
        client.start()
        flush(client)
        flush(client)
        let sent = sentData(transport).filter { $0.name == "error" }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.timestamp, 1_799_990_100_000, "the crash time, in milliseconds")
        XCTAssertEqual(sent.first?.data["rs_error_type"] as? String, "NSRangeException")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "read once, then deleted")
    }

    func testASavedExceptionOlderThanThirtyDaysIsDeletedUnsent() throws {
        let url = try XCTUnwrap(RavensightCrashFile.defaultURL(ingestKey: "gt_live_test", directory: directory))
        let nowSec = clock.nowMs / 1000
        RavensightCrashFile.append(crash("stale", at: nowSec - 31 * 86_400), to: url)
        RavensightCrashFile.append(crash("fresh", at: nowSec - 29 * 86_400), to: url)
        let transport = transport()
        let client = makeClient(transport)
        client.start()
        flush(client)
        flush(client)
        XCTAssertEqual(errors(transport).compactMap { $0["rs_message"] as? String }, ["fresh"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAResetDeletesASavedExceptionAndTheHeldCrashes() throws {
        let url = try XCTUnwrap(RavensightCrashFile.defaultURL(ingestKey: "gt_live_test", directory: directory))
        let transport = transport()
        transport.holdSuffix = "/settings"
        let client = makeClient(transport)
        client.start()
        settle(client)
        capture(client, crash("held"))
        settle(client)
        RavensightCrashFile.append(crash("saved"), to: url)
        client.resetDeviceId()
        settle(client)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the saved record is deleted")
        transport.release(RavensightResponse(
            status: 200, body: try? JSONSerialization.data(withJSONObject: ["trackingEnabled": true])))
        settle(client)
        flush(client)
        XCTAssertTrue(errors(transport).isEmpty, "nothing held under the old id is sent")
    }

    func testASavedExceptionIsDeletedUnsentWhenCaptureIsOff() throws {
        let url = try XCTUnwrap(RavensightCrashFile.defaultURL(ingestKey: "gt_live_test", directory: directory))
        RavensightCrashFile.append(crash("old"), to: url)
        let transport = transport()
        let client = makeClient(transport) { $0.captureErrors = false }
        client.start()
        flush(client)
        XCTAssertTrue(errors(transport).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testEachCrashDiagnosticIsSentOnce() {
        let transport = transport()
        let client = makeClient(transport)
        client.start()
        flush(client)
        let trap = RavensightCrashDiagnostic(
            signal: 5, exceptionType: 6, exceptionCode: 1, terminationReason: nil,
            frames: ["MyGame +1234"], beginSec: 100, endSec: 200)
        client.onWorkQueue { client.receiveCrashDiagnostics([trap, trap]) }
        client.onWorkQueue { client.receiveCrashDiagnostics([trap]) }
        flush(client)
        let sent = errors(transport)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["rs_message"] as? String, "Crashed with SIGTRAP (EXC_BREAKPOINT)")
        XCTAssertEqual(sent.first?["rs_stack"] as? String, "MyGame +1234")
        XCTAssertEqual(sent.first?["rs_source"] as? String, "crash")
    }

    func testTheSystemsReportOfASavedExceptionIsNotSentTwice() throws {
        let url = try XCTUnwrap(RavensightCrashFile.defaultURL(ingestKey: "gt_live_test", directory: directory))
        RavensightCrashFile.append(RavensightCapture(
            source: "crash", severity: "critical", message: "boom", stack: nil, type: "NSGenericException", atSec: 1_799_999_150), to: url)
        let transport = transport()
        let client = makeClient(transport)
        client.start()
        flush(client)
        let abort = RavensightCrashDiagnostic(
            signal: 6, exceptionType: 10, exceptionCode: 0, terminationReason: nil, frames: [], beginSec: 1_799_999_140, endSec: 1_799_999_160)
        client.onWorkQueue { client.receiveCrashDiagnostics([abort]) }
        flush(client)
        XCTAssertEqual(errors(transport).compactMap { $0["rs_error_type"] as? String }, ["NSGenericException"])
    }
}
