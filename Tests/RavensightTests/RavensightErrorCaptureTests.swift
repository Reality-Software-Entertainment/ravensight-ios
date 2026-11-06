import XCTest
@testable import Ravensight

/// The pure pieces of error capture: the scrub (against the shared vectors),
/// the dedupe key, the device caps, the trail ring, the event shape, the
/// crash file, the exception hook's chaining and the crash diagnostic.
final class RavensightErrorTextTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Case: Decodable {
            let name: String
            let `in`: String
            let out: String
        }
        let cases: [Case]
    }

    func testEveryScrubVectorMatchesExactly() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "scrub-vectors", withExtension: "json", subdirectory: "Fixtures"))
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(vectors.cases.count, 20)
        for vector in vectors.cases {
            XCTAssertEqual(RavensightErrorText.scrub(vector.in), vector.out, vector.name)
            XCTAssertEqual(RavensightErrorText.scrub(vector.out), vector.out, "idempotent: \(vector.name)")
        }
    }

    func testALongPathWithADigitSurvivesInAStack() {
        let frame = "at Game.update (Sources/MyGame2/Gameplay/InventorySlotController.swift:88)"
        XCTAssertEqual(RavensightErrorText.scrub(frame), frame)
        let symbol = "4   MyGame   0x0000000100abc123 $s6MyGame4FooC3baryyF + 52"
        XCTAssertEqual(RavensightErrorText.scrub(symbol), symbol, "a mangled Swift name under 32 characters is kept")
        // The contract's rule, same as the server's: a mangled name of 32 or
        // more characters with a digit reads as a token and is scrubbed.
        XCTAssertEqual(
            RavensightErrorText.scrub("$s6MyGame14InventoryScreenC6reloadyyF + 52"), "$[token] + 52")
    }

    func testAHugeInputIsCutBeforeTheScrubAndScrubsFast() {
        let huge = String(repeating: "a1b2c3d4/", count: 22_223)
        XCTAssertGreaterThanOrEqual(huge.count, 200_000)
        let started = Date()
        let message = RavensightErrorText.clean(huge, RavensightErrorText.maxMessage)
        let stack = RavensightErrorText.clean(huge, RavensightErrorText.maxStack)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertLessThanOrEqual(message.count, 200)
        XCTAssertLessThanOrEqual(stack.count, 2000)
        let built = RavensightErrorText.eventData(
            RavensightCapture(source: "log", severity: "warning", message: huge, stack: huge), trail: nil)
        XCTAssertLessThanOrEqual((built.data["rs_message"] as? String)?.count ?? 0, 200)
    }

    func testSecretsInsideAnExceptionReasonAreScrubbed() {
        let reason = "upload for jane@example.com to https://cdn.example.com/a?sig=abc failed with gt_live_abcdef12"
        XCTAssertEqual(
            RavensightErrorText.scrub(reason),
            "upload for [email] to https://cdn.example.com/a failed with [token]")
    }

    func testTheDedupeKeyIgnoresNumbersAndAddresses() {
        let one = RavensightErrorText.dedupeKey(type: "T", message: "index 3 beyond bounds [0 .. 2]", stack: "0 CoreFoundation 0x00000001804a2b3c x + 4")
        let two = RavensightErrorText.dedupeKey(type: "T", message: "index 7 beyond bounds [0 .. 5]", stack: "0 CoreFoundation 0x00000001804a9999 x + 8")
        XCTAssertEqual(one, two)
        XCTAssertNotEqual(one, RavensightErrorText.dedupeKey(type: "U", message: "index 3 beyond bounds [0 .. 2]", stack: nil))
    }

    func testCapsAllowThreePerKeyAndSixAMinute() {
        var caps = RavensightErrorCaps(nowMs: 0)
        XCTAssertTrue(caps.admit(key: "a", nowMs: 0))
        XCTAssertTrue(caps.admit(key: "a", nowMs: 0))
        XCTAssertTrue(caps.admit(key: "a", nowMs: 0))
        XCTAssertFalse(caps.admit(key: "a", nowMs: 0), "three per key")
        XCTAssertTrue(caps.admit(key: "b", nowMs: 0))
        XCTAssertTrue(caps.admit(key: "c", nowMs: 0))
        XCTAssertTrue(caps.admit(key: "d", nowMs: 0))
        XCTAssertFalse(caps.admit(key: "e", nowMs: 0), "six a minute")
        XCTAssertTrue(caps.admit(key: "e", nowMs: 10_000), "the bucket refills, one every ten seconds")
        XCTAssertFalse(caps.admit(key: "f", nowMs: 10_000))
    }

    func testCapsStopAtThirtyASessionAndTenTrails() {
        var caps = RavensightErrorCaps(nowMs: 0)
        var admitted = 0
        for index in 0..<100 where caps.admit(key: "k\(index)", nowMs: Int64(index) * 60_000) {
            admitted += 1
        }
        XCTAssertEqual(admitted, 30)
        var trails = 0
        for _ in 0..<20 where caps.takeTrail() { trails += 1 }
        XCTAssertEqual(trails, 10)
    }

    func testTheTrailKeepsTheLastTwentyLinesInOrderScrubbedAndCut() {
        var trail = RavensightTrail()
        for index in 0..<25 { trail.add(level: "track", text: "event_\(index)", elapsedMs: Int64(index)) }
        XCTAssertEqual(trail.lines.count, 20)
        XCTAssertEqual(trail.lines.first, "+5 track event_5")
        XCTAssertEqual(trail.lines.last, "+24 track event_24")
        trail.add(level: "info", text: "mail jane@example.com\n" + String(repeating: "x", count: 300), elapsedMs: 30)
        XCTAssertTrue(trail.lines.last!.hasPrefix("+30 info mail [email] x"))
        XCTAssertEqual(trail.lines.last!.count, 120)
        XCTAssertLessThanOrEqual(trail.text.count, 1500)
        XCTAssertTrue(trail.text.hasSuffix(trail.lines.last!), "newest last")
        XCTAssertFalse(trail.text.contains("+5 track event_5\n"), "oldest dropped to fit 1,500")
    }

    func testTheEventShapeIsTopLevelScrubbedAndCut() {
        let capture = RavensightCapture(
            source: "crash", severity: "critical",
            message: "boom at /Users/jacob/x " + String(repeating: "m", count: 300),
            stack: String(repeating: "s", count: 3000), type: "NSRangeException")
        let built = RavensightErrorText.eventData(capture, trail: "+1 track a")
        XCTAssertEqual(built.data["rs_kind"] as? String, "error")
        XCTAssertEqual(built.data["rs_severity"] as? String, "critical")
        XCTAssertEqual(built.data["rs_source"] as? String, "crash")
        XCTAssertEqual(built.data["rs_error_type"] as? String, "NSRangeException")
        XCTAssertEqual((built.data["rs_message"] as? String)?.count, 200)
        XCTAssertTrue((built.data["rs_message"] as? String)?.hasPrefix("boom at ~/x m") == true)
        XCTAssertEqual((built.data["rs_stack"] as? String)?.count, 2000)
        XCTAssertEqual(built.data["rs_trail"] as? String, "+1 track a")
        XCTAssertNil(built.data["rs_fp"], "the server writes the fingerprint")
        let empty = RavensightErrorText.eventData(RavensightCapture(source: "log", severity: "warning", message: ""), trail: nil)
        XCTAssertEqual(empty.data["rs_message"] as? String, "(no message)")
        XCTAssertNil(empty.data["rs_stack"])
        XCTAssertNil(empty.data["rs_trail"])
    }

    func testTheCrashFileRoundTripsAndHoldsAtMostFive() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try XCTUnwrap(RavensightCrashFile.defaultURL(ingestKey: "gt_live_x", directory: dir))
        XCTAssertTrue(url.lastPathComponent.hasPrefix("crash-"))
        for index in 0..<7 {
            RavensightCrashFile.append(
                RavensightCapture(source: "crash", severity: "critical", message: "m\(index)", stack: "s", type: "T", atSec: 100), to: url)
        }
        let loaded = RavensightCrashFile.load(url)
        XCTAssertEqual(loaded.count, 5)
        XCTAssertEqual(loaded.first, RavensightCapture(source: "crash", severity: "critical", message: "m0", stack: "s", type: "T", atSec: 100))
        RavensightCrashFile.delete(url)
        XCTAssertTrue(RavensightCrashFile.load(url).isEmpty)
    }

    func testAnExceptionBecomesAScrubbedCriticalCrash() {
        let exception = NSException(
            name: .invalidArgumentException,
            reason: "bad value for jane@example.com",
            userInfo: nil)
        let capture = RavensightExceptionHook.capture(for: exception, atSec: 42)
        XCTAssertEqual(capture.source, "crash")
        XCTAssertEqual(capture.severity, "critical")
        XCTAssertEqual(capture.type, "NSInvalidArgumentException")
        XCTAssertEqual(capture.message, "bad value for [email]")
        XCTAssertEqual(capture.atSec, 42)
    }

    func testTheExceptionHookChainsToThePreviousHandlerAndRestoresIt() throws {
        let original = NSGetUncaughtExceptionHandler()
        defer { NSSetUncaughtExceptionHandler(original) }
        defer { RavensightExceptionHook.resetForTesting() }
        RavensightExceptionHook.resetForTesting()
        previousHandlerCalls = 0
        NSSetUncaughtExceptionHandler(countingHandler)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try XCTUnwrap(RavensightCrashFile.defaultURL(ingestKey: "gt_live_hook", directory: dir))
        RavensightExceptionHook.activate(fileURL: url)
        RavensightExceptionHook.activate(fileURL: url) // a second install does not double wrap
        let installed = try XCTUnwrap(NSGetUncaughtExceptionHandler())

        installed(NSException(name: .rangeException, reason: "index 3 beyond bounds", userInfo: nil))
        XCTAssertEqual(previousHandlerCalls, 1, "the earlier handler is always called, once")
        let saved = RavensightCrashFile.load(url)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.type, "NSRangeException")
        XCTAssertEqual(saved.first?.message, "index 3 beyond bounds")

        RavensightExceptionHook.deactivate(fileURL: url)
        XCTAssertFalse(RavensightExceptionHook.isActive)
        let restored = try XCTUnwrap(NSGetUncaughtExceptionHandler())
        XCTAssertEqual(
            unsafeBitCast(restored, to: UnsafeRawPointer.self),
            unsafeBitCast(countingHandler as RavensightExceptionHook.ExceptionHandler, to: UnsafeRawPointer.self))
    }

    func testAnInertHookWritesNothingButStillChains() throws {
        let original = NSGetUncaughtExceptionHandler()
        defer { NSSetUncaughtExceptionHandler(original) }
        defer { RavensightExceptionHook.resetForTesting() }
        RavensightExceptionHook.resetForTesting()
        previousHandlerCalls = 0
        NSSetUncaughtExceptionHandler(countingHandler)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try XCTUnwrap(RavensightCrashFile.defaultURL(ingestKey: "gt_live_inert", directory: dir))
        RavensightExceptionHook.activate(fileURL: url)
        let ours = try XCTUnwrap(NSGetUncaughtExceptionHandler())
        // Someone installed a handler after ours: ours stays, made inert.
        NSSetUncaughtExceptionHandler(laterHandler)
        RavensightExceptionHook.deactivate(fileURL: url)
        ours(NSException(name: .genericException, reason: "x", userInfo: nil))
        XCTAssertTrue(RavensightCrashFile.load(url).isEmpty)
        XCTAssertEqual(previousHandlerCalls, 1)
        NSSetUncaughtExceptionHandler(original)
    }

    func testASwiftTrapDiagnosticBecomesAShortCriticalCrash() throws {
        let tree: [String: Any] = [
            "callStackPerThread": true,
            "callStacks": [
                ["threadAttributed": false, "callStackRootFrames": [["binaryName": "Other", "offsetIntoBinaryTextSegment": 1]]],
                ["threadAttributed": true, "callStackRootFrames": [[
                    "binaryName": "MyGame", "offsetIntoBinaryTextSegment": 1234,
                    "subFrames": [["binaryName": "SwiftUI", "offsetIntoBinaryTextSegment": 99]],
                ]]],
            ],
        ]
        let frames = RavensightCrashDiagnostic.frames(fromCallStackTree: try JSONSerialization.data(withJSONObject: tree))
        XCTAssertEqual(frames, ["MyGame +1234", "SwiftUI +99"])
        let diagnostic = RavensightCrashDiagnostic(
            signal: 5, exceptionType: 6, exceptionCode: 1,
            terminationReason: nil, frames: frames, beginSec: 100, endSec: 200)
        let capture = diagnostic.capture
        XCTAssertEqual(capture.source, "crash")
        XCTAssertEqual(capture.severity, "critical")
        XCTAssertEqual(capture.type, "SIGTRAP")
        XCTAssertEqual(capture.message, "Crashed with SIGTRAP (EXC_BREAKPOINT)")
        XCTAssertEqual(capture.stack, "MyGame +1234\nSwiftUI +99")
        XCTAssertEqual(capture.atSec, 200)
    }

    func testAnObjectiveCReasonNamesTheCrash() {
        var diagnostic = RavensightCrashDiagnostic(
            signal: 6, exceptionType: 10, exceptionCode: 0, terminationReason: "Namespace SIGNAL, Code 6",
            frames: [], beginSec: 1, endSec: 2)
        diagnostic.objcExceptionName = "NSRangeException"
        diagnostic.objcMessage = "index 9 beyond bounds"
        XCTAssertEqual(diagnostic.capture.type, "NSRangeException")
        XCTAssertEqual(diagnostic.capture.message, "index 9 beyond bounds Namespace SIGNAL, Code 6")
        XCTAssertNil(diagnostic.capture.stack)
    }

    func testTheFrameWalkStopsAtTwelve() throws {
        var frame: [String: Any] = ["binaryName": "Deep", "offsetIntoBinaryTextSegment": 0]
        for index in 1..<40 { frame = ["binaryName": "F\(index)", "offsetIntoBinaryTextSegment": index, "subFrames": [frame]] }
        let tree: [String: Any] = ["callStacks": [["threadAttributed": true, "callStackRootFrames": [frame]]]]
        let frames = RavensightCrashDiagnostic.frames(fromCallStackTree: try JSONSerialization.data(withJSONObject: tree))
        XCTAssertEqual(frames.count, 12)
    }
}

#if compiler(>=5.10)
nonisolated(unsafe) private var previousHandlerCalls = 0
#else
private var previousHandlerCalls = 0
#endif

private func countingHandler(_ exception: NSException) {
    previousHandlerCalls += 1
}

private func laterHandler(_ exception: NSException) {}
