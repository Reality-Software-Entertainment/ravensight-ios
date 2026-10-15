import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// The Ravensight SDK client. Owns the protocol state machine, the flush
/// timer and the transport.
///
/// Concurrency contract: every public method is non blocking and safe to call
/// from any thread. All state lives on one private serial dispatch queue;
/// calls are forwarded onto it and return immediately. The read only
/// properties (isReady, isTrackingEnabled, isEnabled, isOptedOut,
/// statusReason, sessionToken, deviceId, queuedEventCount) return a lock
/// protected snapshot that is refreshed after every state change, so they
/// never block on network work. Completion handlers and onStatusChange are
/// always delivered on the main queue.
///
/// Most games use the static Ravensight facade instead of holding a client.
///
/// Sendable by construction rather than by the compiler's proof: mutable
/// state is only touched on workQueue (a serial queue), the snapshot and the
/// status handler only under snapshotLock, and the lifecycle observer only
/// on the main thread. That is why it is marked @unchecked.
public final class RavensightClient: @unchecked Sendable {
    /// This SDK's version.
    public static let sdkVersion = "0.3.0"
    /// The default host. "/api/v1" is appended for you.
    public static let defaultApiUrl = RavensightCore.defaultApiUrl
    /// Server hard limit on POST /track/batch.
    public static let maxBatchSize = RavensightCore.maxBatchSize
    /// The feedback categories the server accepts.
    public static let feedbackCategories = RavensightCore.feedbackCategories

    static let deviceIdKey = "ravensight_device_id"
    static let optOutKey = "ravensight_tracking_opt_out"
    static let markerKey = "ravensight_background_marker"
    /// The longest a quit is held for the final flush.
    static let quitHoldSeconds: TimeInterval = 1.5

    public let configuration: RavensightConfiguration
    /// True when a Ravensight Playtest token was found at construction.
    public let isPlaytest: Bool

    /// True for a synthetic session: a Ravensight Playtest run driven by an
    /// agent, not a person. Same value as isPlaytest.
    public var isSynthetic: Bool { return isPlaytest }

    /// The id this run sends while it is a synthetic session (pt-<runId>),
    /// nil in a normal session. It lives in memory only and is never saved,
    /// and deviceId never returns it.
    public let playtestDeviceId: String?

    let workQueue = DispatchQueue(label: "io.ravensight.sdk")
    let transport: RavensightTransport
    let now: () -> Int64
    private let defaults: UserDefaults
    private let isBackgroundLaunch: () -> Bool
    private let installsLifecycleObservers: Bool

    var core: RavensightCore
    private var started = false
    /// False until the app has been in the foreground once since start().
    private var foreground = false
    private var deferredStart = false
    private var startedQueued = false
    private var exitedQueued = false
    private var backgroundedAtMs: Int64?
    private var requestInFlight = false
    private var retryWorkItem: DispatchWorkItem?
    private var flushTimer: DispatchSourceTimer?
    private var flushWaiters: [Waiter] = []
    /// Created and read on the main thread only.
    private var lifecycle: RavensightLifecycle?
    private var warned: Set<String> = []
    private var lastNotifiedReason: String?

    /// The persisted queue, nil unless persistQueue is on in a normal session.
    private let queueStore: RavensightQueueStore?
    /// Where this key's queue file lives (or would), whatever persistQueue
    /// says, so an opt-out or a reset can delete one left by an earlier
    /// launch.
    private let queueFileURL: URL?
    /// Seconds a queue write waits so a burst of changes becomes one write.
    /// Background, quit and anything that empties the queue write at once.
    var persistDelay: TimeInterval = 0.25
    private var persistScheduled = false
    /// Queue file writes this run. Tests read it.
    private(set) var queueWrites = 0
    /// Called on the work queue after each queue file write. Tests set it to
    /// wait for the write itself instead of sleeping.
    var onQueueWrite: (() -> Void)?
    /// True while the saved queue is still on disk waiting to be loaded (the
    /// client was built disabled).
    private var restoreDue = false
    private var persistedRevision = -1
    private var persistedSessionToken: String?
    private var lastDeliveryRecord: RavensightDelivery?

    /// Seconds a report waits for a session to open, and between status
    /// checks while a screenshot is processed. Tests shorten them.
    var reportSessionWait: TimeInterval = 10
    var reportPollInterval: TimeInterval = 2
    var reportPollAttempts = 35

    private let snapshotLock = NSLock()
    private var snapshot = Snapshot()
    private var statusHandler: ((String?) -> Void)?
    private var flushHandler: ((RavensightFlushOutcome) -> Void)?

    private struct Snapshot {
        var enabled = true
        var optedOut = false
        var trackingEnabled = true
        var sessionReady = false
        var sessionToken: String?
        var queuedEventCount = 0
        var reason: String?
        /// The durable id. Never a synthetic one.
        var deviceId = ""
        var stats = RavensightStats()
    }

