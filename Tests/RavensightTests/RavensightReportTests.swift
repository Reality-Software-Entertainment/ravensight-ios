import XCTest
import CryptoKit
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif
#if canImport(UIKit)
import UIKit
#endif
@testable import Ravensight

/// Player Reports over a stub transport: the request shapes the server's
/// report routes expect, the screenshot upload, and every refusal.
final class RavensightReportTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    /// A 1 by 1 PNG.
    private let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

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
        environment: [String: String] = [:]
    ) -> RavensightClient {
        var configuration = RavensightConfiguration(ingestKey: "gt_live_test")
        configuration.apiUrl = "https://fake.test"
        configuration.trackLifecycleEvents = false
        configuration.flushInterval = 0
        let client = RavensightClient(
            configuration: configuration,
            transport: transport,
            now: nil,
            defaults: defaults,
            environment: environment,
            isBackgroundLaunch: { false },
            installsLifecycleObservers: false
        )
        client.reportPollInterval = 0.01
        client.reportSessionWait = 2
        return client
    }

    private func json(_ object: [String: Any]) -> Data {
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func body(_ request: RavensightRequest?) -> [String: Any] {
        guard let data = request?.body else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func submit(_ client: RavensightClient, _ report: RavensightReport) -> Result<RavensightReportReceipt, RavensightError> {
        var outcome: Result<RavensightReportReceipt, RavensightError>?
        let done = expectation(description: "report")
        client.submitReport(report) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return outcome ?? .failure(RavensightError(code: "none", status: 0, message: ""))
    }

    private func code(_ result: Result<RavensightReportReceipt, RavensightError>) -> String? {
        if case .failure(let error) = result { return error.code }
        return nil
    }

    private func reportRequests(_ transport: FakeTransport) -> [RavensightRequest] {
        return transport.requests.filter { $0.url.contains("/reports") || $0.url.hasPrefix("https://storage.test") }
    }

    /// Routes the report endpoints like the server: a text report completes
    /// on creation; a screenshot report goes pending, upload, finalize,
    /// processing, then complete on the first status check.
    private func serveReports(_ transport: FakeTransport, storageStatus: Int = 204) {
        transport.override = { [unowned self] request in
            let url = request.url
            if url == "https://fake.test/api/v1/reports" {
                let image = self.body(request)["image"] as? Bool ?? false
                return RavensightResponse(status: 201, body: self.json(image
                    ? ["id": "sub_1", "status": "pending", "reportId": NSNull(), "usageEvents": 20_001]
                    : ["id": "sub_1", "status": "complete", "reportId": "rep_1", "usageEvents": 1]))
            }
            if url.hasSuffix("/reports/sub_1/upload") {
                return RavensightResponse(status: 200, body: self.json([
                    "url": "https://storage.test/bucket",
                    "fields": ["key": "player-reports/staging/sub_1", "Content-Type": "application/octet-stream", "Policy": "p0"],
                ]))
            }
            if url.hasPrefix("https://storage.test") {
                return RavensightResponse(status: storageStatus)
            }
            if url.hasSuffix("/reports/sub_1/finalize") {
                return RavensightResponse(status: 202, body: self.json(["id": "sub_1", "status": "processing"]))
            }
            if url.hasSuffix("/reports/sub_1") && request.method == "GET" {
                return RavensightResponse(status: 200, body: self.json(["id": "sub_1", "status": "complete", "reportId": "rep_2", "usageEvents": 20_001]))
            }
            return nil
        }
    }

    // MARK: Shapes

    func testTextReportSendsTheContractShape() {
        let transport = FakeTransport()
        serveReports(transport)
        let client = makeClient(transport: transport)
        client.start()
        let report = RavensightReport(
            category: "bug", message: "The door will not open",
            metadata: ["zone": "castle", "deaths": 3, "hard_mode": true, "speed": 1.5],
            level: "castle_2", steps: "Walk to the door"
        )
        let result = submit(client, report)

        guard case .success(let receipt) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(receipt, RavensightReportReceipt(id: "sub_1", reportId: "rep_1", status: "complete", usageEvents: 1, clientId: report.clientId))
        let requests = reportRequests(transport)
        XCTAssertEqual(requests.map { $0.method + " " + $0.url }, ["POST https://fake.test/api/v1/reports"])
        let sent = requests[0]
        XCTAssertEqual(sent.headers["X-Session-Token"], "sess_1", "the session was opened for the report")
        XCTAssertEqual(sent.headers["Content-Type"], "application/json")
        XCTAssertNil(sent.headers["X-API-Key"])
        let payload = body(sent)
        XCTAssertEqual(payload["clientId"] as? String, report.clientId)
        XCTAssertNotNil(report.clientId.range(of: "^[a-f0-9]{32}$", options: .regularExpression))
        XCTAssertEqual(payload["message"] as? String, "The door will not open")
        XCTAssertEqual(payload["category"] as? String, "bug")
        XCTAssertEqual((payload["capturedAt"] as? NSNumber)?.int64Value, report.capturedAt)
        XCTAssertEqual(payload["level"] as? String, "castle_2")
        XCTAssertEqual(payload["steps"] as? String, "Walk to the door")
        XCTAssertNil(payload["expected"], "empty fields are left out")
        XCTAssertNil(payload["image"], "no screenshot, no image fields")
        let context = payload["context"] as? [String: Any]
        XCTAssertEqual(context?["zone"] as? String, "castle")
        XCTAssertEqual(context?["deaths"] as? Int, 3)
        XCTAssertEqual(context?["hard_mode"] as? Bool, true)
        XCTAssertEqual(context?["speed"] as? Double, 1.5)
    }

    func testScreenshotReportUploadsToStorageThenFinalizes() {
        let transport = FakeTransport()
        serveReports(transport)
        let client = makeClient(transport: transport)
        client.start()
        let report = RavensightReport(category: "bug", message: "Clipping", screenshotData: tinyPNG)
        let result = submit(client, report)

        guard case .success(let receipt) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(receipt.reportId, "rep_2")
        XCTAssertEqual(receipt.usageEvents, 20_001)
        let requests = reportRequests(transport)
        XCTAssertEqual(requests.map { $0.method + " " + $0.url }, [
            "POST https://fake.test/api/v1/reports",
            "POST https://fake.test/api/v1/reports/sub_1/upload",
            "POST https://storage.test/bucket",
            "POST https://fake.test/api/v1/reports/sub_1/finalize",
            "GET https://fake.test/api/v1/reports/sub_1",
        ])

        let initiate = body(requests[0])
        XCTAssertEqual(initiate["image"] as? Bool, true)
        XCTAssertEqual(initiate["bytes"] as? Int, tinyPNG.count)
        let expectedHash = SHA256.hash(data: tinyPNG).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(initiate["sha256"] as? String, expectedHash)

        let upload = requests[2]
        XCTAssertNil(upload.headers["X-Session-Token"], "storage never sees the session token")
        XCTAssertNil(upload.headers["X-API-Key"])
        XCTAssertNil(upload.headers["X-Ravensight-Playtest"])
        let contentType = upload.headers["Content-Type"] ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let multipart = upload.body ?? Data()
        let text = String(decoding: multipart, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"key\"\r\n\r\nplayer-reports/staging/sub_1\r\n"))
        XCTAssertTrue(text.contains("name=\"Content-Type\"\r\n\r\napplication/octet-stream\r\n"))
        XCTAssertTrue(text.contains("name=\"Policy\"\r\n\r\np0\r\n"))
        XCTAssertNotNil(multipart.range(of: tinyPNG), "the exact bytes that were hashed")
        let fileHeader = multipart.range(of: Data("name=\"file\"".utf8))
        let lastField = multipart.range(of: Data("name=\"Policy\"".utf8))
        XCTAssertNotNil(fileHeader)
        XCTAssertGreaterThan(fileHeader?.lowerBound ?? 0, lastField?.lowerBound ?? Int.max, "the file comes last")
        XCTAssertTrue(text.hasSuffix("--\r\n"))
    }

    func testReportsCarryThePlaytestHeaderToRavensightOnly() {
        let transport = FakeTransport()
        serveReports(transport)
        let client = makeClient(transport: transport, environment: [
            "RAVENSIGHT_PLAYTEST_TOKEN": "pt_token",
            "RAVENSIGHT_PLAYTEST_RUN_ID": "run_7",
        ])
        client.start()
        _ = submit(client, RavensightReport(message: "Persona report", screenshotData: tinyPNG))
        for request in reportRequests(transport) {
            if request.url.hasPrefix("https://fake.test") {
                XCTAssertEqual(request.headers["X-Ravensight-Playtest"], "pt_token")
            } else {
                XCTAssertNil(request.headers["X-Ravensight-Playtest"])
            }
        }
    }

    // MARK: Refusals

    func testOptOutBlocksReportsWithNoRequest() {
        let transport = FakeTransport()
        serveReports(transport)
        let client = makeClient(transport: transport)
        client.setTrackingEnabled(false)
        client.start()
        XCTAssertEqual(code(submit(client, RavensightReport(message: "x", screenshotData: tinyPNG))), "disabled")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testStopAllBlocksReportsInASyntheticSessionToo() {
        let transport = FakeTransport()
        serveReports(transport)
        let client = makeClient(transport: transport, environment: [
            "RAVENSIGHT_PLAYTEST_TOKEN": "pt_token",
            "RAVENSIGHT_PLAYTEST_RUN_ID": "run_7",
        ])
        client.start()
        client.stopAllTelemetry()
        XCTAssertEqual(code(submit(client, RavensightReport(message: "x"))), "disabled")
        XCTAssertTrue(reportRequests(transport).isEmpty)
    }

    func testLocalValidationMakesNoRequest() {
        let transport = FakeTransport()
        serveReports(transport)
        let client = makeClient(transport: transport)
        client.start()
        let longMessage = String(repeating: "a", count: 501)
        XCTAssertEqual(code(submit(client, RavensightReport(message: "  "))), "empty_message")
        XCTAssertEqual(code(submit(client, RavensightReport(message: longMessage))), "message_too_long")
        XCTAssertEqual(code(submit(client, RavensightReport(category: "rant", message: "x"))), "invalid_category")
        XCTAssertEqual(code(submit(client, RavensightReport(message: "x", metadata: ["1bad": "v"]))), "invalid_metadata")
        XCTAssertEqual(code(submit(client, RavensightReport(message: "x", metadata: ["k": .string(longMessage)]))), "invalid_metadata")
        XCTAssertEqual(code(submit(client, RavensightReport(message: "x", capturedAt: Date().addingTimeInterval(-2 * 86_400)))), "invalid_capture_time")
        XCTAssertEqual(code(submit(client, RavensightReport(message: "x", screenshotData: Data(repeating: 1, count: 64)))), "invalid_image")
        var huge = Data([0xFF, 0xD8, 0xFF])
        huge.append(Data(repeating: 0, count: 1_000_000))
        XCTAssertEqual(code(submit(client, RavensightReport(message: "x", screenshotData: huge))), "image_too_large")
        #if canImport(ImageIO)
        XCTAssertEqual(code(submit(client, RavensightReport(message: "x", screenshotData: Self.png(width: 2001, height: 2001)))), "image_too_large")
        #endif
        XCTAssertTrue(reportRequests(transport).isEmpty)
    }

    func testRetryReusesTheSameSubmission() {
        let transport = FakeTransport()
        var initiates = 0
        transport.override = { [unowned self] request in
            guard request.url == "https://fake.test/api/v1/reports" else { return nil }
            initiates += 1
            if initiates == 1 {
                return RavensightResponse(status: 503, body: self.json(["error": "attachments_unavailable"]))
            }
            return RavensightResponse(status: 201, body: self.json(["id": "sub_1", "status": "complete", "reportId": "rep_1", "usageEvents": 1]))
        }
        let client = makeClient(transport: transport)
        client.start()
        let report = RavensightReport(message: "Retry me")
        let first = submit(client, report)
        XCTAssertEqual(code(first), "attachments_unavailable")
        if case .failure(let error) = first { XCTAssertEqual(error.status, 503) }
        let second = submit(client, report)
        guard case .success = second else { return XCTFail("the retry succeeds") }
        let bodies = reportRequests(transport).map { body($0) }
        XCTAssertEqual(bodies.count, 2, "one attempt per call, no automatic retry")
        XCTAssertEqual(bodies[0]["clientId"] as? String, bodies[1]["clientId"] as? String)
        XCTAssertEqual((bodies[0]["capturedAt"] as? NSNumber)?.int64Value, (bodies[1]["capturedAt"] as? NSNumber)?.int64Value)
    }

    func testAFailedUploadStopsBeforeFinalize() {
        let transport = FakeTransport()
        serveReports(transport, storageStatus: 403)
        let client = makeClient(transport: transport)
        client.start()
        let result = submit(client, RavensightReport(message: "x", screenshotData: tinyPNG))
        XCTAssertEqual(code(result), "upload_failed")
        if case .failure(let error) = result { XCTAssertEqual(error.status, 403) }
        XCTAssertFalse(reportRequests(transport).contains { $0.url.hasSuffix("/finalize") })
        XCTAssertNil(client.statusReason, "a storage refusal is not a key refusal")
    }

    func testTrackingDisabledOnTheReportRouteIsTheKillSwitch() {
        let transport = FakeTransport()
        transport.override = { [unowned self] request in
            guard request.url.contains("/reports") else { return nil }
            return RavensightResponse(status: 403, body: self.json(["error": "tracking_disabled"]))
        }
        let client = makeClient(transport: transport)
        client.start()
        XCTAssertEqual(code(submit(client, RavensightReport(message: "x"))), "tracking_disabled")
        let barrier = expectation(description: "barrier")
        client.onWorkQueue { barrier.fulfill() }
        wait(for: [barrier], timeout: 2)
        XCTAssertEqual(client.statusReason, "tracking_disabled")
    }

    func testNoSessionInTimeFailsWithNoSession() {
        let transport = FakeTransport()
        transport.sessionStatus = 500
        serveReports(transport)
        let client = makeClient(transport: transport)
        client.reportSessionWait = 0.3
        client.start()
        XCTAssertEqual(code(submit(client, RavensightReport(message: "x"))), "no_session")
        XCTAssertTrue(reportRequests(transport).isEmpty)
    }

    func testAPendingSubmissionWithoutTheScreenshotIsAConflict() {
        let transport = FakeTransport()
        transport.override = { [unowned self] request in
            guard request.url == "https://fake.test/api/v1/reports" else { return nil }
            return RavensightResponse(status: 201, body: self.json(["id": "sub_1", "status": "pending"]))
        }
        let client = makeClient(transport: transport)
        client.start()
        XCTAssertEqual(code(submit(client, RavensightReport(message: "x"))), "submission_conflict")
    }

    #if canImport(UIKit) && !os(watchOS)
    func testAUIImageIsEncodedOnceAsJPEGWithinTheLimits() {
        let size = CGSize(width: 3000, height: 2000)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let report = RavensightReport(category: "bug", message: "x", screenshot: image)
        guard let data = report.screenshot else { return XCTFail("encoded") }
        XCTAssertEqual(Array(data.prefix(3)), [0xFF, 0xD8, 0xFF], "JPEG")
        XCTAssertLessThanOrEqual(data.count, RavensightReport.maxScreenshotBytes)
        XCTAssertNil(RavensightReport.imageRefusal(data), "fits 1600 by 1600, so under the pixel limit")
        XCTAssertNil(RavensightReport(message: "x", screenshot: nil).screenshot, "no image unless one is passed")
    }

    func testARetinaScreenshotKeepsItsPixelsNotItsPoints() {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 3
        let points = CGSize(width: 400, height: 300) // 1200 by 900 pixels
        let image = UIGraphicsImageRenderer(size: points, format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: points))
        }
        guard let data = RavensightReport(message: "x", screenshot: image).screenshot,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return XCTFail("encoded")
        }
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 1200)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 900)
    }

    func testALargeScreenshotIsScaledToFit1600Pixels() {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 3
        let points = CGSize(width: 1000, height: 500) // 3000 by 1500 pixels
        let image = UIGraphicsImageRenderer(size: points, format: format).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(origin: .zero, size: points))
        }
        guard let data = RavensightReport(message: "x", screenshot: image).screenshot,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return XCTFail("encoded")
        }
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 1600)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 800)
    }
    #endif

    #if canImport(ImageIO)
    /// A blank PNG of the given size, for the pixel limit.
    private static func png(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
    #endif
}
