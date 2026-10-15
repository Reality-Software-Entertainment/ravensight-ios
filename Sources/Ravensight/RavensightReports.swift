import Foundation
import CryptoKit
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// A scalar value in a report's metadata. Write plain literals:
/// `["zone": "castle", "deaths": 3, "hard_mode": true]`.
public enum RavensightMetadataValue: Equatable, Sendable,
    ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }

    var jsonValue: Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        }
    }

    /// The length the server checks (its String() of the value).
    var textLength: Int {
        switch self {
        case .string(let value): return value.utf16.count
        case .int(let value): return String(value).utf16.count
        case .double(let value): return String(value).utf16.count
        case .bool(let value): return value ? 4 : 5
        }
    }
}

/// One player report, built once and safe to submit again. The submission
/// id (clientId), the capture time and the screenshot bytes are fixed when
/// the value is created, so resubmitting the same value after a failure is
/// recognised by the server as the same report: it is never stored or
/// charged twice. A different message under the same clientId is refused
/// with submission_conflict.
public struct RavensightReport: Sendable {
    /// The idempotency key the server deduplicates on (32 hex characters).
    public let clientId: String
    /// Unix seconds. The server accepts reports captured within the last day.
    public let capturedAt: Int64
    /// One of Ravensight.feedbackCategories. Default "other".
    public let category: String
    /// What the player wrote. Required, at most 500 characters.
    public let message: String
    /// Developer chosen scalar context: keys start with a letter and use
    /// letters, digits and underscores (at most 40), values at most 500
    /// characters, at most 8 KB in all. Never put secrets, logs or chat here.
    public let metadata: [String: RavensightMetadataValue]
    /// Optional detail fields: level (100 characters), what the player
    /// expected (500), steps to reproduce (1,000), how often (80).
    public let level: String
    public let expected: String
    public let steps: String
    public let frequency: String
    /// The exact image bytes that will be uploaded (JPEG, PNG or WebP, at
    /// most 1,000,000 bytes and 4,000,000 pixels), or nil for a text report.
    public let screenshot: Data?
    /// True when a screenshot was passed but could not be encoded.
    let screenshotUnusable: Bool

    /// A report with optional screenshot bytes you prepared yourself.
    public init(
        category: String = "other",
        message: String,
        screenshotData: Data? = nil,
        metadata: [String: RavensightMetadataValue] = [:],
        level: String = "",
        expected: String = "",
        steps: String = "",
        frequency: String = "",
        capturedAt: Date = Date(),
        clientId: String? = nil
    ) {
        self.clientId = clientId ?? RavensightReport.mintClientId()
        self.capturedAt = Int64(capturedAt.timeIntervalSince1970)
        self.category = category
        self.message = message
        self.metadata = metadata
        self.level = level
        self.expected = expected
        self.steps = steps
        self.frequency = frequency
        self.screenshot = screenshotData
        self.screenshotUnusable = false
    }

    #if canImport(UIKit) && !os(watchOS)
    /// A report with an optional screenshot the game captured itself. The
    /// image is scaled to fit 1600 by 1600 and encoded as JPEG once, here,
    /// so a resubmission sends identical bytes. The SDK never captures the
    /// screen on its own: pass an image only when the player chose to
    /// attach one, with anything private already hidden.
    public init(
        category: String = "other",
        message: String,
        screenshot: UIImage?,
        metadata: [String: RavensightMetadataValue] = [:],
        level: String = "",
        expected: String = "",
        steps: String = "",
        frequency: String = "",
        capturedAt: Date = Date(),
        clientId: String? = nil
    ) {
        let encoded = screenshot.flatMap { RavensightReport.encodeScreenshot($0) }
        self.init(
            category: category, message: message, screenshotData: encoded, metadata: metadata,
            level: level, expected: expected, steps: steps, frequency: frequency,
            capturedAt: capturedAt, clientId: clientId
        )
        if screenshot != nil && encoded == nil {
            self = RavensightReport(copying: self, unusable: true)
        }
    }

