import Foundation

/// The Ravensight SDK client. Owns the protocol state machine, the flush
/// timer and the transport.
///
/// Concurrency contract: every public method is non blocking and safe to call
/// from any thread. All state lives on one private serial dispatch queue;
/// calls are forwarded onto it and return immediately. The read only
/// properties (isReady, isTrackingEnabled, isEnabled, queuedEventCount)
/// return a lock protected snapshot that is refreshed after every state
/// change, so they never block on network work. Completion handlers are
/// always delivered on the main queue.
///
/// Most games use the static Ravensight facade instead of holding a client.
public final class RavensightClient {
    public static let defaultApiUrl = RavensightCore.defaultApiUrl
    /// Server hard limit on POST /track/batch.
    public static let maxBatchSize = RavensightCore.maxBatchSize

    private static let deviceIdKey = "ravensight_device_id"

    public let configuration: RavensightConfiguration
    /// Random per install id, persisted in UserDefaults. No hardware
    /// identifier is ever collected.
    public let deviceId: String

    private let workQueue = DispatchQueue(label: "io.ravensight.sdk")
    private let transport: RavensightTransport
    private let now: () -> Int64

    private var core: RavensightCore
    private var started = false
    private var requestInFlight = false
    private var retryWorkItem: DispatchWorkItem?
    private var flushTimer: DispatchSourceTimer?
    private var flushWaiters: [() -> Void] = []
    private var lifecycle: RavensightLifecycle?

    private let snapshotLock = NSLock()
    private var snapshot = Snapshot()

    private struct Snapshot {
        var enabled = true
        var trackingEnabled = true
        var sessionReady = false
        var queuedEventCount = 0
    }

    // MARK: Creation

    public convenience init(configuration: RavensightConfiguration) {
        self.init(
            configuration: configuration,
            transport: RavensightURLSessionTransport(timeout: configuration.requestTimeout),
            now: nil
        )
    }

    /// Internal designated initializer so tests can inject a fake transport
    /// and a fake clock.
    init(configuration: RavensightConfiguration, transport: RavensightTransport, now: (() -> Int64)?) {
        self.configuration = configuration
        self.transport = transport
        self.now = now ?? { Int64(Date().timeIntervalSince1970 * 1000) }
        self.deviceId = RavensightClient.loadOrCreateDeviceId()

        let coreConfig = RavensightCoreConfig(
            ingestKey: configuration.ingestKey,
            apiUrl: configuration.apiUrl,
            gameVersion: configuration.gameVersion ?? RavensightClient.bundleVersion(),
            platform: RavensightClient.platformName(),
            deviceId: deviceId,
            maxQueueSize: configuration.maxQueueSize
        )
        self.core = RavensightCore(config: coreConfig)
        publishSnapshot()
    }

    // MARK: Lifecycle

    /// Boots the SDK: reads the server kill switch, opens a session, starts
    /// the flush timer and hooks the app lifecycle. Safe to call once; later
    /// calls are ignored.
    public func start() {
        workQueue.async {
            guard !self.started else { return }
            self.started = true

            if self.configuration.trackLifecycleEvents {
                self.core.track(name: "game_started", data: [:], nowMs: self.now())
            }
            self.startFlushTimer()
            self.publishSnapshot()
            self.pump()
        }
        DispatchQueue.main.async {
            self.installLifecycleHooks()
        }
    }

    private func installLifecycleHooks() {
        workQueue.async {
            guard self.lifecycle == nil else { return }
            self.lifecycle = RavensightLifecycle(
                client: self,
                trackEvents: self.configuration.trackLifecycleEvents
            )
        }
    }

    private func startFlushTimer() {
        guard configuration.flushInterval > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(
            deadline: .now() + configuration.flushInterval,
            repeating: configuration.flushInterval
        )
        timer.setEventHandler { [weak self] in
            self?.pump()
        }
        timer.resume()
        flushTimer = timer
    }

    // MARK: Public API