    private struct Waiter {
        var callback: () -> Void
        var onMain: Bool
    }

    // MARK: Creation

    public convenience init(configuration: RavensightConfiguration) {
        self.init(
            configuration: configuration,
            transport: RavensightURLSessionTransport(timeout: configuration.requestTimeout),
            now: nil
        )
    }

    /// Internal designated initializer so tests can inject a fake transport,
    /// a fake clock, their own storage and launch environment, and a fake
    /// answer to "was this a background launch".
    init(
        configuration: RavensightConfiguration,
        transport: RavensightTransport,
        now: (() -> Int64)?,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isBackgroundLaunch: (() -> Bool)? = nil,
        installsLifecycleObservers: Bool = true,
        queueDirectory: URL? = nil
    ) {
        self.configuration = configuration
        self.transport = transport
        self.now = now ?? { Int64(Date().timeIntervalSince1970 * 1000) }
        self.defaults = defaults
        self.isBackgroundLaunch = isBackgroundLaunch ?? RavensightClient.launchedInBackground
        self.installsLifecycleObservers = installsLifecycleObservers

        let token = RavensightClient.firstNonEmpty(
            configuration.playtestToken, environment["RAVENSIGHT_PLAYTEST_TOKEN"]
        )
        let runId = RavensightClient.firstNonEmpty(
            configuration.playtestRunId, environment["RAVENSIGHT_PLAYTEST_RUN_ID"]
        )
        self.isPlaytest = token != nil

        // A synthetic (playtest) run sends pt-<runId>, held in memory only:
        // it never writes the saved id and ignores the saved opt-out. The
        // durable id is read (never created or replaced) so deviceId can
        // keep reporting it to the app.
        let deviceId: String
        let durableId: String
        let optedOut: Bool
        if token != nil {
            deviceId = runId.map { "pt-" + $0 } ?? ""
            durableId = defaults.string(forKey: RavensightClient.deviceIdKey) ?? ""
            optedOut = false
            self.playtestDeviceId = deviceId
        } else {
            deviceId = RavensightClient.loadOrCreateDeviceId(defaults)
            durableId = deviceId
            optedOut = defaults.bool(forKey: RavensightClient.optOutKey)
            self.playtestDeviceId = nil
        }
        self.queueFileURL = RavensightQueueStore.defaultFileURL(
            ingestKey: configuration.ingestKey, directory: queueDirectory
        )
        if configuration.persistQueue && token == nil {
            self.queueStore = queueFileURL.map(RavensightQueueStore.init(fileURL:))
        } else {
            self.queueStore = nil
        }

        let coreConfig = RavensightCoreConfig(
            ingestKey: configuration.ingestKey,
            apiUrl: configuration.apiUrl,
            gameVersion: configuration.gameVersion ?? RavensightClient.bundleVersion(),
            platform: RavensightClient.platformName(),
            deviceId: deviceId,
            maxQueueSize: configuration.maxQueueSize,
            playtestToken: token
        )
        var core = RavensightCore(config: coreConfig)
        // The opt-out is applied before anything can be queued or sent.
        core.setEnabled(configuration.enabled)
        core.setOptedOut(optedOut)
        if token != nil && runId == nil {
            core.stop(reason: RavensightCore.Reason.sessionFailed)
        }
        self.core = core
        self.snapshot.deviceId = durableId
        self.persistedRevision = self.core.queueRevision
        self.lastNotifiedReason = self.core.statusReason
        if token != nil && runId == nil {
            warnOnce(
                "playtest_no_run",
                "a playtest token was found without a run id (session_failed), nothing is sent this run. Set RAVENSIGHT_PLAYTEST_RUN_ID too."
            )
        }
        publishSnapshot()

        // File work happens on the work queue, never on the caller's thread
        // (start() may hold the facade's lock while this runs).
        let persist = configuration.persistQueue
        let synthetic = token != nil
        let stoppedBeforeStart = configuration.stoppedBeforeStart
        workQueue.async {
            if synthetic { return } // a synthetic run never touches the file
            if optedOut || !persist || stoppedBeforeStart {
                // A stop made before start() (Ravensight.stopAllTelemetry)
                // keeps nothing either, like a stop made after it.
                // The player said no, or the game no longer persists: an
                // earlier launch's events are not kept.
                self.deleteQueueFile()
                return
            }
            self.restoreDue = true
            self.restoreQueueIfDue()
            self.persistedRevision = self.core.queueRevision
            self.stateChanged()
        }
    }

    deinit {
        flushTimer?.cancel()
        retryWorkItem?.cancel()
    }