    /// Scales to fit 1600 by 1600 (the size the server keeps) and encodes
    /// JPEG under the 1,000,000 byte limit, or nil if it cannot.
    static func encodeScreenshot(_ image: UIImage) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        for (side, quality) in [(1600.0, 0.78), (1600.0, 0.6), (1200.0, 0.6), (800.0, 0.6)] {
            let scale = min(1, side / max(size.width, size.height))
            let target = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            format.opaque = true
            let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
            }
            if let data = rendered.jpegData(compressionQuality: quality),
               data.count <= RavensightReport.maxScreenshotBytes {
                return data
            }
        }
        return nil
    }
    #endif

    private init(copying other: RavensightReport, unusable: Bool) {
        clientId = other.clientId
        capturedAt = other.capturedAt
        category = other.category
        message = other.message
        metadata = other.metadata
        level = other.level
        expected = other.expected
        steps = other.steps
        frequency = other.frequency
        screenshot = other.screenshot
        screenshotUnusable = unusable
    }

    // MARK: Limits the server enforces (src/services/playerReports/contract.js)

    public static let maxScreenshotBytes = 1_000_000
    public static let maxScreenshotPixels = 4_000_000
    public static let maxMessageLength = 500
    public static let maxMetadataBytes = 8_000

    static func mintClientId() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ data: Data) -> String {
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The local refusal for this report, or nil when it may be sent.
    func refusal(nowSec: Int64) -> String? {
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "empty_message" }
        if message.utf16.count > RavensightReport.maxMessageLength { return "message_too_long" }
        if !RavensightCore.feedbackCategories.contains(category) { return "invalid_category" }
        if level.utf16.count > 100 || expected.utf16.count > 500
            || steps.utf16.count > 1000 || frequency.utf16.count > 80 { return "invalid_report" }
        if clientId.range(of: "^[a-zA-Z0-9_-]{8,80}$", options: .regularExpression) == nil { return "invalid_report" }
        for (key, value) in metadata {
            if key.range(of: "^[a-zA-Z][a-zA-Z0-9_]{0,39}$", options: .regularExpression) == nil
                || value.textLength > 500 {
                return "invalid_metadata"
            }
            if case .double(let number) = value, !number.isFinite { return "invalid_metadata" }
        }
        if RavensightCore.encodeJSON(metadataJSON).count > RavensightReport.maxMetadataBytes { return "invalid_metadata" }
        if capturedAt < nowSec - 86_400 || capturedAt > nowSec + 60 { return "invalid_capture_time" }
        if screenshotUnusable { return "invalid_image" }
        if let image = screenshot, let problem = RavensightReport.imageRefusal(image) { return problem }
        return nil
    }

    /// Checks bytes the way the server's image worker will: at most
    /// 1,000,000 bytes, a still JPEG, PNG or WebP, at most 4,000,000 pixels.
    static func imageRefusal(_ data: Data) -> String? {
        if data.isEmpty { return "invalid_image" }
        if data.count > maxScreenshotBytes { return "image_too_large" }
        let bytes = [UInt8](data.prefix(12))
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        let isPNG = bytes.count >= 4 && Array(bytes[0..<4]) == png
        let isJPEG = bytes.count >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF
        let isWebP = bytes.count >= 12 && Array(bytes[0..<4]) == Array("RIFF".utf8) && Array(bytes[8..<12]) == Array("WEBP".utf8)
        guard isPNG || isJPEG || isWebP else { return "invalid_image" }
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return "invalid_image" }
        if CGImageSourceGetCount(source) != 1 { return "invalid_image" }
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
           width * height > maxScreenshotPixels {
            return "image_too_large"
        }
        #endif
        return nil
    }

    var metadataJSON: [String: Any] {
        return metadata.mapValues { $0.jsonValue }
    }

    /// The POST /reports body.
    var initiateBody: [String: Any] {
        var body: [String: Any] = [
            "clientId": clientId,
            "message": message,
            "category": category,
            "context": metadataJSON,
            "capturedAt": capturedAt,
        ]
        if !level.isEmpty { body["level"] = level }
        if !expected.isEmpty { body["expected"] = expected }
        if !steps.isEmpty { body["steps"] = steps }
        if !frequency.isEmpty { body["frequency"] = frequency }
        if let image = screenshot {
            body["image"] = true
            body["bytes"] = image.count
            body["sha256"] = RavensightReport.sha256Hex(image)
        }
        return body
    }
}

