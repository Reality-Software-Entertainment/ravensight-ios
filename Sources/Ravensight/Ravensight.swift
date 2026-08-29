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
    private static var _shared: RavensightClient?

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
        lock.lock()
        if let existing = _shared {
            lock.unlock()
            return existing
        }
        let client = RavensightClient(configuration: configuration)
        _shared = client
        lock.unlock()
        client.start()
        return client
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

    /// Posts player feedback. The rating is 1 to 5, or 0 to omit it.
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

    /// EXPERIMENTAL. AI generated design suggestions for your game.
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

    /// Local opt in and opt out for a privacy toggle. Disabling discards
    /// anything still queued.
    public static func setEnabled(_ enabled: Bool) {
        shared?.setEnabled(enabled)
    }

    /// True once a session exists and events can leave the queue.
    public static var isReady: Bool {
        return shared?.isReady ?? false
    }
}