    /// Loads the persisted queue once events may be queued. Called from the
    /// initializer and again when a client built disabled is enabled.
    private func restoreQueueIfDue() {
        guard restoreDue, let store = queueStore, core.canQueue else { return }
        restoreDue = false
        let nowMs = now()
        let loaded = store.load(nowMs: nowMs)
        if loaded.dropped > 0 { core.countDropped(loaded.dropped) }
        for group in loaded.groups {
            core.restore(
                events: group.events,
                sessionToken: group.sessionToken,
                expiresAtMs: group.expiresAtMs,
                nowMs: nowMs
            )
        }
        if core.stats.restored > 0 {
            log("restored \(core.stats.restored) event(s) from the persisted queue")
        }
        if loaded.dropped > 0 {
            // Rewrite now (or delete, if nothing was kept) so the next launch
            // does not find and count the same dropped events again.
            persistedRevision = -1
            writeQueueNow()
        }
    }

    /// Deletes this key's queue file and forgets any load still due. Work
    /// queue only.
    private func deleteQueueFile() {
        restoreDue = false
        persistScheduled = false
        if let url = queueFileURL { try? FileManager.default.removeItem(at: url) }
        persistedRevision = core.queueRevision
        persistedSessionToken = nil
    }

    /// Mirrors the queue to disk when it, or the session it would be sent
    /// under, changed: at once when the queue is empty (the file is deleted)
    /// or immediate is set, otherwise coalesced over persistDelay. Work queue
    /// only.
    private func persistQueueIfChanged(immediate: Bool = false) {
        guard queueStore != nil, !restoreDue else { return }
        if immediate || core.pendingCount == 0 || persistDelay <= 0 {
            writeQueueNow()
            return
        }
        guard !persistScheduled else { return }
        persistScheduled = true
        workQueue.asyncAfter(deadline: .now() + persistDelay) {
            guard self.persistScheduled else { return }
            self.writeQueueNow()
        }
    }

    private func writeQueueNow() {
        persistScheduled = false
        guard let store = queueStore, !restoreDue else { return }
        let valid = core.isSessionValid(nowMs: now())
        let token = valid ? core.sessionToken : nil
        guard core.queueRevision != persistedRevision || token != persistedSessionToken else { return }
        persistedRevision = core.queueRevision
        persistedSessionToken = token
        var groups: [RavensightQueueStore.Group] = []
        if let batch = core.restoredBatch {
            groups.append(.init(sessionToken: batch.sessionToken, expiresAtMs: batch.expiresAtMs, events: batch.events))
        }
        groups.append(.init(
            sessionToken: token,
            expiresAtMs: valid ? core.sessionExpiresAtMs : 0,
            events: core.pendingEvents
        ))
        queueWrites += 1
        if !store.save(groups) {
            warnOnce("queue_write", "could not write the persisted queue; events stay in memory.")
        }
        onQueueWrite?()
    }

    // MARK: Lifecycle

    /// Boots the SDK: queues game_started, reads the server kill switch,
    /// opens a session, starts the flush timer and hooks the app lifecycle.
    /// Makes no request while disabled or opted out. A launch into the
    /// background (background fetch, silent push) waits for the first
    /// foreground. Safe to call once; later calls are ignored.
    public func start() {
        let background = isBackgroundLaunch()
        workQueue.async {
            guard !self.started else { return }
            self.started = true
            if background {
                self.deferredStart = true
                self.log("launched in the background, waiting for the first foreground")
            } else {
                self.performStart()
            }
        }
        if installsLifecycleObservers {
            if Thread.isMainThread {
                installLifecycleHooks()
            } else {
                DispatchQueue.main.async { self.installLifecycleHooks() }
            }
        }
    }

    private func performStart() {
        foreground = true
        consumeColdLaunchMarker()
        queueGameStartedIfDue()
        stateChanged()
        pump()
    }

    /// Main thread only. A scene based app can report the background state
    /// while it launches, so after the observers are in place the state is
    /// read again: an app that is already active runs a deferred start now
    /// instead of waiting for a notification it may have missed.
    private func installLifecycleHooks() {
        guard lifecycle == nil else { return }
        lifecycle = RavensightLifecycle(client: self)
        if !isBackgroundLaunch() && RavensightClient.applicationIsActive() {
            handleDidBecomeActive()
        }
    }

    /// game_started, once per session, only while events may be queued.
    private func queueGameStartedIfDue() {
        guard started, foreground, configuration.trackLifecycleEvents, !startedQueued, core.canQueue else { return }
        if core.track(name: "game_started", data: [:], nowMs: now()) {
            startedQueued = true
        }
    }

    // MARK: Lifecycle handlers (called by RavensightLifecycle, or by tests)

