import Foundation

/// What happened to the last request that carried events.
public enum RavensightDeliveryResult: Equatable, Sendable {
    /// The server accepted the batch (202).
    case accepted
    /// The server answered with this HTTP status: the session could not be
    /// opened, or the batch was refused or deferred (401, 403, 429, 5xx,
    /// 400). Events are kept unless the status says otherwise.
    case failed(status: Int)
    /// No answer: no connection, DNS failure or timeout. Events are kept.
    case offline
}

/// The last delivery attempt and when it finished.
public struct RavensightDelivery: Equatable, Sendable {
    public let result: RavensightDeliveryResult
    public let timestamp: Date

    public init(result: RavensightDeliveryResult, timestamp: Date) {
        self.result = result
        self.timestamp = timestamp
    }
}

/// One delivery attempt, reported to onFlush on the main queue. Sent once per
/// request that carried events (a batch), and once per failed session open
/// that held queued events back.
public struct RavensightFlushOutcome: Equatable, Sendable {
    /// Events the server accepted in this request. 0 unless status is 202.
    public let sent: Int
    /// HTTP status, or 0 when there was no answer (offline).
    public let status: Int
    /// The server's error code (or "network_error", "http_<status>"), nil on
    /// success.
    public let error: String?
    /// Events still waiting after this attempt.
    public let pending: Int

    public init(sent: Int, status: Int, error: String?, pending: Int) {
        self.sent = sent
        self.status = status
        self.error = error
        self.pending = pending
    }

    public var succeeded: Bool { return status == 202 }
}

/// Counters for this run. track() returning true means "queued"; only
/// "delivered" means the server has the event.
public struct RavensightStats: Equatable, Sendable {
    /// Events accepted into the queue this run (each track() that returned
    /// true and was taken).
    public let queued: Int
    /// Events the server accepted (202) this run.
    public let delivered: Int
    /// Events waiting to be sent now, restored ones included.
    public let pending: Int
    /// Events that left the queue undelivered this run: pushed out by the
    /// queue cap, refused on their own by the server (400), or discarded by
    /// an opt-out, stopAllTelemetry, resetDeviceId, the kill switch or a
    /// playtest stop.
    public let droppedEvents: Int
    /// Events loaded from the persisted queue at launch (persistQueue).
    public let restored: Int
    /// Successful batch requests this run.
    public let flushes: Int
    /// Sessions opened this run.
    public let sessions: Int
    /// The last delivery attempt, nil before the first one.
    public let lastDelivery: RavensightDelivery?

    public init(
        queued: Int = 0, delivered: Int = 0, pending: Int = 0, droppedEvents: Int = 0,
        restored: Int = 0, flushes: Int = 0, sessions: Int = 0, lastDelivery: RavensightDelivery? = nil
    ) {
        self.queued = queued
        self.delivered = delivered
        self.pending = pending
        self.droppedEvents = droppedEvents
        self.restored = restored
        self.flushes = flushes
        self.sessions = sessions
        self.lastDelivery = lastDelivery
    }
}