    /// Queues an event for delivery. Events are flushed in batches of up to
    /// 50 via POST /api/v1/track/batch as soon as a valid session exists.
    /// Safe to call before start() finishes; events wait in the queue.
    /// Returns false when tracking is off (locally or by the kill switch).
    @discardableResult
    public func track(_ name: String, data: [String: Any]? = nil) -> Bool {
        let current = readSnapshot()
        let active = current.enabled && current.trackingEnabled && !name.isEmpty
        workQueue.async {
            if self.core.track(name: name, data: data, nowMs: self.now()) {
                self.publishSnapshot()
                self.pump()
            }
        }
        return active
    }

    /// Forces an immediate flush attempt of any queued events, bypassing the
    /// backoff window once. The optional completion fires (on the main
    /// queue) when this attempt has finished, whether or not the queue
    /// drained.
    public func flush(completion: (() -> Void)? = nil) {
        workQueue.async {
            if let completion = completion {
                self.flushWaiters.append(completion)
            }
            self.pump(ignoreBackoff: true)
        }
    }

    /// Submits free form player feedback via POST /api/v1/feedback. Requires
    /// a live session: if none exists yet the call fails with code
    /// "no_session" and a session is opened in the background for next time.
    /// The rating is 1 to 5, or 0 to omit it. The completion is delivered on
    /// the main queue.
    public func submitFeedback(
        _ message: String,
        category: String? = nil,
        rating: Int = 0,
        completion: ((Result<Void, RavensightError>) -> Void)? = nil
    ) {
        workQueue.async {
            let finish: (Result<Void, RavensightError>) -> Void = { result in
                if case .failure(let error) = result {
                    self.log("feedback failed: \(error)")
                }
                if let completion = completion {
                    DispatchQueue.main.async { completion(result) }
                }
            }

            guard self.core.isActive else {
                finish(.failure(RavensightError(
                    code: "tracking_disabled", status: 0,
                    message: "tracking is disabled, feedback not sent"
                )))
                return
            }
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                finish(.failure(RavensightError(
                    code: "empty_message", status: 0,
                    message: "feedback message is empty"
                )))
                return
            }
            guard self.core.isSessionValid(nowMs: self.now()), let token = self.core.sessionToken else {
                self.core.markSessionWanted()
                self.pump()
                finish(.failure(RavensightError(
                    code: "no_session", status: 0,
                    message: "no valid session yet, cannot submit feedback"
                )))
                return
            }

            let request = self.core.feedbackRequest(
                message: message, category: category, rating: rating, token: token
            )
            self.transport.send(request) { response in
                self.workQueue.async {
                    if response.status == 201 {
                        self.log("feedback submitted")
                        finish(.success(()))
                        return
                    }
                    if response.status == 401 {
                        // Session expired mid flight; a fresh one is opened
                        // in the background so a retry can succeed.
                        self.core.invalidateSession()
                        self.core.markSessionWanted()
                        self.publishSnapshot()
                        self.pump()
                    }
                    finish(.failure(RavensightError(
                        code: response.errorCode(fallback: self.fallbackCode(response.status)),
                        status: response.status,
                        message: "feedback submission failed (HTTP \(response.status))"
                    )))
                }
            }
        }
    }

    /// EXPERIMENTAL. Fetches AI generated design suggestions for your game
    /// via GET /api/v1/agent/suggestions. Empty until the game has enough
    /// data for a weekly digest, and the shape of each entry may change, so
    /// do not build game logic on it. The completion is delivered on the
    /// main queue.
    public func fetchSuggestions(_ completion: @escaping (Result<[[String: Any]], RavensightError>) -> Void) {
        workQueue.async {
            let request = self.core.suggestionsRequest()
            self.transport.send(request) { response in
                let result: Result<[[String: Any]], RavensightError>
                if response.status == 200 {
                    let object = response.json as? [String: Any]
                    let raw = object?["suggestions"] as? [Any] ?? []
                    result = .success(raw.compactMap { $0 as? [String: Any] })
                } else {
                    result = .failure(RavensightError(
                        code: response.errorCode(fallback: self.fallbackCode(response.status)),
                        status: response.status,
                        message: "fetch suggestions failed (HTTP \(response.status))"
                    ))
                }
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    /// Local opt in and opt out, for a privacy toggle. Disabling stops all
    /// sending and discards anything still queued.
    public func setEnabled(_ enabled: Bool) {
        workQueue.async {
            self.core.setEnabled(enabled)
            self.publishSnapshot()
            if enabled { self.pump() }
        }
    }

    /// True unless setEnabled(false) opted this install out locally.
    public var isEnabled: Bool { return readSnapshot().enabled }

    /// True unless the server side kill switch turned tracking off at boot.
    public var isTrackingEnabled: Bool { return readSnapshot().trackingEnabled }

    /// True once a session exists and events can leave the queue.
    public var isReady: Bool {
        let current = readSnapshot()
        return current.enabled && current.trackingEnabled && current.sessionReady
    }

    /// Events currently waiting in the offline queue.
    public var queuedEventCount: Int { return readSnapshot().queuedEventCount }

    // MARK: Pump (always on workQueue)

    private func pump(ignoreBackoff: Bool = false) {
        guard started else {
            settleFlushWaiters()
            return
        }
        guard !requestInFlight else { return }

        let step = core.nextStep(nowMs: now(), ignoringBackoff: ignoreBackoff)
        switch step {
        case .idle:
            settleFlushWaiters()

        case .wait(let untilMs):
            scheduleRetry(atMs: untilMs)
            settleFlushWaiters()

        case .send(let request, let purpose):
            requestInFlight = true
            transport.send(request) { [weak self] response in
                guard let self = self else { return }
                self.workQueue.async {
                    self.requestInFlight = false
                    let effects = self.core.handle(
                        response: response, for: purpose, nowMs: self.now()
                    )
                    self.report(effects)
                    self.publishSnapshot()
                    self.pump()
                }
            }
        }
    }

    private func scheduleRetry(atMs deadline: Int64) {
        retryWorkItem?.cancel()
        let delayMs = max(deadline - now(), 500)
        let workItem = DispatchWorkItem { [weak self] in
            self?.retryWorkItem = nil
            self?.pump()
        }
        retryWorkItem = workItem
        workQueue.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: workItem)
    }

    private func settleFlushWaiters() {
        guard !flushWaiters.isEmpty else { return }
        let waiters = flushWaiters
        flushWaiters = []
        DispatchQueue.main.async {
            for waiter in waiters { waiter() }
        }
    }

    private func report(_ effects: [RavensightCore.Effect]) {
        for effect in effects {
            switch effect {
            case .trackingDisabled:
                log("tracking disabled by server kill switch")
            case .sessionReady:
                log("session ready")
            case .sessionFailed(let reason):
                log("session creation failed (\(reason)), will retry")
            case .eventsFlushed(let count):
                log("flushed \(count) event(s)")
            case .flushFailed(let reason):
                log("batch flush failed (\(reason)), will retry")
            case .eventDropped(let reason):
                log("dropped one event rejected by the server (\(reason))")
            }
        }
    }

    // MARK: Snapshot

    private func publishSnapshot() {
        let current = Snapshot(
            enabled: core.enabled,
            trackingEnabled: core.trackingEnabled,
            sessionReady: core.isSessionValid(nowMs: now()),
            queuedEventCount: core.pendingEvents.count
        )
        snapshotLock.lock()
        snapshot = current
        snapshotLock.unlock()
    }

    private func readSnapshot() -> Snapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshot
    }

    private func fallbackCode(_ status: Int) -> String {
        return status == 0 ? "network_error" : "http_\(status)"
    }

    private func log(_ message: String) {
        if configuration.verboseLogging {
            print("Ravensight: \(message)")
        }
    }

    // MARK: Environment

    private static func loadOrCreateDeviceId() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: deviceIdKey), !existing.isEmpty {
            return existing
        }
        let created = "dev_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(created, forKey: deviceIdKey)
        return created
    }

    private static func bundleVersion() -> String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String)
            ?? (info?["CFBundleVersion"] as? String)
            ?? "1.0.0"
    }

    private static func platformName() -> String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #elseif os(tvOS)
        return "tvos"
        #elseif os(watchOS)
        return "watchos"
        #else
        return "apple"
        #endif
    }
}