    /// iOS: the app became active. Runs a start deferred by a background
    /// launch.
    func handleDidBecomeActive() {
        workQueue.async {
            guard self.deferredStart else { return }
            self.deferredStart = false
            self.performStart()
        }
    }

    /// iOS: the app is about to resign active. A flush, but not an explicit
    /// one: it respects any backoff or Retry-After window and sends nothing
    /// after a refused key. Only the quit path skips the window.
    func handleWillResignActive() {
        workQueue.async {
            self.pump()
        }
    }

    /// iOS: the app entered the background. Records the time, flushes and
    /// saves the marker a later cold launch uses to report game_exited. No
    /// event (game_paused only with trackPauseEvents). The completion fires
    /// on the work queue when the flush attempt has finished.
    func handleDidEnterBackground(completion: (() -> Void)? = nil) {
        workQueue.async {
            if self.foreground {
                self.backgroundedAtMs = self.now()
                if self.configuration.trackPauseEvents && self.configuration.trackLifecycleEvents {
                    self.core.track(name: "game_paused", data: [:], nowMs: self.now())
                }
                self.writeBackgroundMarker()
                self.stateChanged()
            }
            self.persistQueueIfChanged(immediate: true)
            if let completion = completion {
                self.flushWaiters.append(Waiter(callback: completion, onMain: false))
            }
            self.pump()
        }
    }

    /// iOS: the app is about to return to the foreground. Deletes the marker;
    /// after sessionTimeout or more in the background, ends the old session
    /// with game_exited stamped at the moment the player left and opens a new
    /// one with game_started.
    func handleWillEnterForeground() {
        workQueue.async {
            // Before the first foreground (a deferred start) the marker is
            // left alone: performStart still has to report it.
            guard self.foreground else { return }
            if !self.isPlaytest {
                self.defaults.removeObject(forKey: RavensightClient.markerKey)
            }
            guard let leftAtMs = self.backgroundedAtMs else { return }
            self.backgroundedAtMs = nil

            let nowMs = self.now()
            let timeoutMs = Int64(self.configuration.sessionTimeout * 1000)
            if nowMs - leftAtMs >= timeoutMs {
                if self.configuration.trackLifecycleEvents,
                   self.core.isSessionValid(nowMs: nowMs),
                   let token = self.core.sessionToken {
                    self.core.setPendingExit(.init(
                        sessionToken: token, timestamp: leftAtMs / 1000, retry: true
                    ))
                }
                self.core.invalidateSession()
                self.startedQueued = false
                self.queueGameStartedIfDue()
                self.stateChanged()
                self.pump()
            } else if self.configuration.trackPauseEvents && self.configuration.trackLifecycleEvents {
                self.core.track(name: "game_resumed", data: [:], nowMs: nowMs)
                self.stateChanged()
            }
        }
    }

    /// macOS: the app lost focus. Not an exit; a flush, and game_paused only
    /// with trackPauseEvents.
    func handleFocusLost() {
        workQueue.async {
            if self.configuration.trackPauseEvents && self.configuration.trackLifecycleEvents && self.foreground {
                self.core.track(name: "game_paused", data: [:], nowMs: self.now())
                self.stateChanged()
            }
            self.pump()
        }
    }

    /// macOS: the app regained focus. game_resumed only with trackPauseEvents.
    func handleFocusGained() {
        workQueue.async {
            if self.configuration.trackPauseEvents && self.configuration.trackLifecycleEvents && self.foreground {
                self.core.track(name: "game_resumed", data: [:], nowMs: self.now())
                self.stateChanged()
            }
        }
    }

    /// The quit path: queues game_exited once, then holds the caller for at
    /// most holdSeconds while the last batch leaves. Never call it from the
    /// SDK's own queue. When a background marker is waiting, the next cold
    /// launch reports the exit instead, so it is not sent twice.
    func handleWillTerminate(holdSeconds: TimeInterval = RavensightClient.quitHoldSeconds) {
        let done = DispatchSemaphore(value: 0)
        workQueue.async {
            let markerWaiting = !self.isPlaytest
                && self.defaults.object(forKey: RavensightClient.markerKey) != nil
            if self.configuration.trackLifecycleEvents && self.foreground
                && !self.exitedQueued && !markerWaiting {
                if self.core.track(name: "game_exited", data: [:], nowMs: self.now()) {
                    self.exitedQueued = true
                }
                self.stateChanged()
            }
            self.persistQueueIfChanged(immediate: true)
            self.flushWaiters.append(Waiter(callback: { done.signal() }, onMain: false))
            // The last chance skips any backoff window, but a refused key
            // stays refused: the quit is not an explicit flush.
            self.pump(ignoreBackoff: !self.core.keyRefused)
        }
        _ = done.wait(timeout: .now() + holdSeconds)
    }

    // MARK: Background marker

