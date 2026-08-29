import Foundation

/// One queued analytics event.
struct RavensightEvent {
    var name: String
    var data: [String: Any]
    /// Unix seconds, captured when the event happened.
    var timestamp: Int64

    func payload() -> [String: Any] {
        return ["event": name, "data": data, "timestamp": timestamp]
    }
}

/// Configuration for the protocol core. All values are resolved by the time
/// the core sees them; there are no platform lookups in here.
struct RavensightCoreConfig {
    var ingestKey: String
    /// Normalized base URL ending in /api/v1.
    var apiUrl: String
    var gameVersion: String
    var platform: String
    var deviceId: String
    var maxQueueSize: Int

    init(
        ingestKey: String,
        apiUrl: String = RavensightCore.defaultApiUrl,
        gameVersion: String = "1.0.0",
        platform: String = "apple",
        deviceId: String,
        maxQueueSize: Int = RavensightCore.defaultQueueCap
    ) {
        self.ingestKey = ingestKey
        self.apiUrl = RavensightCore.normalizeApiUrl(apiUrl)
        self.gameVersion = gameVersion
        self.platform = platform
        self.deviceId = deviceId
        self.maxQueueSize = maxQueueSize > 0 ? maxQueueSize : RavensightCore.defaultQueueCap
    }
}

/// Counters mirrored from the Unity SDK's RavensightStats.
struct RavensightCoreStats {
    var queued = 0
    var sent = 0
    var dropped = 0
    var flushes = 0
    var sessions = 0
}

/// The whole Ravensight protocol as a pure, clock injected state machine:
/// the boot kill switch, sessions, batching at the 50 event server limit,
/// the offline queue with a drop oldest cap, re authentication on 401,
/// Retry-After on 429, exponential backoff from 10 seconds to 5 minutes, and
/// oversize batch splitting on 400.
///
/// The core never performs I/O and never reads a clock. A driver asks it what
/// to do next with nextStep(nowMs:), performs the network request it was
/// handed, and feeds the response back through handle(response:for:nowMs:).
/// Every method takes the current time in unix milliseconds, which is what
/// makes the whole protocol testable with a fake clock and no URLSession.
struct RavensightCore {
    // MARK: Constants

    static let defaultApiUrl = "https://api.ravensight.io/api/v1"
    /// Server hard limit on POST /track/batch.
    static let maxBatchSize = 50
    static let defaultQueueCap = 500
    static let defaultRetryMs: Int64 = 10_000
    static let maxBackoffMs: Int64 = 300_000
    static let sessionExpirySkewMs: Int64 = 5_000

    /// What an in flight request was for, so the response can be routed.
    enum Purpose: Equatable {
        case settings
        case session
        case batch(count: Int)
    }

    /// What the driver should do next.
    enum Step: Equatable {
        /// Nothing to do until new events arrive.
        case idle
        /// Perform this request and feed the response back.
        case send(RavensightRequest, Purpose)
        /// Work is pending but the backoff window is open; try again then.
        case wait(untilMs: Int64)
    }

    /// Observable outcomes of a handled response, mirroring the Godot SDK's
    /// signals. The driver decides what to do with them (log, notify).
    enum Effect: Equatable {
        case trackingDisabled
        case sessionReady
        case sessionFailed(String)
        case eventsFlushed(Int)
        case flushFailed(String)
        case eventDropped(String)
    }

    // MARK: State

    let config: RavensightCoreConfig

    /// Local opt in and opt out. Disabling discards anything queued.
    private(set) var enabled = true
    /// Server side kill switch from GET /settings. Assumed on until checked.
    private(set) var trackingEnabled = true
    /// True once the boot settings check has been answered (or failed).
    private(set) var settingsChecked = false

    private(set) var sessionToken: String?
    /// Unix milliseconds.
    private(set) var sessionExpiresAtMs: Int64 = 0
    /// Set when something other than the queue needs a session (feedback).
    private(set) var sessionWanted = false

    private(set) var pendingEvents: [RavensightEvent] = []

    private(set) var backoffMs = RavensightCore.defaultRetryMs
    private(set) var nextAttemptAtMs: Int64 = 0
    /// Shrinks below maxBatchSize while splitting an oversize batch on 400.
    private(set) var batchLimit = RavensightCore.maxBatchSize
    private(set) var consecutiveUnauthorized = 0

    private var counters = RavensightCoreStats()

    init(config: RavensightCoreConfig) {
        self.config = config
    }

    // MARK: Derived state

    var isActive: Bool {
        return enabled && trackingEnabled
    }

    var stats: RavensightCoreStats {
        var copy = counters
        copy.queued = pendingEvents.count
        return copy
    }

    func isSessionValid(nowMs: Int64) -> Bool {
        guard let token = sessionToken, !token.isEmpty else { return false }
        return nowMs < sessionExpiresAtMs - RavensightCore.sessionExpirySkewMs
    }

