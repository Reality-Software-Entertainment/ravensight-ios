import Foundation

/// The static facade most games use. Call start once, early, then track from
/// anywhere:
///
///     Ravensight.start(ingestKey: "gt_live_your_key")
///     Ravensight.track("level_completed", data: ["level": 3, "deaths": 2])
///
/// Everything here forwards to a shared RavensightClient. All calls are non
/// blocking and safe from any thread; completion handlers arrive on the main
/// queue. See RavensightClient for the full concurrency contract.
public enum Ravensight {
    private static let lock = NSLock()
    // Both are only touched while holding lock.
    #if compiler(>=5.10)
    nonisolated(unsafe) private static var _shared: RavensightClient?
    /// A runtime setEnabled made before start, for this process only.
    nonisolated(unsafe) private static var pendingEnabled: Bool?
    #else
    private static var _shared: RavensightClient?
    /// A runtime setEnabled made before start, for this process only.
    private static var pendingEnabled: Bool?
    #endif

    /// The shared client, or nil before start() has been called.
    public static var shared: RavensightClient? {
        lock.lock()
        defer { lock.unlock() }
        return _shared
    }

    /// Boots the SDK with a full configuration. Safe to call more than once:
    /// later calls return the existing client without reconfiguring it.
    @discardableResult
    public static func start(_ configuration: RavensightConfiguration) -> RavensightClient {
        return start(configuration, makeClient: RavensightClient.init(configuration:))
    }

    /// The start path with the client construction injectable, for tests.
    static func start(
        _ configuration: RavensightConfiguration,
        makeClient: (RavensightConfiguration) -> RavensightClient
    ) -> RavensightClient {
        lock.lock()
        if let existing = _shared {
            lock.unlock()
            return existing
        }
        var configuration = configuration
        // A setEnabled(false) made before start (the 0.1 privacy toggle)
        // still holds for this process. It is never saved.
        if pendingEnabled == false { configuration.enabled = false }
        pendingEnabled = nil
        let client = makeClient(configuration)
        _shared = client
        lock.unlock()
        client.start()
        return client
    }

    /// Clears the shared client and any pending runtime value. Tests only.
    static func resetForTesting() {
        lock.lock()
        _shared = nil
        pendingEnabled = nil
        lock.unlock()
    }

    /// Boots the SDK with just an ingest key. Only pass apiUrl if you self
    /// host; gameVersion defaults to the app bundle's version.
    @discardableResult
    public static func start(
        ingestKey: String,
        apiUrl: String? = nil,
        gameVersion: String? = nil
    ) -> RavensightClient {
        var configuration = RavensightConfiguration(ingestKey: ingestKey)
        if let apiUrl = apiUrl { configuration.apiUrl = apiUrl }
        if let gameVersion = gameVersion { configuration.gameVersion = gameVersion }
        return start(configuration)
    }

    /// Queues an event. Returns false when tracking is off or the SDK has
    /// not been started.
    @discardableResult
    public static func track(_ name: String, data: [String: Any]? = nil) -> Bool {
        guard let client = shared else { return false }
        return client.track(name, data: data)
    }

    /// Sends queued events now, bypassing the backoff window once.
    public static func flush(completion: (() -> Void)? = nil) {
        guard let client = shared else {
            if let completion = completion { DispatchQueue.main.async(execute: completion) }
            return
        }
        client.flush(completion: completion)
    }

    /// Posts player feedback. The category is one of feedbackCategories;
    /// the rating is 1 to 5, or 0 to omit it.
    public static func submitFeedback(
        _ message: String,
        category: String? = nil,
        rating: Int = 0,
        completion: ((Result<Void, RavensightError>) -> Void)? = nil
    ) {
        guard let client = shared else {
            if let completion = completion {
                DispatchQueue.main.async {
                    completion(.failure(RavensightError(
                        code: "not_started", status: 0,
                        message: "call Ravensight.start before submitting feedback"
                    )))
                }
            }
            return
        }
        client.submitFeedback(message, category: category, rating: rating, completion: completion)
    }