    private func writeBackgroundMarker() {
        guard !isPlaytest, configuration.trackLifecycleEvents, core.canQueue,
              let leftAtMs = backgroundedAtMs,
              core.isSessionValid(nowMs: now()),
              let token = core.sessionToken else { return }
        defaults.set([
            "sessionToken": token,
            "expiresAt": core.sessionExpiresAtMs / 1000,
            "backgroundedAt": leftAtMs / 1000,
        ] as [String: Any], forKey: RavensightClient.markerKey)
    }

    /// A marker left by a process that never came back to the foreground (the
    /// player swiped it away, or the OS ended it): one attempt to report that
    /// session's game_exited, then the marker is gone whatever the answer.
    private func consumeColdLaunchMarker() {
        guard !isPlaytest,
              let marker = defaults.dictionary(forKey: RavensightClient.markerKey) else { return }
        defaults.removeObject(forKey: RavensightClient.markerKey)
        guard core.canQueue,
              let token = marker["sessionToken"] as? String, !token.isEmpty,
              let expiresAt = RavensightCore.numberValue(marker["expiresAt"]),
              let leftAt = RavensightCore.numberValue(marker["backgroundedAt"]),
              Double(now()) / 1000 < expiresAt else { return }
        core.setPendingExit(.init(sessionToken: token, timestamp: Int64(leftAt), retry: false))
    }

    // MARK: Flush timer

    private func updateTimer() {
        let wanted = started && foreground && core.isActive && configuration.flushInterval > 0
        if wanted && flushTimer == nil {
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
        } else if !wanted, let timer = flushTimer {
            timer.cancel()
            flushTimer = nil
            retryWorkItem?.cancel()
            retryWorkItem = nil
        }
    }

    // MARK: Public API

    /// Queues an event. Nothing is sent per call: the queue goes out in
    /// batches of up to 50 via POST /api/v1/track/batch on the flush timer,
    /// as soon as 50 are queued, on flush(), on background and on quit.
    /// Safe to call before start().
    ///
    /// The return value is queue acceptance, not delivery: true means the
    /// event was queued, false means nothing was queued (disabled, opted
    /// out, stopped, switched off by the server, or an empty name). Whether
    /// the server has it shows in stats.delivered, lastDelivery and onFlush.
    @discardableResult
    public func track(_ name: String, data: [String: Any]? = nil) -> Bool {
        let current = readSnapshot()
        let active = current.enabled && !current.optedOut && current.trackingEnabled && !name.isEmpty
        workQueue.async {
            if self.core.track(name: name, data: data, nowMs: self.now()) {
                self.stateChanged()
                if self.core.pendingEvents.count >= RavensightCore.maxBatchSize {
                    self.pump()
                }
            }
        }
        return active
    }

    /// Forces an immediate flush attempt of any queued events, bypassing the
    /// backoff window once (and making one more attempt after a refused
    /// key). The optional completion fires (on the main queue) when this
    /// attempt has finished, whether or not the queue drained.
    public func flush(completion: (() -> Void)? = nil) {
        workQueue.async {
            if let completion = completion {
                self.flushWaiters.append(Waiter(callback: completion, onMain: true))
            }
            self.pump(ignoreBackoff: true)
        }
    }

