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
    /// Bare Ravensight Playtest token, sent as X-Ravensight-Playtest on every
    /// request. Nil outside a playtest run.
    var playtestToken: String?

    init(
        ingestKey: String,
        apiUrl: String = RavensightCore.defaultApiUrl,
        gameVersion: String = "1.0.0",
        platform: String = "apple",
        deviceId: String,
        maxQueueSize: Int = RavensightCore.defaultQueueCap,
        playtestToken: String? = nil
    ) {
        self.ingestKey = ingestKey
        self.apiUrl = RavensightCore.normalizeApiUrl(apiUrl)
        self.gameVersion = gameVersion
        self.platform = platform
        self.deviceId = deviceId
        self.maxQueueSize = maxQueueSize > 0 ? maxQueueSize : RavensightCore.defaultQueueCap
        self.playtestToken = (playtestToken?.isEmpty ?? true) ? nil : playtestToken
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
/// Retry-After on 429 and 503, exponential backoff from 10 seconds to 5
/// minutes, oversize batch splitting on 400, the refused key stop, and the
/// one off game_exited send for a session that ended in the background.
///
/// The core never performs I/O and never reads a clock. A driver asks it what
/// to do next with nextStep(nowMs:), performs the network request it was
/// handed, and feeds the response back through handle(response:for:nowMs:).
/// Every method takes the current time in unix milliseconds, which is what
/// makes the whole protocol testable with a fake clock and no URLSession.
struct RavensightCore {
    // MARK: Constants

    /// The default host. normalizeApiUrl appends /api/v1.
    static let defaultHost = "https://api.ravensight.io"
    static let defaultApiUrl = defaultHost
    /// Server hard limit on POST /track/batch.
    static let maxBatchSize = 50
    static let defaultQueueCap = 500
    static let defaultRetryMs: Int64 = 10_000
    static let maxBackoffMs: Int64 = 300_000
    static let sessionExpirySkewMs: Int64 = 5_000
    /// A batch 401 re opens the session at most this many times in a row
    /// before falling back to the exponential backoff.
    static let maxSessionReopens = 2

    /// The startup outcome vocabulary, shared with every Ravensight SDK.
    enum Reason {
        static let disabled = "disabled"
        static let invalidKey = "invalid_key"
        static let trackingDisabled = "tracking_disabled"
        static let offline = "offline"
        static let rateLimited = "rate_limited"
        static let sessionFailed = "session_failed"
        static let playtestJobClosed = "playtest_job_closed"
    }

    /// What an in flight request was for, so the response can be routed.
    enum Purpose: Equatable {
        case settings
        case session
        case batch(count: Int)
        /// The game_exited of a session that ended in the background, sent
        /// under that session's own token. retry is false for the cold
        /// launch marker (one attempt, whatever the answer).
        case exit(retry: Bool)
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

    /// Observable outcomes of a handled response. The driver decides what to
    /// do with them (log, notify, stop the timer).
    enum Effect: Equatable {
        case trackingDisabled
        case sessionReady
        case sessionFailed(String)
        case eventsFlushed(Int)
        case flushFailed(String)
        case eventDropped(String)
        /// 401, or a 403 that is not one of the named refusals.
        case keyRefused
        /// Permanent stop for the run (a closed or invalid playtest token).
        case stopped(String)
    }

    /// A game_exited waiting to go out under a session that has ended.
    struct PendingExit: Equatable {
        var sessionToken: String
        /// Unix seconds: when the player left.
        var timestamp: Int64
        var retry: Bool
    }

    // MARK: State

    private(set) var config: RavensightCoreConfig

    /// The game's runtime switch (construction option and setEnabled). Never
    /// persisted. Disabling discards anything queued.
    private(set) var enabled = true
    /// The player's saved choice. Opting out discards anything queued.
    private(set) var optedOut = false
    /// Server side kill switch from GET /settings or a 403
    /// tracking_disabled. Assumed on until checked.
    private(set) var trackingEnabled = true
    /// True once the boot settings check has been answered (or failed).
    private(set) var settingsChecked = false
    /// The ingest key was refused. Automatic sending stops; an explicit
    /// flush makes one more attempt.
    private(set) var keyRefused = false
    /// Set for a permanent stop for the run (playtest_job_closed, or
    /// session_failed for an unusable playtest token).
    private(set) var stopReason: String?
    /// The last transient failure (offline, rate_limited, session_failed),
    /// cleared by the next success.
    private(set) var lastFailure: String?

    private(set) var sessionToken: String?
    /// Unix milliseconds.
    private(set) var sessionExpiresAtMs: Int64 = 0
    /// Set when something other than the queue needs a session (feedback).
    private(set) var sessionWanted = false

    private(set) var pendingEvents: [RavensightEvent] = []
    private(set) var pendingExit: PendingExit?

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

    /// True when events may be queued: enabled, not opted out, not switched
    /// off by the server and not stopped for the run. A refused key still
    /// queues (the queue is kept, the cap applies).
    var canQueue: Bool {
        return enabled && !optedOut && trackingEnabled && stopReason == nil
    }

    /// True when the client may touch the network on its own.
    var isActive: Bool {
        return canQueue && !keyRefused
    }

    /// Why the client is not ready, or nil when it is (or has not failed).
    var statusReason: String? {
        if !enabled || optedOut { return Reason.disabled }
        if let stop = stopReason { return stop }
        if !trackingEnabled { return Reason.trackingDisabled }
        if keyRefused { return Reason.invalidKey }
        return lastFailure
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

    /// Trims whitespace, strips every trailing slash and a trailing /api/v1,
    /// then appends /api/v1. Empty means the default host.
    static func normalizeApiUrl(_ url: String) -> String {
        var raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        if raw.hasSuffix("/api/v1") { raw.removeLast("/api/v1".count) }
        while raw.hasSuffix("/") { raw.removeLast() }
        if raw.isEmpty { raw = defaultHost }
        return raw + "/api/v1"
    }

    // MARK: Inputs

    /// Queues an event. Safe to call before the settings check or session.
    /// atSec overrides the timestamp (unix seconds), for an event that
    /// happened earlier than now. Returns false when nothing was queued.
    @discardableResult
    mutating func track(name: String, data: [String: Any]?, nowMs: Int64, atSec: Int64? = nil) -> Bool {
        guard canQueue, !name.isEmpty else { return false }

        while pendingEvents.count >= config.maxQueueSize {
            pendingEvents.removeFirst() // drop oldest so the newest always survive
            counters.dropped += 1
        }
        pendingEvents.append(RavensightEvent(
            name: name,
            data: RavensightCore.sanitizeJSON(data ?? [:]) as? [String: Any] ?? [:],
            timestamp: atSec ?? nowMs / 1000
        ))
        return true
    }

    /// The game's runtime switch. Disabling discards anything queued so an
    /// opt out does not leave player data sitting in memory.
    mutating func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        if !value { discardQueue() }
    }

    /// The player's choice. Opting out discards anything queued.
    mutating func setOptedOut(_ value: Bool) {
        guard value != optedOut else { return }
        optedOut = value
        if value { discardQueue() }
    }

    /// Stops the run for good: queue cleared, nothing more is sent.
    mutating func stop(reason: String) {
        guard stopReason == nil else { return }
        stopReason = reason
        discardQueue()
    }

    /// Switches to a new device id (resetDeviceId): the queue is cleared and
    /// the next step opens a fresh session under the new id.
    mutating func replaceDeviceId(_ deviceId: String) {
        config.deviceId = deviceId
        discardQueue()
        invalidateSession()
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

    /// Queue the game_exited of a session that has ended, to be sent under
    /// that session's own token before anything else.
    mutating func setPendingExit(_ exit: PendingExit) {
        guard enabled, !optedOut, stopReason == nil, !exit.sessionToken.isEmpty else { return }
        pendingExit = exit
    }

    private mutating func discardQueue() {
        counters.dropped += pendingEvents.count
        pendingEvents.removeAll()
        sessionWanted = false
        pendingExit = nil
    }

    // MARK: Pump

    /// What should happen next. The driver guarantees at most one request is
    /// in flight at a time and only calls this between requests.
    /// ignoringBackoff is an explicit flush: it skips the backoff window
    /// once and makes one more attempt after a refused key.
    func nextStep(nowMs: Int64, ignoringBackoff: Bool = false) -> Step {
        guard enabled, !optedOut, stopReason == nil else { return .idle }

        if let exit = pendingExit, trackingEnabled {
            if !ignoringBackoff && nowMs < nextAttemptAtMs {
                return .wait(untilMs: nextAttemptAtMs)
            }
            return .send(exitRequest(exit), .exit(retry: exit.retry))
        }

        if keyRefused && !ignoringBackoff { return .idle }

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
        case .exit(let retry):
            return handleExit(response, retry: retry, nowMs: nowMs)
        }
    }

    /// Applies a refusal from an endpoint outside the pump (suggestions,
    /// feedback). Returns the effects, empty when the status is not one.
    /// keyAuthenticated is true for X-API-Key requests, where a 401 means
    /// the key; on a session token request a 401 means the session.
    mutating func applyRefusal(_ response: RavensightResponse, keyAuthenticated: Bool) -> [Effect] {
        if response.status == 401 {
            if keyAuthenticated { return refuseKey() }
            invalidateSession()
            return []
        }
        if response.status == 403 { return handleForbidden(response) }
        return []
    }

    // MARK: Response handling

    private mutating func handleSettings(_ response: RavensightResponse) -> [Effect] {
        settingsChecked = true

        switch response.status {
        case 200:
            if let object = response.json as? [String: Any],
               let flag = object["trackingEnabled"] as? Bool, !flag {
                return killSwitch()
            }
            // Malformed bodies assume tracking is on, like every other SDK.
            trackingEnabled = true
            return []
        case 401:
            return refuseKey()
        case 403:
            return handleForbidden(response)
        case 0:
            // Unreachable: assume tracking is on so a settings outage does
            // not lose data. The session request decides the outcome.
            lastFailure = Reason.offline
            return []
        default:
            return []
        }
    }

    private mutating func handleSession(_ response: RavensightResponse, nowMs: Int64) -> [Effect] {
        let parsed = response.json as? [String: Any]
        let token = parsed?["token"] as? String

        if response.status == 201, let token = token, !token.isEmpty {
            sessionToken = token
            sessionExpiresAtMs = RavensightCore.resolveExpiryMs(parsed, nowMs: nowMs)
            sessionWanted = false
            keyRefused = false
            lastFailure = nil
            counters.sessions += 1
            resetBackoff()
            return [.sessionReady]
        }

        switch response.status {
        case 401:
            return refuseKey()
        case 403:
            return handleForbidden(response)
        case 429:
            applyRetryAfter(response, nowMs: nowMs)
            lastFailure = Reason.rateLimited
            return [.sessionFailed(response.errorCode(fallback: "rate_limited"))]
        case 503:
            applyRetryAfter(response, nowMs: nowMs)
            lastFailure = Reason.sessionFailed
            return [.sessionFailed(response.errorCode(fallback: "http_503"))]
        case 0:
            scheduleBackoff(nowMs: nowMs)
            lastFailure = Reason.offline
            return [.sessionFailed(response.errorCode(fallback: "network_error"))]
        default:
            scheduleBackoff(nowMs: nowMs)
            lastFailure = Reason.sessionFailed
            return [.sessionFailed(response.errorCode(fallback: fallbackCode(for: response.status)))]
        }
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
            lastFailure = nil
            resetBackoff()
            return [.eventsFlushed(removed)]

        case 401:
            // Session expired or revoked. The batch stays queued and is re
            // sent as soon as a fresh session is issued. After two re opens
            // in a row the backoff takes over instead of spinning.
            invalidateSession()
            consecutiveUnauthorized += 1
            if consecutiveUnauthorized > RavensightCore.maxSessionReopens {
                scheduleBackoff(nowMs: nowMs)
            }
            return []

        case 403:
            return handleForbidden(response)

        case 429, 503:
            applyRetryAfter(response, nowMs: nowMs)
            if response.status == 429 { lastFailure = Reason.rateLimited }
            return [.flushFailed(response.errorCode(fallback: response.status == 429 ? "rate_limited" : "http_503"))]

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
            if response.status == 0 { lastFailure = Reason.offline }
            return [.flushFailed(response.errorCode(fallback: fallbackCode(for: response.status)))]
        }
    }

    private mutating func handleExit(_ response: RavensightResponse, retry: Bool, nowMs: Int64) -> [Effect] {
        let transient = response.status == 0 || response.status == 429 || response.status >= 500
        if retry && transient {
            if response.status == 429 || response.status == 503 {
                applyRetryAfter(response, nowMs: nowMs)
            } else {
                scheduleBackoff(nowMs: nowMs)
            }
            return [.flushFailed(response.errorCode(fallback: fallbackCode(for: response.status)))]
        }
        pendingExit = nil
        if response.status == 202 {
            counters.sent += 1
            resetBackoff()
            return [.eventsFlushed(1)]
        }
        if response.status == 403 {
            // The kill switch and a closed playtest still apply; any other
            // 403 here is about the old session, not the key.
            let code = response.errorCode(fallback: "")
            if code == "tracking_disabled" || code == "playtest_job_closed" || code == "invalid_playtest_token" {
                return handleForbidden(response)
            }
        }
        return []
    }

    /// Routes a 403 by its error code: the kill switch, a closed or invalid
    /// playtest token, or otherwise a refused key.
    private mutating func handleForbidden(_ response: RavensightResponse) -> [Effect] {
        switch response.errorCode(fallback: "") {
        case "tracking_disabled":
            return killSwitch()
        case "playtest_job_closed":
            stop(reason: Reason.playtestJobClosed)
            return [.stopped(Reason.playtestJobClosed)]
        case "invalid_playtest_token":
            stop(reason: Reason.sessionFailed)
            return [.stopped(Reason.sessionFailed)]
        default:
            return refuseKey()
        }
    }

    private mutating func killSwitch() -> [Effect] {
        trackingEnabled = false
        discardQueue()
        return [.trackingDisabled]
    }

    private mutating func refuseKey() -> [Effect] {
        keyRefused = true
        return [.keyRefused]
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

    /// Adds the playtest header (the bare token) when this is a playtest run.
    private func withPlaytest(_ headers: [String: String]) -> [String: String] {
        guard let token = config.playtestToken else { return headers }
        var copy = headers
        copy["X-Ravensight-Playtest"] = token
        return copy
    }

    private func settingsRequest() -> RavensightRequest {
        return RavensightRequest(
            method: "GET",
            url: config.apiUrl + "/settings",
            headers: withPlaytest(["X-API-Key": config.ingestKey])
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
            headers: withPlaytest([
                "Content-Type": "application/json",
                "X-API-Key": config.ingestKey,
            ]),
            body: RavensightCore.encodeJSON(body)
        )
    }

    private func batchRequest(count: Int) -> RavensightRequest {
        let events = pendingEvents.prefix(count).map { $0.payload() }
        return eventsRequest(events: events, token: sessionToken ?? "")
    }

    private func exitRequest(_ exit: PendingExit) -> RavensightRequest {
        let event = RavensightEvent(name: "game_exited", data: [:], timestamp: exit.timestamp)
        return eventsRequest(events: [event.payload()], token: exit.sessionToken)
    }

    private func eventsRequest(events: [[String: Any]], token: String) -> RavensightRequest {
        let body: [String: Any] = ["events": events]
        return RavensightRequest(
            method: "POST",
            url: config.apiUrl + "/track/batch",
            headers: withPlaytest([
                "Content-Type": "application/json",
                "X-Session-Token": token,
            ]),
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
            headers: withPlaytest([
                "Content-Type": "application/json",
                "X-Session-Token": token,
            ]),
            body: RavensightCore.encodeJSON(payload)
        )
    }

    func suggestionsRequest() -> RavensightRequest {
        return RavensightRequest(
            method: "GET",
            url: config.apiUrl + "/agent/suggestions",
            headers: withPlaytest(["X-API-Key": config.ingestKey])
        )
    }

    // MARK: Feedback validation

    /// The six categories the server accepts.
    static let feedbackCategories = ["bug", "suggestion", "complaint", "praise", "playtest", "other"]

    /// The local refusal code for a feedback submission, or nil when it may
    /// be sent. Checked before any request is made.
    static func feedbackRefusal(message: String, category: String?, rating: Int) -> String? {
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "empty_message" }
        if let category = category, !category.isEmpty, !feedbackCategories.contains(category) {
            return "invalid_category"
        }
        if rating != 0 && !(1...5).contains(rating) { return "invalid_rating" }
        return nil
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