    /// EXPERIMENTAL. AI generated design suggestions for your game. An
    /// empty list while tracking is off.
    public static func fetchSuggestions(_ completion: @escaping (Result<[[String: Any]], RavensightError>) -> Void) {
        guard let client = shared else {
            DispatchQueue.main.async {
                completion(.failure(RavensightError(
                    code: "not_started", status: 0,
                    message: "call Ravensight.start before fetching suggestions"
                )))
            }
            return
        }
        client.fetchSuggestions(completion)
    }

    /// The player's choice, for a privacy toggle. Saved to UserDefaults
    /// before this returns, and safe to call before start(): the client
    /// reads it when it is created, and a saved opt-out wins over
    /// configuration.enabled. Turning off clears the queue and stops sending.
    public static func setTrackingEnabled(_ enabled: Bool) {
        if let client = shared {
            client.setTrackingEnabled(enabled)
        } else if launchedForPlaytest {
            print("Ravensight: setTrackingEnabled is ignored during a playtest run")
        } else {
            RavensightClient.saveTrackingEnabled(enabled, defaults: .standard)
        }
    }

    /// True when the player opted out with setTrackingEnabled(false). Reads
    /// the saved choice when the SDK has not been started.
    public static var isOptedOut: Bool {
        if let client = shared { return client.isOptedOut }
        return UserDefaults.standard.bool(forKey: RavensightClient.optOutKey)
    }

    /// Forgets this install's analytics identity and returns the new device
    /// id. See RavensightClient.resetDeviceId. Before start() it saves a
    /// fresh id for the client to pick up.
    @discardableResult
    public static func resetDeviceId() -> String {
        if let client = shared { return client.resetDeviceId() }
        if launchedForPlaytest {
            print("Ravensight: resetDeviceId is ignored during a playtest run")
            return ""
        }
        let fresh = RavensightClient.mintDeviceId()
        UserDefaults.standard.set(fresh, forKey: RavensightClient.deviceIdKey)
        UserDefaults.standard.removeObject(forKey: RavensightClient.markerKey)
        return fresh
    }

    /// The runtime switch on the shared client, not the player's choice.
    /// Before 0.2.0 this was the documented privacy toggle; it is not saved,
    /// so use setTrackingEnabled for a player's opt-out.
    @available(*, deprecated, message: "Use Ravensight.setTrackingEnabled(_:) for the player's choice, or Ravensight.shared?.setEnabled(_:) for a runtime switch.")
    public static func setEnabled(_ enabled: Bool) {
        lock.lock()
        let client = _shared
        if client == nil { pendingEnabled = enabled }
        lock.unlock()
        if let client = client {
            client.setEnabled(enabled)
        } else {
            // Held until start() for this process only, never saved.
            print("Ravensight: setEnabled(_:) is deprecated and not saved; use Ravensight.setTrackingEnabled(_:) for the player's choice.")
        }
    }

    /// True when the launch environment carries a playtest token, for the
    /// calls made before start().
    private static var launchedForPlaytest: Bool {
        let token = ProcessInfo.processInfo.environment["RAVENSIGHT_PLAYTEST_TOKEN"] ?? ""
        return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The feedback categories the server accepts.
    public static let feedbackCategories = RavensightClient.feedbackCategories

    /// This SDK's version.
    public static let sdkVersion = RavensightClient.sdkVersion

    /// True once a session exists and events can leave the queue.
    public static var isReady: Bool {
        return shared?.isReady ?? false
    }

    /// Why the shared client is not sending, or nil when it is ready (or not
    /// started). See RavensightClient.statusReason for the values.
    public static var statusReason: String? {
        return shared?.statusReason
    }

    /// The current session token, nil until a session opens. Pass it to your
    /// game server as joinToken.
    public static var sessionToken: String? {
        return shared?.sessionToken
    }
}