    /// Submits free form player feedback via POST /api/v1/feedback. The
    /// category is one of feedbackCategories (or nil); the rating is 1 to 5,
    /// or 0 to omit it. Fails locally, with no request, with "disabled",
    /// "empty_message", "invalid_category" or "invalid_rating". Requires a
    /// live session: if none exists yet the call fails with "no_session"
    /// and a session is opened in the background for next time. The
    /// completion is delivered on the main queue.
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
                    code: "disabled", status: 0,
                    message: "tracking is off, feedback not sent"
                )))
                return
            }
            if let refusal = RavensightCore.feedbackRefusal(message: message, category: category, rating: rating) {
                finish(.failure(RavensightError(
                    code: refusal, status: 0,
                    message: RavensightClient.feedbackMessage(refusal)
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
                    let effects = self.core.applyRefusal(response, keyAuthenticated: false)
                    self.report(effects)
                    if response.status == 401 {
                        // Session expired mid flight; a fresh one is opened
                        // in the background so a retry can succeed.
                        self.core.markSessionWanted()
                    }
                    self.stateChanged()
                    self.pump()
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
    /// do not build game logic on it. While tracking is off it makes no
    /// request and succeeds with an empty list. The completion is delivered
    /// on the main queue.
    public func fetchSuggestions(_ completion: @escaping (Result<[[String: Any]], RavensightError>) -> Void) {
        workQueue.async {
            guard self.core.isActive else {
                DispatchQueue.main.async { completion(.success([])) }
                return
            }
            let request = self.core.suggestionsRequest()
            self.transport.send(request) { response in
                self.workQueue.async {
                    let result: Result<[[String: Any]], RavensightError>
                    if response.status == 200 {
                        let object = response.json as? [String: Any]
                        let raw = object?["suggestions"] as? [Any] ?? []
                        result = .success(raw.compactMap { $0 as? [String: Any] })
                    } else {
                        self.report(self.core.applyRefusal(response, keyAuthenticated: true))
                        self.stateChanged()
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
    }

    /// The player's choice, for a privacy toggle. Written to UserDefaults
    /// (ravensight_tracking_opt_out) before this returns, so it holds on
    /// every later launch, and a saved opt-out wins over
    /// configuration.enabled. Turning off clears the queue and stops the
    /// timer. A no-op under a playtest run.
    public func setTrackingEnabled(_ enabled: Bool) {
        if isPlaytest {
            print("Ravensight: setTrackingEnabled is ignored during a playtest run")
            return
        }
        RavensightClient.saveTrackingEnabled(enabled, defaults: defaults)
        snapshotLock.lock()
        snapshot.optedOut = !enabled
        snapshotLock.unlock()
        workQueue.async {
            self.core.setOptedOut(!enabled)
            if !enabled { self.deleteQueueFile() }
            if enabled { self.queueGameStartedIfDue() }
            self.stateChanged()
            if enabled { self.pump() }
        }
    }

    /// The game's runtime switch, never persisted (for the player's own
    /// choice use setTrackingEnabled). Disabling stops all sending and
    /// discards anything still queued; enabling a client built with
    /// enabled = false starts it.
    public func setEnabled(_ enabled: Bool) {
        snapshotLock.lock()
        snapshot.enabled = enabled
        snapshotLock.unlock()
        workQueue.async {
            self.core.setEnabled(enabled)
            if enabled {
                self.restoreQueueIfDue()
                self.queueGameStartedIfDue()
            } else {
                // A stop keeps nothing, including a file still waiting to
                // be loaded by a client built disabled.
                self.deleteQueueFile()
            }
            self.stateChanged()
            if enabled { self.pump() }
        }
    }

    /// The one control that stops everything, in a normal session and in a
    /// synthetic (playtest) one alike: the flush timer stops, the queue is
    /// cleared (and the persisted queue file deleted), and track, feedback
    /// and reports are refused until resumeTelemetry(). No request of any
    /// kind is made while stopped. Nothing is saved: the next launch starts
    /// normally. Same switch as setEnabled(false).
    ///
    /// Use it for "stop now" (a privacy screen, a parental gate, a
    /// synthetic run that must go quiet). For the player's lasting choice
    /// use setTrackingEnabled(false), which is saved but does not stop a
    /// synthetic session.
    public func stopAllTelemetry() {
        setEnabled(false)
    }

    /// Undoes stopAllTelemetry() for this run. A saved player opt-out still
    /// wins: in a normal session nothing is sent while the player has opted
    /// out. Same switch as setEnabled(true).
    public func resumeTelemetry() {
        setEnabled(true)
    }

    /// Forgets this install's durable analytics identity: mints a new random
    /// id, saves it and returns it. Never returns a synthetic id.
    ///
    /// In a normal session the queue is cleared and the session ends (the
    /// next one opens under the new id). In a synthetic (playtest) session
    /// the run carries on as pt-<runId>, untouched; the new durable id is
    /// saved for the next normal launch and returned.
    @discardableResult
    public func resetDeviceId() -> String {
        let fresh = RavensightClient.mintDeviceId()
        defaults.set(fresh, forKey: RavensightClient.deviceIdKey)
        defaults.removeObject(forKey: RavensightClient.markerKey)
        snapshotLock.lock()
        snapshot.deviceId = fresh
        snapshotLock.unlock()
        if isPlaytest {
            print("Ravensight: resetDeviceId saved a new durable id for the next normal launch; this synthetic run keeps its playtest id")
            // Events a normal launch left on disk belong to the forgotten id.
            workQueue.async { self.deleteQueueFile() }
            return fresh
        }
        workQueue.async {
            self.core.replaceDeviceId(fresh)
            self.deleteQueueFile()
            self.stateChanged()
        }
        return fresh
    }

    /// The durable per install id (dev_ plus 32 hex), saved in UserDefaults.
    /// Safe to mirror in your own storage: it is never a synthetic id. In a
    /// synthetic (playtest) session it still returns the durable id, or an
    /// empty string when this install has never run a normal session; the
    /// id the run actually sends is playtestDeviceId. No hardware identifier
    /// is ever collected.
    public var deviceId: String { return readSnapshot().deviceId }

    /// The game's runtime switch (configuration.enabled, setEnabled).
    public var isEnabled: Bool { return readSnapshot().enabled }

    /// True when the player opted out with setTrackingEnabled(false).
    public var isOptedOut: Bool { return readSnapshot().optedOut }

    /// False once the server kill switch turned tracking off for this run.
    public var isTrackingEnabled: Bool { return readSnapshot().trackingEnabled }

    /// True once a session exists and events can leave the queue.
    public var isReady: Bool {
        let current = readSnapshot()
        return current.enabled && !current.optedOut && current.trackingEnabled
            && current.reason == nil && current.sessionReady
    }

    /// The current session token, nil until a session opens. A game server
    /// can pass it as joinToken so its events join this player's session.
    public var sessionToken: String? { return readSnapshot().sessionToken }

    /// Why the client is not sending, or nil when it is ready: "disabled",
    /// "invalid_key", "tracking_disabled", "offline", "rate_limited",
    /// "session_failed" or "playtest_job_closed".
    public var statusReason: String? { return readSnapshot().reason }

    /// Called on the main queue whenever statusReason changes.
    public var onStatusChange: ((String?) -> Void)? {
        get {
            snapshotLock.lock()
            defer { snapshotLock.unlock() }
            return statusHandler
        }
        set {
            snapshotLock.lock()
            statusHandler = newValue
            snapshotLock.unlock()
        }
    }

    /// Called on the main queue after every delivery attempt: each batch
    /// request, and each failed session open that held queued events back.
    public var onFlush: ((RavensightFlushOutcome) -> Void)? {
        get {
            snapshotLock.lock()
            defer { snapshotLock.unlock() }
            return flushHandler
        }
        set {
            snapshotLock.lock()
            flushHandler = newValue
            snapshotLock.unlock()
        }
    }

    /// Events currently waiting to be sent (queued, not yet delivered).
    public var queuedEventCount: Int { return readSnapshot().queuedEventCount }

    /// Counters for this run: queued (accepted by track), delivered
    /// (accepted by the server), pending, droppedEvents, restored, and the
    /// last delivery attempt.
    public var stats: RavensightStats { return readSnapshot().stats }

    /// The last delivery attempt: accepted, failed(status) or offline, with
    /// its time. Nil before the first attempt.
    public var lastDelivery: RavensightDelivery? { return readSnapshot().stats.lastDelivery }

    /// Runs a block on the work queue after everything already queued there.
    /// Tests use it as a barrier.
    func onWorkQueue(_ block: @escaping () -> Void) {
        workQueue.async(execute: block)
    }

    // MARK: Pump (always on workQueue)

    func pump(ignoreBackoff: Bool = false) {
        guard started, foreground else {
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
            let sent = core.stamp
            transport.send(request) { [weak self] response in
                guard let self = self else { return }
                self.workQueue.async {
                    self.requestInFlight = false
                    if self.core.isStale(purpose, since: sent) {
                        // Opt-out, disable or resetDeviceId happened while
                        // this was in flight: it belongs to the old state.
                        self.log("ignored a response that no longer applies")
                        self.pump()
                        return
                    }
                    let effects = self.core.handle(
                        response: response, for: purpose, nowMs: self.now()
                    )
                    self.report(effects)
                    self.recordDelivery(purpose: purpose, response: response)
                    self.stateChanged()
                    self.pump()
                }
            }
        }
    }

    /// Updates lastDelivery and tells onFlush about a request that carried
    /// events, or a failed session open that kept them waiting.
    private func recordDelivery(purpose: RavensightCore.Purpose, response: RavensightResponse) {
        let carried: Int
        switch purpose {
        case .settings:
            return
        case .session:
            guard response.status != 201, core.pendingCount > 0 else { return }
            carried = 0
        case .batch(let count), .restored(let count):
            carried = count
        case .exit:
            carried = 1
        }
        let result: RavensightDeliveryResult
        switch response.status {
        case 202: result = .accepted
        case 0: result = .offline
        default: result = .failed(status: response.status)
        }
        lastDeliveryRecord = RavensightDelivery(result: result, timestamp: Date(timeIntervalSince1970: Double(now()) / 1000))
        let outcome = RavensightFlushOutcome(
            sent: response.status == 202 ? carried : 0,
            status: response.status,
            error: response.status == 202 ? nil : response.errorCode(fallback: fallbackCode(response.status)),
            pending: core.pendingCount
        )
        if let handler = onFlush {
            DispatchQueue.main.async { handler(outcome) }
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
        for waiter in waiters where !waiter.onMain {
            waiter.callback()
        }
        let onMain = waiters.filter { $0.onMain }
        if !onMain.isEmpty {
            DispatchQueue.main.async {
                for waiter in onMain { waiter.callback() }
            }
        }
    }

    func report(_ effects: [RavensightCore.Effect]) {
        for effect in effects {
            switch effect {
            case .trackingDisabled:
                warnOnce("tracking_disabled", "tracking disabled by the server kill switch (tracking_disabled), sending stopped for this run.")
            case .keyRefused:
                warnOnce("invalid_key", "ingest key refused (invalid_key), sending stopped for this run. Check your gt_live_ key.")
            case .stopped(let reason):
                if reason == RavensightCore.Reason.playtestJobClosed {
                    warnOnce(reason, "playtest job closed (playtest_job_closed), sending stopped for this run.")
                } else {
                    warnOnce("playtest_refused", "playtest token refused (session_failed), sending stopped for this run.")
                }
            case .sessionReady:
                log("session ready")
                if backgroundedAtMs != nil { writeBackgroundMarker() }
            case .sessionFailed(let reason):
                log("session creation failed (\(reason)), will retry")
            case .eventsFlushed(let count):
                log("flushed \(count) event(s)")
            case .flushFailed(let reason):
                log("batch flush failed (\(reason)), will retry")
            case .eventDropped(let reason):
                warnOnce("event_dropped", "dropped an event the server refused (\(reason)); later drops are counted, not logged.")
            }
        }
    }

    // MARK: Snapshot

    /// Call after every state change on the work queue: refreshes the
    /// snapshot, the timer and the status notification.
    func stateChanged() {
        persistQueueIfChanged()
        publishSnapshot()
        updateTimer()
        let reason = core.statusReason
        guard reason != lastNotifiedReason else { return }
        lastNotifiedReason = reason
        if let handler = onStatusChange {
            DispatchQueue.main.async { handler(reason) }
        }
    }

    private func publishSnapshot() {
        let nowMs = now()
        let valid = core.isSessionValid(nowMs: nowMs)
        let counters = core.stats
        let stats = RavensightStats(
            queued: counters.accepted,
            delivered: counters.sent,
            pending: counters.pending,
            droppedEvents: counters.dropped,
            restored: counters.restored,
            flushes: counters.flushes,
            sessions: counters.sessions,
            lastDelivery: lastDeliveryRecord
        )
        snapshotLock.lock()
        // deviceId is the durable id, set at creation and by resetDeviceId
        // only, so it is carried over rather than read from the core.
        snapshot = Snapshot(
            enabled: core.enabled,
            optedOut: core.optedOut,
            trackingEnabled: core.trackingEnabled && core.stopReason == nil,
            sessionReady: valid,
            sessionToken: valid ? core.sessionToken : nil,
            queuedEventCount: core.pendingCount,
            reason: core.statusReason,
            deviceId: snapshot.deviceId,
            stats: stats
        )
        snapshotLock.unlock()
    }

    private func readSnapshot() -> Snapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshot
    }

    func fallbackCode(_ status: Int) -> String {
        return status == 0 ? "network_error" : "http_\(status)"
    }

    func log(_ message: String) {
        if configuration.verboseLogging {
            print("Ravensight: \(message)")
        }
    }

    /// Printed once per run whatever verboseLogging says.
    func warnOnce(_ key: String, _ message: String) {
        guard !warned.contains(key) else { return }
        warned.insert(key)
        print("Ravensight: \(message)")
    }

    private static func feedbackMessage(_ code: String) -> String {
        switch code {
        case "empty_message": return "feedback message is empty"
        case "invalid_category": return "category must be one of " + feedbackCategories.joined(separator: ", ")
        case "invalid_rating": return "rating must be 0 (omitted) or 1 to 5"
        default: return code
        }
    }

    // MARK: Storage

    /// Saves the player's choice without needing a client.
    static func saveTrackingEnabled(_ enabled: Bool, defaults: UserDefaults) {
        defaults.set(!enabled, forKey: optOutKey)
    }

    /// An existing saved id is kept exactly as it is; only a missing one is
    /// minted.
    private static func loadOrCreateDeviceId(_ defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: deviceIdKey), !existing.isEmpty {
            return existing
        }
        let created = mintDeviceId()
        defaults.set(created, forKey: deviceIdKey)
        return created
    }

    /// dev_ plus 32 hex characters from 16 bytes of the system CSPRNG.
    static func mintDeviceId() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return "dev_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Environment

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    /// True for an iOS launch into the background (background fetch, silent
    /// push). Read on the main thread; from another thread it is assumed
    /// false, so call start() from the main thread.
    private static func launchedInBackground() -> Bool {
        #if canImport(UIKit) && !os(watchOS)
        guard Thread.isMainThread else { return false }
        return UIApplication.shared.applicationState == .background
        #else
        return false
        #endif
    }

    /// True when the app is in the foreground and active. Main thread only.
    private static func applicationIsActive() -> Bool {
        #if canImport(UIKit) && !os(watchOS)
        return UIApplication.shared.applicationState == .active
        #else
        return true
        #endif
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