    /// Accepts a bare host or a full /api/v1 base and always returns the
    /// versioned base with no trailing slash.
    static func normalizeApiUrl(_ url: String) -> String {
        var raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        if raw.isEmpty { raw = String(defaultApiUrl.dropLast(0)) }
        if raw.hasSuffix("/api/v1") { return raw }
        return raw + "/api/v1"
    }

    // MARK: Inputs

    /// Queues an event. Safe to call before the settings check or session.
    /// Returns false when tracking is off (locally or by the kill switch).
    @discardableResult
    mutating func track(name: String, data: [String: Any]?, nowMs: Int64) -> Bool {
        guard isActive, !name.isEmpty else { return false }

        while pendingEvents.count >= config.maxQueueSize {
            pendingEvents.removeFirst() // drop oldest so the newest always survive
            counters.dropped += 1
        }
        pendingEvents.append(RavensightEvent(
            name: name,
            data: RavensightCore.sanitizeJSON(data ?? [:]) as? [String: Any] ?? [:],
            timestamp: nowMs / 1000
        ))
        return true
    }

    /// Local opt in and opt out. Disabling discards anything queued so an opt
    /// out does not leave player data sitting in memory.
    mutating func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        if !value {
            counters.dropped += pendingEvents.count
            pendingEvents.removeAll()
            sessionWanted = false
        }
    }

    /// Ask the state machine to open a session even with an empty queue
    /// (used by feedback, which needs a session token).
    mutating func markSessionWanted() {
        if isActive { sessionWanted = true }
    }

    /// Drop the current session so the next step opens a fresh one.
    mutating func invalidateSession() {
        sessionToken = nil
        sessionExpiresAtMs = 0
    }

    // MARK: Pump

    /// What should happen next. The driver guarantees at most one request is
    /// in flight at a time and only calls this between requests.
    func nextStep(nowMs: Int64, ignoringBackoff: Bool = false) -> Step {
        guard enabled else { return .idle }

        if !settingsChecked {
            return .send(settingsRequest(), .settings)
        }
        guard trackingEnabled else { return .idle }

        let hasWork = !pendingEvents.isEmpty || sessionWanted
        guard hasWork else { return .idle }

        if !ignoringBackoff && nowMs < nextAttemptAtMs {
            return .wait(untilMs: nextAttemptAtMs)
        }

        if !isSessionValid(nowMs: nowMs) {
            return .send(sessionRequest(), .session)
        }

        guard !pendingEvents.isEmpty else { return .idle }
        let count = min(batchLimit, pendingEvents.count)
        return .send(batchRequest(count: count), .batch(count: count))
    }

    /// Feed the response for a request previously handed out by nextStep.
    mutating func handle(response: RavensightResponse, for purpose: Purpose, nowMs: Int64) -> [Effect] {
        switch purpose {
        case .settings:
            return handleSettings(response)
        case .session:
            return handleSession(response, nowMs: nowMs)
        case .batch(let count):
            return handleBatch(response, count: count, nowMs: nowMs)
        }
    }

    // MARK: Response handling

    private mutating func handleSettings(_ response: RavensightResponse) -> [Effect] {
        settingsChecked = true

        if response.status == 200,
           let object = response.json as? [String: Any],
           let flag = object["trackingEnabled"] as? Bool {
            trackingEnabled = flag
        } else {
            // Unreachable or malformed: assume tracking is on, same as the
            // Godot and Unity SDKs, so a settings outage does not lose data.
            trackingEnabled = true
        }

        if !trackingEnabled {
            counters.dropped += pendingEvents.count
            pendingEvents.removeAll()
            sessionWanted = false
            return [.trackingDisabled]
        }
        return []
    }

    private mutating func handleSession(_ response: RavensightResponse, nowMs: Int64) -> [Effect] {
        let parsed = response.json as? [String: Any]
        let token = parsed?["token"] as? String

        if response.status == 201, let token = token, !token.isEmpty {
            sessionToken = token
            sessionExpiresAtMs = RavensightCore.resolveExpiryMs(parsed, nowMs: nowMs)
            sessionWanted = false
            counters.sessions += 1
            resetBackoff()
            return [.sessionReady]
        }

        if response.status == 429 {
            applyRetryAfter(response, nowMs: nowMs)
            return [.sessionFailed(response.errorCode(fallback: "rate_limited"))]
        }

        scheduleBackoff(nowMs: nowMs)
        return [.sessionFailed(response.errorCode(fallback: fallbackCode(for: response.status)))]
    }

    private mutating func handleBatch(_ response: RavensightResponse, count: Int, nowMs: Int64) -> [Effect] {
        switch response.status {
        case 202:
            let removed = min(count, pendingEvents.count)
            pendingEvents.removeFirst(removed)
            counters.sent += removed
            counters.flushes += 1
            batchLimit = RavensightCore.maxBatchSize
            consecutiveUnauthorized = 0
            resetBackoff()
            return [.eventsFlushed(removed)]

        case 401:
            // Session expired or revoked. The batch stays queued and is re
            // sent as soon as a fresh session is issued. Repeated rejections
            // of freshly minted sessions back off instead of spinning.
            invalidateSession()
            consecutiveUnauthorized += 1
            if consecutiveUnauthorized >= 2 {
                scheduleBackoff(nowMs: nowMs)
            }
            return []

        case 429:
            applyRetryAfter(response, nowMs: nowMs)
            return [.flushFailed(response.errorCode(fallback: "rate_limited"))]

        case 400:
            if count > 1 {
                // Oversize batch: halve and retry, down to a single event.
                batchLimit = max(1, count / 2)
                return []
            }
            // A single event the server will never take. Drop it so the rest
            // of the queue is not blocked behind it forever.
            if !pendingEvents.isEmpty {
                pendingEvents.removeFirst()
                counters.dropped += 1
            }
            batchLimit = RavensightCore.maxBatchSize
            return [.eventDropped(response.errorCode(fallback: "http_400"))]

        default:
            scheduleBackoff(nowMs: nowMs)
            return [.flushFailed(response.errorCode(fallback: fallbackCode(for: response.status)))]
        }
    }

    // MARK: Backoff

    private mutating func resetBackoff() {
        backoffMs = RavensightCore.defaultRetryMs
        nextAttemptAtMs = 0
    }

    private mutating func scheduleBackoff(nowMs: Int64) {
        nextAttemptAtMs = nowMs + backoffMs
        backoffMs = min(backoffMs * 2, RavensightCore.maxBackoffMs)
    }

    private mutating func applyRetryAfter(_ response: RavensightResponse, nowMs: Int64) {
        let waitMs = response.retryAfterMs
        if waitMs > 0 {
            nextAttemptAtMs = nowMs + waitMs
        } else {
            scheduleBackoff(nowMs: nowMs)
        }
    }

    private func fallbackCode(for status: Int) -> String {
        return status == 0 ? "network_error" : "http_\(status)"
    }

    // MARK: Request builders

    private func settingsRequest() -> RavensightRequest {
        return RavensightRequest(
            method: "GET",
            url: config.apiUrl + "/settings",
            headers: ["X-API-Key": config.ingestKey]
        )
    }

    private func sessionRequest() -> RavensightRequest {
        let body: [String: Any] = [
            "deviceId": config.deviceId,
            "gameVersion": config.gameVersion,
            "platform": config.platform,
        ]
        return RavensightRequest(
            method: "POST",
            url: config.apiUrl + "/session",
            headers: [
                "Content-Type": "application/json",
                "X-API-Key": config.ingestKey,
            ],
            body: RavensightCore.encodeJSON(body)
        )
    }

    private func batchRequest(count: Int) -> RavensightRequest {
        let events = pendingEvents.prefix(count).map { $0.payload() }
        let body: [String: Any] = ["events": events]
        return RavensightRequest(
            method: "POST",
            url: config.apiUrl + "/track/batch",
            headers: [
                "Content-Type": "application/json",
                "X-Session-Token": sessionToken ?? "",
            ],
            body: RavensightCore.encodeJSON(body)
        )
    }

    func feedbackRequest(message: String, category: String?, rating: Int, token: String) -> RavensightRequest {
        var payload: [String: Any] = ["message": message]
        if let category = category, !category.isEmpty { payload["category"] = category }
        if rating > 0 { payload["rating"] = rating }
        return RavensightRequest(
            method: "POST",
            url: config.apiUrl + "/feedback",
            headers: [
                "Content-Type": "application/json",
                "X-Session-Token": token,
            ],
            body: RavensightCore.encodeJSON(payload)
        )
    }

    func suggestionsRequest() -> RavensightRequest {
        return RavensightRequest(
            method: "GET",
            url: config.apiUrl + "/agent/suggestions",
            headers: ["X-API-Key": config.ingestKey]
        )
    }

    // MARK: JSON helpers

    /// Resolves session expiry the way the Godot SDK does: an absolute
    /// expiresAt in unix seconds wins, then a relative expiresIn, then a one
    /// day default.
    static func resolveExpiryMs(_ parsed: [String: Any]?, nowMs: Int64) -> Int64 {
        if let expiresAt = numberValue(parsed?["expiresAt"]), expiresAt > 0 {
            return Int64(expiresAt * 1000)
        }
        let expiresIn = numberValue(parsed?["expiresIn"]).flatMap { $0 > 0 ? $0 : nil } ?? 86_400
        return nowMs + Int64(expiresIn * 1000)
    }

    static func numberValue(_ value: Any?) -> Double? {
        if value is NSNull { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    static func encodeJSON(_ object: [String: Any]) -> Data {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return Data("{}".utf8)
        }
        return data
    }

    /// Keeps JSON friendly values as they are and stringifies anything else,
    /// so a stray Date or custom struct in event data cannot poison a batch.
    static func sanitizeJSON(_ value: Any) -> Any {
        switch value {
        case is String, is NSNull:
            return value
        case let number as NSNumber:
            return number
        case let dictionary as [String: Any]:
            return dictionary.mapValues { sanitizeJSON($0) }
        case let array as [Any]:
            return array.map { sanitizeJSON($0) }
        case let optional as Any?:
            guard let unwrapped = optional else { return NSNull() }
            return String(describing: unwrapped)
        }
    }
}