/// What the server holds for a submitted report.
public struct RavensightReportReceipt: Equatable, Sendable {
    /// The submission id.
    public let id: String
    /// The stored report's id once it is complete.
    public let reportId: String?
    /// "complete" on success.
    public let status: String
    /// Shared usage events this report draws: 1 for text, 20,001 with a
    /// screenshot (20,000 for the image plus the report).
    public let usageEvents: Int
    /// The report's clientId, to match it to your own record.
    public let clientId: String
}

extension RavensightClient {
    typealias ReportCompletion = (Result<RavensightReportReceipt, RavensightError>) -> Void

    /// Submits a Player Report: text, optional detail fields, scalar
    /// metadata and an optional screenshot, through the server's report
    /// routes (POST /reports, then for a screenshot POST /reports/:id/upload,
    /// the upload itself, POST /reports/:id/finalize, and status checks
    /// while the image is processed).
    ///
    /// Usage: a text report draws one shared usage event; a screenshot adds
    /// 20,000, reserved when the report is accepted.
    ///
    /// Retries: the SDK makes one attempt per step and never retries on its
    /// own, because a screenshot reserves usage. On failure the error code
    /// says what happened; submit the same RavensightReport value again to
    /// retry (same clientId, capture time and bytes), and the server picks
    /// up where it stopped instead of creating a second report. The server
    /// allows two upload attempts per report, and releases an unfinished
    /// screenshot report's reservation after 15 minutes. A retry after a
    /// day fails with invalid_capture_time; build a new report then.
    ///
    /// Refused locally, with no request, while tracking is off (opted out,
    /// stopped, disabled, kill switch): "disabled". Other local codes:
    /// "empty_message", "message_too_long", "invalid_category",
    /// "invalid_metadata", "invalid_report", "invalid_capture_time",
    /// "invalid_image", "image_too_large". "no_session" when no session
    /// opened within 10 seconds. Server codes pass through ("report_limit",
    /// "event_limit", "attachments_unavailable", "feature_disabled",
    /// "submission_conflict", "upload_limit", "upload_closed"), plus
    /// "upload_failed" when the upload itself failed, "report_canceled",
    /// and "report_processing" when the screenshot was still being checked
    /// after the status checks ran out (submit again later to check).
    /// The completion is delivered on the main queue.
    public func submitReport(
        _ report: RavensightReport,
        completion: ((Result<RavensightReportReceipt, RavensightError>) -> Void)? = nil
    ) {
        workQueue.async {
            let finish: ReportCompletion = { result in
                if case .failure(let error) = result { self.log("report failed: \(error)") }
                if let completion = completion {
                    DispatchQueue.main.async { completion(result) }
                }
            }
            guard self.core.isActive else {
                finish(.failure(RavensightError(code: "disabled", status: 0, message: "tracking is off, report not sent")))
                return
            }
            if let refusal = report.refusal(nowSec: self.now() / 1000) {
                finish(.failure(RavensightError(code: refusal, status: 0, message: "report refused locally (\(refusal))")))
                return
            }
            self.withReportSession(deadline: Date().addingTimeInterval(self.reportSessionWait), finish: finish) { token in
                self.initiateReport(report, token: token, finish: finish)
            }
        }
    }

    /// Text and metadata, with an optional screenshot as JPEG, PNG or WebP
    /// bytes. Returns the report so a failed submission can be retried with
    /// submitReport(_:completion:).
    @discardableResult
    public func submitReport(
        category: String = "other",
        message: String,
        screenshotData: Data?,
        metadata: [String: RavensightMetadataValue] = [:],
        completion: ((Result<RavensightReportReceipt, RavensightError>) -> Void)? = nil
    ) -> RavensightReport {
        let report = RavensightReport(category: category, message: message, screenshotData: screenshotData, metadata: metadata)
        submitReport(report, completion: completion)
        return report
    }

