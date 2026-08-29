import Foundation

/// Everything the SDK needs to run. Only the ingest key is required.
public struct RavensightConfiguration {
    /// Your PUBLISHABLE ingest key (gt_live_...). Safe to ship in a client
    /// build: it can only open sessions and read the tracking kill switch. It
    /// cannot read analytics, read feedback or touch your account.
    public var ingestKey: String

    /// Base URL. Leave the default unless you self host. "/api/v1" is
    /// appended when omitted.
    public var apiUrl: String = RavensightClient.defaultApiUrl

    /// Reported to the server as the client's game version. Nil uses the app
    /// bundle's short version string.
    public var gameVersion: String?

    /// Offline queue cap. Oldest events are dropped first once exceeded.
    public var maxQueueSize: Int = 500

    /// Seconds between automatic flushes. 0 flushes only on demand.
    public var flushInterval: TimeInterval = 5

    /// Per request timeout in seconds.
    public var requestTimeout: TimeInterval = 15

    /// Automatically track game_started, game_paused, game_resumed and
    /// game_exited around the app lifecycle.
    public var trackLifecycleEvents: Bool = true

    /// Log SDK activity with print. Off by default.
    public var verboseLogging: Bool = false

    public init(ingestKey: String) {
        self.ingestKey = ingestKey
    }
}

/// Reported by the explicit request helpers (feedback, suggestions).
/// Tracking never throws and never reports errors.
public struct RavensightError: Error, Equatable, CustomStringConvertible {
    /// Stable machine readable code, e.g. "empty_message", "no_session",
    /// "rate_limited", "http_400", "network_error".
    public let code: String
    /// HTTP status of the failing response, or 0 when no request was made or
    /// the transport failed.
    public let status: Int
    /// Human readable summary.
    public let message: String

    public init(code: String, status: Int, message: String) {
        self.code = code
        self.status = status
        self.message = message
    }

    public var description: String {
        return "RavensightError(\(code), status \(status)): \(message)"
    }
}
