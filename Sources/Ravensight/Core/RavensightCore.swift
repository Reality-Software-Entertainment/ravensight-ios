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
    /// A validated distribution label sent on POST /session, or nil.
    var distribution: String?
    /// Mints every event's rs_event_id. Shared with the client, which stamps
    /// ids on the caller's thread.
    var eventIds: RavensightEventIds

    init(
        ingestKey: String,
        apiUrl: String = RavensightCore.defaultApiUrl,
        gameVersion: String = "1.0.0",
        platform: String = "apple",
        deviceId: String,
        maxQueueSize: Int = RavensightCore.defaultQueueCap,
        playtestToken: String? = nil,
        distribution: String? = nil,
        eventIds: RavensightEventIds? = nil
    ) {
        self.ingestKey = ingestKey
        self.apiUrl = RavensightCore.normalizeApiUrl(apiUrl)
        self.gameVersion = gameVersion
        self.platform = platform
        self.deviceId = deviceId
        self.maxQueueSize = maxQueueSize > 0 ? maxQueueSize : RavensightCore.defaultQueueCap
        self.playtestToken = (playtestToken?.isEmpty ?? true) ? nil : playtestToken
        self.distribution = RavensightCore.validDistribution(distribution)
        self.eventIds = eventIds ?? RavensightEventIds(deviceId: deviceId, startSec: 0)
    }
}

/// Counters for one run. accepted counts queue acceptance (what track
/// returns), sent counts events the server answered 202 for.
struct RavensightCoreStats {
    /// Events accepted into the queue this run.
    var accepted = 0
    /// Events the server accepted (202) this run.
    var sent = 0
    /// Events that left the queue without being delivered: pushed out by
    /// the cap, refused on their own with a 400, or discarded by an
    /// opt-out, a stop, a reset or the kill switch.
    var dropped = 0
    var flushes = 0
    var sessions = 0
    /// Events loaded from the persisted queue at launch.
    var restored = 0
    /// Events waiting now, restored ones included.
    var pending = 0
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
    /// Retry waits without a Retry-After vary by this fraction either way,
    /// so many clients that failed together do not retry together.
    static let backoffJitter = 0.2
    static let minRetryMs: Int64 = 500
    /// An event whose data is larger than this as JSON is dropped before it
    /// is queued, never sent.
    static let maxEventBytes = 8192
    /// The longest distribution label the server accepts.
    static let maxDistributionLength = 40
    /// The key every event's data carries for deduplication.
    static let eventIdKey = "rs_event_id"

    /// The startup outcome vocabulary, shared with every Ravensight SDK.
    enum Reason {
        /// No ingest key: the client is inert for the run.
        static let noKey = "no_key"
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
        /// Events restored from the persisted queue, sent under the session
        /// they were queued in while that session is still valid.
        case restored(count: Int)
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

    /// Events restored from disk that belong to an earlier, unexpired
    /// session, sent under that session's token before the live queue.
    struct RestoredBatch {
        var sessionToken: String
        /// Unix milliseconds.
        var expiresAtMs: Int64
        var events: [RavensightEvent]
    }

    /// A game_exited waiting to go out under a session that has ended.
    struct PendingExit: Equatable {
        var sessionToken: String
        /// Unix seconds: when the player left.
        var timestamp: Int64
        var retry: Bool
        /// The exit's rs_event_id, assigned by setPendingExit when empty, so
        /// a retried exit carries the same id.
        var eventId: String = ""
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

    private(set) var pendingEvents: [RavensightEvent] = [] {
        didSet { queueRevision &+= 1 }
    }
    private(set) var restoredBatch: RestoredBatch? {
        didSet { queueRevision &+= 1 }
    }
    private(set) var pendingExit: PendingExit?
    /// Bumped on every change to the queued events, so a driver that mirrors
    /// the queue to disk knows when to write.
    private(set) var queueRevision = 0

    private(set) var backoffMs = RavensightCore.defaultRetryMs
    private(set) var nextAttemptAtMs: Int64 = 0
    /// Shrinks below maxBatchSize while splitting an oversize batch on 400.
    private(set) var batchLimit = RavensightCore.maxBatchSize
    private(set) var consecutiveUnauthorized = 0