    #if canImport(UIKit) && !os(watchOS)
    /// Text and metadata, with an optional screenshot the game captured. A
    /// screenshot is only sent when you pass one; the SDK never captures
    /// the screen. Returns the report so a failed submission can be retried
    /// with submitReport(_:completion:).
    @discardableResult
    public func submitReport(
        category: String = "other",
        message: String,
        screenshot: UIImage? = nil,
        metadata: [String: RavensightMetadataValue] = [:],
        completion: ((Result<RavensightReportReceipt, RavensightError>) -> Void)? = nil
    ) -> RavensightReport {
        let report = RavensightReport(category: category, message: message, screenshot: screenshot, metadata: metadata)
        submitReport(report, completion: completion)
        return report
    }
    #else
    /// A text report (no UIKit here: pass screenshotData for an image).
    @discardableResult
    public func submitReport(
        category: String = "other",
        message: String,
        metadata: [String: RavensightMetadataValue] = [:],
        completion: ((Result<RavensightReportReceipt, RavensightError>) -> Void)? = nil
    ) -> RavensightReport {
        let report = RavensightReport(category: category, message: message, metadata: metadata)
        submitReport(report, completion: completion)
        return report
    }
    #endif

    // MARK: Steps (work queue)

    private func refusedWhileStopped(_ finish: ReportCompletion) -> Bool {
        guard core.isActive else {
            finish(.failure(RavensightError(code: "disabled", status: 0, message: "tracking turned off, report stopped")))
            return true
        }
        return false
    }

    /// Runs body with a valid session token, opening a session and waiting
    /// for it until the deadline.
    private func withReportSession(deadline: Date, finish: @escaping ReportCompletion, body: @escaping (String) -> Void) {
        if refusedWhileStopped(finish) { return }
        if core.isSessionValid(nowMs: now()), let token = core.sessionToken {
            body(token)
            return
        }
        guard Date() < deadline else {
            finish(.failure(RavensightError(code: "no_session", status: 0, message: "no session opened in time, report not sent")))
            return
        }
        core.markSessionWanted()
        pump()
        workQueue.asyncAfter(deadline: .now() + 0.25) {
            self.withReportSession(deadline: deadline, finish: finish, body: body)
        }
    }

    private func reportFailure(_ response: RavensightResponse, step: String) -> RavensightError {
        let effects = core.applyRefusal(response, keyAuthenticated: false)
        report(effects)
        if response.status == 401 { core.markSessionWanted() }
        stateChanged()
        pump()
        return RavensightError(
            code: response.errorCode(fallback: fallbackCode(response.status)),
            status: response.status,
            message: "report \(step) failed (HTTP \(response.status))"
        )
    }

    private func sendReport(_ request: RavensightRequest, _ handler: @escaping (RavensightResponse) -> Void) {
        transport.send(request) { response in
            self.workQueue.async { handler(response) }
        }
    }

    private func initiateReport(_ report: RavensightReport, token: String, finish: @escaping ReportCompletion) {
        let request = core.reportRequest(method: "POST", path: "", body: report.initiateBody, token: token)
        sendReport(request) { response in
            guard response.status == 201, let object = response.json as? [String: Any],
                  let id = object["id"] as? String, !id.isEmpty else {
                finish(.failure(self.reportFailure(response, step: "submission")))
                return
            }
            self.advanceReport(report, id: id, state: object, token: token, uploaded: false, polls: 0, finish: finish)
        }
    }

