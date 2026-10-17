import Foundation

/// Everything the SDK needs to run. Only the ingest key is required.
public struct RavensightConfiguration: Sendable {
    /// Your PUBLISHABLE ingest key (gt_live_..., or a gt_pub_... public key
    /// for a build anyone can download). Safe to ship in a client build: it
    /// can open sessions, read the tracking kill switch and read this game's
    /// design suggestions. It cannot read analytics, read feedback or touch
    /// your account. Empty (or only whitespace) makes the SDK inert.
    public var ingestKey: String

    /// True silences the one warning an empty ingestKey prints. Without a key
    /// the SDK is inert either way: nothing stored, no file, no request, no
    /// timer, statusReason "no_key". For a public build whose key is injected
    /// at build time and may be absent.
    public var optional: Bool = false

    /// Whether the player must say yes first. .optOut (the default) collects
    /// until the player opts out. .optIn creates no device id, saves no
    /// queue and makes no request until setTrackingEnabled(true); events
    /// tracked before that yes are dropped, not held.
    public var consent: RavensightConsent = .optOut

    /// A short label for where this build was distributed (for example
    /// "app-store" or "testflight"), sent on POST /session. At most 40
    /// characters with no control characters, surrounding whitespace
    /// trimmed; anything else is ignored with one warning.
    public var distribution: String?

    /// Base URL. Leave the default unless you self host. Whitespace and
    /// trailing slashes are trimmed and "/api/v1" is appended, so the bare
    /// host and the full "/api/v1" form both work. Empty means the default.
    public var apiUrl: String = RavensightClient.defaultApiUrl

    /// The game's runtime switch, default true and never persisted. False
    /// means no request of any kind until setEnabled(true). The player's own
    /// saved choice (Ravensight.setTrackingEnabled) wins over true.
    public var enabled: Bool = true

    /// Reported to the server as the client's game version. Nil uses the app
    /// bundle's short version string.
    public var gameVersion: String?

    /// Offline queue cap. Oldest events are dropped first once exceeded.
    public var maxQueueSize: Int = 500

    /// Keep the queue in a small file under Application Support so events
    /// survive a force quit or a crash. Off by default: the queue then lives
    /// in memory only. At most 500 events are written (the newest), every
    /// write is atomic, the file is read when the client is created, and it
    /// is deleted when the player opts out, on resetDeviceId, on
    /// stopAllTelemetry and on the kill switch. Never used in a synthetic
    /// (playtest) session.
    public var persistQueue: Bool = false

    /// Seconds between automatic flushes. 0 flushes only on demand (and
    /// whenever 50 events are queued, on background and on quit).
    public var flushInterval: TimeInterval = 5

    /// Per request timeout in seconds.
    public var requestTimeout: TimeInterval = 15

    /// Automatically track game_started and game_exited around the app
    /// lifecycle.
    public var trackLifecycleEvents: Bool = true

    /// Also track game_paused when the app leaves the foreground (iOS) or
    /// loses focus (macOS), and game_resumed when it comes back. Off by
    /// default: those were automatic before 0.2.0.
    public var trackPauseEvents: Bool = false

    /// iOS only. Seconds in the background after which the session ends:
    /// game_exited is recorded at the moment the player left, and returning
    /// opens a new session with game_started. Default 1800 (30 minutes).
    public var sessionTimeout: TimeInterval = 1800

    /// Ravensight Playtest token for this run. Nil reads the
    /// RAVENSIGHT_PLAYTEST_TOKEN launch environment variable. Leave both
    /// unset in a build for real players.
    public var playtestToken: String?

    /// Ravensight Playtest run id, required with a token. Nil reads the
    /// RAVENSIGHT_PLAYTEST_RUN_ID launch environment variable.
    public var playtestRunId: String?

    /// Log SDK activity with print. Off by default. A key refusal, the kill
    /// switch and a playtest stop are printed once whatever this says.
    public var verboseLogging: Bool = false

    /// Set by Ravensight.start when stopAllTelemetry() was called before
    /// it: the client starts stopped and deletes the persisted queue, as a
    /// stop made after start would. A configuration with enabled = false
    /// alone keeps the file for a later setEnabled(true).
    var stoppedBeforeStart = false

    public init(ingestKey: String) {
        self.ingestKey = ingestKey
    }
}

/// When collection may start. See RavensightConfiguration.consent.
public enum RavensightConsent: String, Sendable {
    /// Collect until the player opts out with setTrackingEnabled(false). The
    /// default, and the behaviour of every release before 0.4.0.
    case optOut = "opt_out"
    /// Collect nothing until the player opts in with setTrackingEnabled(true).
    /// The yes is saved in UserDefaults under ravensight_optin.
    case optIn = "opt_in"
}

/// Reported by the explicit request helpers (feedback, suggestions).
/// Tracking never throws and never reports errors.
public struct RavensightError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Stable machine readable code, e.g. "disabled", "empty_message",
    /// "invalid_category", "invalid_rating", "no_session", "rate_limited",
    /// "http_400", "network_error".
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