    /// Bumped whenever the queue is discarded (opt-out, disable, reset,
    /// kill switch, stop). A batch answer from before the bump is stale.
    private(set) var queueGeneration = 0
    /// Bumped whenever the session is dropped. A session answer from before
    /// the bump belongs to a session (or identity) that no longer applies.
    private(set) var sessionGeneration = 0

    /// What a response is checked against, captured when its request left.
    struct Stamp: Equatable {
        var queue: Int
        var session: Int
        var exit: PendingExit?
    }

    var stamp: Stamp {
        return Stamp(queue: queueGeneration, session: sessionGeneration, exit: pendingExit)
    }

    /// True when a response no longer applies to the current state: a batch
    /// sent before the queue was discarded, a session opened before the
    /// session (or the device id) was dropped, or an exit that was replaced.
    /// The driver drops such a response instead of handling it.
    func isStale(_ purpose: Purpose, since sent: Stamp) -> Bool {
        switch purpose {
        case .settings:
            return false
        case .session:
            return sent.session != sessionGeneration
        case .batch, .restored:
            return sent.queue != queueGeneration
        case .exit:
            return sent.exit != pendingExit
        }
    }

    private var counters = RavensightCoreStats()

    /// 0 <= x < 1, for the backoff jitter. Tests fix it; 0.5 is no jitter.
    var random: () -> Double = { Double.random(in: 0..<1) }

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
        copy.pending = pendingCount
        return copy
    }