    /// Moves a submission on from the state the server last reported.
    private func advanceReport(
        _ report: RavensightReport, id: String, state: [String: Any], token: String,
        uploaded: Bool, polls: Int, finish: @escaping ReportCompletion
    ) {
        if refusedWhileStopped(finish) { return }
        let status = state["status"] as? String ?? ""
        switch status {
        case "complete":
            finish(.success(RavensightReportReceipt(
                id: id,
                reportId: state["reportId"] as? String,
                status: status,
                usageEvents: (state["usageEvents"] as? NSNumber)?.intValue ?? 1,
                clientId: report.clientId
            )))
        case "pending" where !uploaded:
            guard let image = report.screenshot else {
                // A text report completes on creation; pending without an
                // image means the server holds a screenshot report under
                // this clientId that this value no longer carries.
                finish(.failure(RavensightError(code: "submission_conflict", status: 0, message: "the server expects a screenshot for this report")))
                return
            }
            uploadScreenshot(image, id: id, token: token, finish: finish) {
                self.finalizeReport(report, id: id, token: token, finish: finish)
            }
        case "canceled":
            finish(.failure(RavensightError(code: "report_canceled", status: 0, message: "the report was canceled")))
        default:
            // processing, or pending after the upload: check again shortly.
            guard polls < reportPollAttempts else {
                finish(.failure(RavensightError(code: "report_processing", status: 0, message: "the screenshot is still being checked; submit the same report again later")))
                return
            }
            workQueue.asyncAfter(deadline: .now() + reportPollInterval) {
                if self.refusedWhileStopped(finish) { return }
                let request = self.core.reportRequest(method: "GET", path: "/" + id, body: nil, token: token)
                self.sendReport(request) { response in
                    guard response.status == 200, let object = response.json as? [String: Any] else {
                        finish(.failure(self.reportFailure(response, step: "status check")))
                        return
                    }
                    self.advanceReport(report, id: id, state: object, token: token, uploaded: true, polls: polls + 1, finish: finish)
                }
            }
        }
    }

    private func uploadScreenshot(
        _ image: Data, id: String, token: String,
        finish: @escaping ReportCompletion, then: @escaping () -> Void
    ) {
        let request = core.reportRequest(method: "POST", path: "/" + id + "/upload", body: [:], token: token)
        sendReport(request) { response in
            guard response.status == 200, let form = response.json as? [String: Any],
                  let url = form["url"] as? String else {
                finish(.failure(self.reportFailure(response, step: "upload authorization")))
                return
            }
            guard url.hasPrefix("https://") else {
                finish(.failure(RavensightError(code: "upload_failed", status: 0, message: "the upload address is not https")))
                return
            }
            if self.refusedWhileStopped(finish) { return }
            let fields = form["fields"] as? [String: Any] ?? [:]
            let upload = RavensightClient.multipartUpload(url: url, fields: fields, file: image)
            // The upload goes to storage, not to Ravensight: no key, no
            // session token, no playtest header.
            self.sendReport(upload) { response in
                guard (200..<300).contains(response.status) else {
                    finish(.failure(RavensightError(
                        code: "upload_failed", status: response.status,
                        message: "screenshot upload failed (HTTP \(response.status)); submit the same report again to retry"
                    )))
                    return
                }
                then()
            }
        }
    }

    private func finalizeReport(_ report: RavensightReport, id: String, token: String, finish: @escaping ReportCompletion) {
        if refusedWhileStopped(finish) { return }
        let request = core.reportRequest(method: "POST", path: "/" + id + "/finalize", body: [:], token: token)
        sendReport(request) { response in
            guard (response.status == 202 || response.status == 200), let object = response.json as? [String: Any] else {
                finish(.failure(self.reportFailure(response, step: "finalize")))
                return
            }
            self.advanceReport(report, id: id, state: object, token: token, uploaded: true, polls: 0, finish: finish)
        }
    }

    /// A multipart/form-data POST of the presigned fields, then the file.
    static func multipartUpload(url: String, fields: [String: Any], file: Data) -> RavensightRequest {
        let boundary = "ravensight" + RavensightReport.mintClientId()
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        for name in fields.keys.sorted() {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(fields[name].map { "\($0)" } ?? "")\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"screenshot\"\r\nContent-Type: application/octet-stream\r\n\r\n")
        body.append(file)
        append("\r\n--\(boundary)--\r\n")
        return RavensightRequest(
            method: "POST",
            url: url,
            headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"],
            body: body
        )
    }
}