    /// Events waiting to be sent: the live queue plus any restored batch.
    var pendingCount: Int {
        return pendingEvents.count + (restoredBatch?.events.count ?? 0)
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
    ///
    /// Every queued event's data carries an rs_event_id. eventId is one the
    /// client already stamped into data (and measured) on the caller's
    /// thread; nil mints one here and checks the size here. An event whose
    /// data is over maxEventBytes as JSON is dropped (counted) and never sent.
    @discardableResult
    mutating func track(
        name: String,
        data: [String: Any]?,
        nowMs: Int64,
        atSec: Int64? = nil,
        eventId: String? = nil
    ) -> Bool {
        guard canQueue, !name.isEmpty else { return false }

        var payload: [String: Any]
        if let eventId = eventId {
            payload = data ?? [:]
            payload[RavensightCore.eventIdKey] = eventId
        } else {
            payload = RavensightCore.sanitizeJSON(data ?? [:]) as? [String: Any] ?? [:]
            payload[RavensightCore.eventIdKey] = config.eventIds.next()
            if RavensightCore.eventBytes(payload) > RavensightCore.maxEventBytes {
                counters.dropped += 1
                return false
            }
        }

        while pendingEvents.count >= config.maxQueueSize {
            pendingEvents.removeFirst() // drop oldest so the newest always survive
            counters.dropped += 1
        }
        pendingEvents.append(RavensightEvent(
            name: name,
            data: payload,
            timestamp: atSec ?? nowMs / 1000
        ))
        counters.accepted += 1
        return true
    }

    /// Puts events loaded from the persisted queue back. Events that were
    /// queued under a session that is still valid go out under that session
    /// first; the rest join the front of the live queue and are sent under
    /// the next session. The cap still applies, oldest dropped first.
    mutating func restore(
        events: [RavensightEvent],
        sessionToken: String?,
        expiresAtMs: Int64,
        nowMs: Int64
    ) {
        guard canQueue, !events.isEmpty else { return }
        // Events saved by 0.3 have no rs_event_id; they get one now, and
        // keep it from here on. Saved ids are never replaced.
        var kept = events.map { event -> RavensightEvent in
            guard event.data[RavensightCore.eventIdKey] == nil else { return event }
            var stamped = event
            stamped.data[RavensightCore.eventIdKey] = config.eventIds.next()
            return stamped
        }
        if kept.count > config.maxQueueSize {
            counters.dropped += kept.count - config.maxQueueSize
            kept = Array(kept.suffix(config.maxQueueSize))
        }
        counters.restored += kept.count
        if let token = sessionToken, !token.isEmpty,
           nowMs < expiresAtMs - RavensightCore.sessionExpirySkewMs {
            if let existing = restoredBatch, existing.sessionToken == token {
                restoredBatch?.events = existing.events + kept
            } else {
                restoredBatch = RestoredBatch(sessionToken: token, expiresAtMs: expiresAtMs, events: kept)
            }
        } else {
            pendingEvents.insert(contentsOf: kept, at: 0)
            while pendingEvents.count > config.maxQueueSize {
                pendingEvents.removeFirst()
                counters.dropped += 1
            }
        }
    }

    /// Counts events dropped before they reached the queue (the persisted
    /// file's age limit or cap).
    mutating func countDropped(_ count: Int) {
        counters.dropped += max(0, count)
    }

    /// Moves a restored batch into the front of the live queue (its session
    /// is gone), keeping the cap.
    private mutating func demoteRestoredBatch() {
        guard let batch = restoredBatch else { return }
        restoredBatch = nil
        pendingEvents.insert(contentsOf: batch.events, at: 0)
        while pendingEvents.count > config.maxQueueSize {
            pendingEvents.removeFirst()
            counters.dropped += 1
        }
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
        config.eventIds.setDeviceId(deviceId)
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
        sessionGeneration += 1
        sessionToken = nil
        sessionExpiresAtMs = 0
    }

    /// Queue the game_exited of a session that has ended, to be sent under
    /// that session's own token before anything else.
    mutating func setPendingExit(_ exit: PendingExit) {
        guard enabled, !optedOut, stopReason == nil, !exit.sessionToken.isEmpty else { return }
        var stamped = exit
        if stamped.eventId.isEmpty { stamped.eventId = config.eventIds.next() }
        pendingExit = stamped
    }

    private mutating func discardQueue() {
        queueGeneration += 1
        counters.dropped += pendingCount
        pendingEvents.removeAll()
        restoredBatch = nil
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
            if !ignoringBackoff && nowMs < nextAttemptAtMs {
                return .wait(untilMs: nextAttemptAtMs)
            }
            return .send(settingsRequest(), .settings)
        }
        guard trackingEnabled else { return .idle }

        if let batch = restoredBatch {
            if !ignoringBackoff && nowMs < nextAttemptAtMs {
                return .wait(untilMs: nextAttemptAtMs)
            }
            let count = min(batchLimit, batch.events.count)
            let events = batch.events.prefix(count).map { $0.payload() }
            return .send(eventsRequest(events: events, token: batch.sessionToken), .restored(count: count))
        }

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
            return handleSettings(response, nowMs: nowMs)
        case .session:
            return handleSession(response, nowMs: nowMs)
        case .batch(let count):
            return handleBatch(response, count: count, nowMs: nowMs)
        case .exit(let retry):
            return handleExit(response, retry: retry, nowMs: nowMs)
        case .restored(let count):
            return handleRestored(response, count: count, nowMs: nowMs)
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

    private mutating func handleSettings(_ response: RavensightResponse, nowMs: Int64) -> [Effect] {
        if response.status == 429 || response.status == 503 {
            // Ask again once Retry-After has passed, like every other endpoint.
            applyRetryAfter(response, nowMs: nowMs)
            if response.status == 429 { lastFailure = Reason.rateLimited }
            return []
        }
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
            return refuseKeyForRun()
        case 403:
            return handleForbidden(response, endsRun: true)
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
            return refuseKeyForRun()
        case 403:
            return handleForbidden(response, endsRun: true)
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

    private mutating func handleRestored(_ response: RavensightResponse, count: Int, nowMs: Int64) -> [Effect] {
        guard var batch = restoredBatch else { return [] }
        switch response.status {
        case 202:
            let removed = min(count, batch.events.count)
            batch.events.removeFirst(removed)
            restoredBatch = batch.events.isEmpty ? nil : batch
            counters.sent += removed
            counters.flushes += 1
            batchLimit = RavensightCore.maxBatchSize
            lastFailure = nil
            resetBackoff()
            return [.eventsFlushed(removed)]
        case 401, 400:
            // The old session is gone (401), or the batch needs splitting
            // (400): either way the live queue's own handling takes over,
            // under the current session.
            demoteRestoredBatch()
            return []
        case 403:
            let code = response.errorCode(fallback: "")
            if code == "tracking_disabled" || code == "playtest_job_closed" || code == "invalid_playtest_token" {
                return handleForbidden(response)
            }
            // Any other 403 here is about the old session, not the key.
            demoteRestoredBatch()
            return []
        case 429, 503:
            applyRetryAfter(response, nowMs: nowMs)
            if response.status == 429 { lastFailure = Reason.rateLimited }
            return [.flushFailed(response.errorCode(fallback: response.status == 429 ? "rate_limited" : "http_503"))]
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
    /// playtest token, or otherwise a refused key. endsRun is set for the
    /// settings check and the session open, where a refused key ends the run.
    private mutating func handleForbidden(_ response: RavensightResponse, endsRun: Bool = false) -> [Effect] {
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
            return endsRun ? refuseKeyForRun() : refuseKey()
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

    /// The key was refused by the settings check or the session open (401,
    /// or a 403 that is not the kill switch or a playtest refusal): retrying
    /// cannot help, so the run ends. The queue is cleared, nothing is retried
    /// (an explicit flush included) and nothing is left to save at quit.
    private mutating func refuseKeyForRun() -> [Effect] {
        keyRefused = true
        stop(reason: Reason.invalidKey)
        return [.keyRefused]
    }

    // MARK: Backoff

    private mutating func resetBackoff() {
        backoffMs = RavensightCore.defaultRetryMs
        nextAttemptAtMs = 0
    }

    /// The current backoff with plus or minus 20 percent jitter, never more
    /// than the 5 minute ceiling and never less than half a second. A
    /// Retry-After is obeyed exactly instead (applyRetryAfter).
    private mutating func scheduleBackoff(nowMs: Int64) {
        let roll = min(max(random(), 0), 1)
        let factor = 1 - RavensightCore.backoffJitter + 2 * RavensightCore.backoffJitter * roll
        let jittered = min(Int64((Double(backoffMs) * factor).rounded()), RavensightCore.maxBackoffMs)
        nextAttemptAtMs = nowMs + max(jittered, RavensightCore.minRetryMs)
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
        var body: [String: Any] = [
            "deviceId": config.deviceId,
            "gameVersion": config.gameVersion,
            "platform": config.platform,
        ]
        if let distribution = config.distribution { body["distribution"] = distribution }
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
        let data: [String: Any] = exit.eventId.isEmpty ? [:] : [RavensightCore.eventIdKey: exit.eventId]
        let event = RavensightEvent(name: "game_exited", data: data, timestamp: exit.timestamp)
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

    /// A Player Reports request (POST /reports, /reports/:id/upload,
    /// /reports/:id/finalize, GET /reports/:id) under the session token.
    func reportRequest(method: String, path: String, body: [String: Any]?, token: String) -> RavensightRequest {
        var headers = ["X-Session-Token": token]
        if body != nil { headers["Content-Type"] = "application/json" }
        return RavensightRequest(
            method: method,
            url: config.apiUrl + "/reports" + path,
            headers: withPlaytest(headers),
            body: body.map { RavensightCore.encodeJSON($0) }
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

    /// The size of an event's data as JSON, in UTF-8 bytes, the way the
    /// server measures it (slashes are not escaped). Unencodable data counts
    /// as too large.
    static func eventBytes(_ data: [String: Any]) -> Int {
        guard JSONSerialization.isValidJSONObject(data),
              let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.withoutEscapingSlashes]) else {
            return Int.max
        }
        return encoded.count
    }

    /// A distribution label the server will take: trimmed, 1 to 40
    /// characters, no control characters. Anything else is nil.
    static func validDistribution(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        guard trimmed.utf16.count <= maxDistributionLength else { return nil }
        let hasControl = trimmed.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
        return hasControl ? nil : trimmed
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
