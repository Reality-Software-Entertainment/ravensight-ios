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
    public static let sdkVersion = "0.5.0"
    /// The default host. "/api/v1" is appended for you.
    public static let defaultApiUrl = RavensightCore.defaultApiUrl
    /// Server hard limit on POST /track/batch.
    public static let maxBatchSize = RavensightCore.maxBatchSize
    /// The feedback categories the server accepts.
    public static let feedbackCategories = RavensightCore.feedbackCategories

    static let deviceIdKey = "ravensight_device_id"
    static let optOutKey = "ravensight_tracking_opt_out"
    static let markerKey = "ravensight_background_marker"
    /// The player's yes in consent = .optIn mode.
    static let optInKey = "ravensight_optin"
    /// Crash diagnostics already handled, so each is sent once.
    static let crashSeenKey = "ravensight_crash_seen"
    /// When the last few Objective-C exception crashes happened, so the
    /// system's report of the same crash is not sent a second time.
    static let exceptionTimesKey = "ravensight_exception_times"
    /// Captures held in memory before the first settings or session answer.
    static let maxBootErrors = 5
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

    /// True when the client was created without an ingest key. It stays
    /// inert for the run: statusReason is "no_key" and isEnabled is false.
    public let isInert: Bool

    /// The consent mode from the configuration.
    let consent: RavensightConsent
    /// Mints rs_event_id, shared with the core.
    let eventIds: RavensightEventIds

    let workQueue = DispatchQueue(label: "io.ravensight.sdk")
    let transport: RavensightTransport
    let now: () -> Int64
    private let defaults: UserDefaults
    private let isBackgroundLaunch: () -> Bool
    private let installsLifecycleObservers: Bool

    var core: RavensightCore
    private var configDocument: RavensightConfigDocument?
    private var configScope = ""
    private var configRequest: UUID?
    private var configCallbacks: [(RavensightConfigResult) -> Void] = []
    private var configSnapshot: [String: Any] = [:]
    private var configSnapshotDevice = ""
    private var configHandler: ((RavensightConfigResult) -> Void)?
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
    /// Opt-in per-session performance sampling (configuration.performance).
    let healthSampler = RavensightHealthSampler()
    private var healthSent = false
    private var bootMs: Double?
    /// Starts a frame source feeding the sampler; nil where there is none
    /// (macOS). Tests replace it.
    var makeFrameSource: (RavensightHealthSampler) -> RavensightFrameSource? = {
        #if canImport(UIKit) && !os(watchOS)
        return RavensightFrameHook(sampler: $0)
        #else
        return nil
        #endif
    }
    /// Main thread only.
    private var frameSource: RavensightFrameSource?
    /// What the work queue last asked the main thread for.
    private var samplingWanted = false
    private var warned: Set<String> = []
    private var lastNotifiedReason: String?

    // Automatic error capture. Work queue only, except metricSubscriber
    // (main thread only).
    /// False in tests: no process-wide exception handler, no MetricKit.
    private let installsCrashSources: Bool
    /// Where an Objective-C exception is written as the app dies. Nil while
    /// inert and in a synthetic (playtest) run, which never touch a file.
    private let crashFileURL: URL?
    private var errorHooked = false
    private var crashFileChecked = false
    private var bootErrors: [RavensightCapture] = []
    private var errorCaps: RavensightErrorCaps
    private var trail = RavensightTrail()
    private var trailStartMs: Int64
    private var metricSubscriber: AnyObject?
    /// Captures queued and captures dropped by a device cap, this run.
    private(set) var errorsCaptured = 0
    private(set) var errorsCapped = 0

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
    private var lastDeliveryRecord: RavensightDelivery?

    /// Seconds a report waits for a session to open, and between status
    /// checks while a screenshot is processed. Tests shorten them.
    var reportSessionWait: TimeInterval = 10
    var reportPollInterval: TimeInterval = 2
    var reportPollAttempts = 35

    private let snapshotLock = NSLock()
    private var snapshot = Snapshot()
    /// Calls to setTrackingEnabled and setEnabled whose choice the snapshot
    /// already shows but the core, on the work queue, has not applied yet.
    /// While any is pending, a snapshot published from the core keeps the
    /// caller's enabled and opted out values: otherwise a publish that ran in
    /// between (start, the queue load, a timer) wrote the core's old value
    /// back, and a track right after the player's yes was refused and lost.
    /// Guarded by snapshotLock.
    private var pendingChoices = 0
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
        var capturingErrors = false
        /// Capture installed and the game's trail switch on.
        var trailing = false
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
            now: nil,
            installsCrashSources: true
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
        queueDirectory: URL? = nil,
        random: (() -> Double)? = nil,
        installsCrashSources: Bool = false
    ) {
        self.configuration = configuration
        self.transport = transport
        let clock = now ?? { Int64(Date().timeIntervalSince1970 * 1000) }
        self.now = clock
        self.defaults = defaults
        self.isBackgroundLaunch = isBackgroundLaunch ?? RavensightClient.launchedInBackground
        self.installsLifecycleObservers = installsLifecycleObservers
        self.consent = configuration.consent
        self.installsCrashSources = installsCrashSources
        let startMs = clock()
        self.errorCaps = RavensightErrorCaps(nowMs: startMs)
        self.trailStartMs = startMs

        // No key: inert for the run. Nothing is read beyond the player's
        // saved choice, nothing is written, no file is touched, no request
        // is made and no timer or observer is installed.
        let inert = configuration.ingestKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.isInert = inert

        let token = inert ? nil : RavensightClient.firstNonEmpty(
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
            optedOut = !RavensightClient.savedChoice(defaults, consent: configuration.consent)
            if inert || (configuration.consent == .optIn && optedOut) {
                // Inert, or opt-in with no yes yet: no id is created. One an
                // earlier yes saved is kept (saying no keeps it).
                deviceId = defaults.string(forKey: RavensightClient.deviceIdKey) ?? ""
            } else {
                deviceId = RavensightClient.loadOrCreateDeviceId(defaults)
            }
            durableId = deviceId
            self.playtestDeviceId = nil
        }
        self.queueFileURL = inert ? nil : RavensightQueueStore.defaultFileURL(
            ingestKey: configuration.ingestKey, directory: queueDirectory
        )
        self.crashFileURL = (inert || token != nil) ? nil : RavensightCrashFile.defaultURL(
            ingestKey: configuration.ingestKey, directory: queueDirectory
        )
        if configuration.persistQueue && token == nil && !inert {
            self.queueStore = queueFileURL.map(RavensightQueueStore.init(fileURL:))
        } else {
            self.queueStore = nil
        }

        let distribution = RavensightCore.validDistribution(configuration.distribution)
        let eventIds = RavensightEventIds(deviceId: deviceId, startSec: clock() / 1000)
        self.eventIds = eventIds
        let coreConfig = RavensightCoreConfig(
            ingestKey: configuration.ingestKey,
            apiUrl: configuration.apiUrl,
            gameVersion: configuration.gameVersion ?? RavensightClient.bundleVersion(),
            platform: RavensightClient.platformName(),
            deviceId: deviceId,
            maxQueueSize: configuration.maxQueueSize,
            playtestToken: token,
            distribution: distribution,
            eventIds: eventIds
        )
        var resolvedConfig = coreConfig
        if configuration.sendDeviceInfo { resolvedConfig.device = RavensightClient.deviceFields() }
        var core = RavensightCore(config: resolvedConfig)
        if let random = random { core.random = random }
        // The opt-out is applied before anything can be queued or sent.
        core.setEnabled(configuration.enabled)
        core.setOptedOut(optedOut)
        if inert {
            core.stop(reason: RavensightCore.Reason.noKey)
        } else if token != nil && runId == nil {
            core.stop(reason: RavensightCore.Reason.sessionFailed)
        }
        if let store = self.queueStore {
            // No file contents, only that the exclusion did not take.
            let warning: (String) -> Void = { message in print("Ravensight: \(message)") }
            store.onExclusionFailure = warning
        }
        self.core = core
        self.snapshot.deviceId = durableId
        self.persistedRevision = self.core.queueRevision
        self.lastNotifiedReason = self.core.statusReason
        if inert && !configuration.optional {
            warnOnce(
                "no_key",
                "no ingest key (no_key), the SDK is inert for this run: nothing is stored or sent. Set optional = true to silence this line."
            )
        }
        if token != nil && runId == nil {
            warnOnce(
                "playtest_no_run",
                "a playtest token was found without a run id (session_failed), nothing is sent this run. Set RAVENSIGHT_PLAYTEST_RUN_ID too."
            )
        }
        if let raw = configuration.distribution, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, distribution == nil {
            warnOnce(
                "distribution",
                "distribution ignored: it must be at most \(RavensightCore.maxDistributionLength) characters with no control characters."
            )
        }
        refreshConfigCache()
        publishSnapshot()
        if inert { return }

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
        #if canImport(ObjectiveC)
        if errorHooked, let url = crashFileURL { RavensightExceptionHook.deactivate(fileURL: url) }
        #endif
        if let subscriber = metricSubscriber {
            DispatchQueue.main.async { RavensightClient.stopSubscriber(subscriber) }
        }
        if let source = frameSource {
            DispatchQueue.main.async { source.invalidate() }
        }
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
        core.restore(events: loaded.groups.flatMap { $0.events }, nowMs: nowMs)
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
        if let url = queueFileURL {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("tmp"))
        }
        persistedRevision = core.queueRevision
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
        guard core.queueRevision != persistedRevision else { return }
        persistedRevision = core.queueRevision
        let groups = RavensightQueueStore.groups(core.pendingEvents)
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
        // Inert (no key): no work queue task, no timer, no lifecycle observer.
        if isInert { return }
        let background = isBackgroundLaunch()
        if configuration.performance { bootMs = RavensightHealthSampler.msSinceProcessStart() }
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
            self.queueHealthIfDue()
            self.persistQueueIfChanged(immediate: true)
            if let completion = completion {
                self.flushWaiters.append(Waiter(callback: completion, onMain: false))
            }
            self.pump()
        }
    }

    /// Work queue. Sampling runs only while performance is on, the client is
    /// started and events may be queued (not disabled, opted out or stopped).
    private func updateSampling() {
        let want = configuration.performance && started && core.canQueue
        guard want != samplingWanted else { return }
        samplingWanted = want
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.frameSource?.invalidate()
            self.frameSource = nil
            if want { self.frameSource = self.makeFrameSource(self.healthSampler) }
        }
    }

    /// Queues the one health event of this session, when performance
    /// sampling is on and at least one sample exists. Work queue only.
    /// Nothing is sent per second or from the frame hook.
    func queueHealthIfDue() {
        guard configuration.performance, !healthSent, let summary = healthSampler.summary() else { return }
        let built = RavensightTypedEvents.health(
            fpsMedian: summary.median, fpsP10: summary.p10,
            memoryMb: RavensightHealthSampler.memoryMb(), bootMs: bootMs)
        if core.track(name: built.name, data: built.data, nowMs: now()) {
            healthSent = true
            stateChanged()
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
                self.resetErrorSession()
                self.startedQueued = false
                self.healthSent = false
                self.healthSampler.reset()
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
    ///
    /// Every queued event's data gains an rs_event_id (any value of yours
    /// under that key is replaced), which the server uses to recognise a
    /// resend. An event whose data is over 8,192 bytes as JSON is dropped
    /// here and never sent: track returns false, it counts in
    /// droppedEvents, one warning is printed for the run and onFlush is
    /// called with the error "event_too_large".
    @discardableResult
    public func track(_ name: String, data: [String: Any]? = nil) -> Bool {
        if isInert { return false }
        let current = readSnapshot()
        let active = current.enabled && !current.optedOut && current.trackingEnabled && !name.isEmpty
        // Stamped and measured here, on the caller's thread, so the answer
        // is honest about an event too large to send. The data is copied
        // into plain JSON values first.
        var stamped: [String: Any]?
        var eventId: String?
        if active {
            var payload = RavensightCore.sanitizeJSON(data ?? [:]) as? [String: Any] ?? [:]
            let id = eventIds.next()
            payload[RavensightCore.eventIdKey] = id
            if RavensightCore.eventBytes(payload) > RavensightCore.maxEventBytes {
                workQueue.async { self.dropTooLarge(name) }
                return false
            }
            stamped = payload
            eventId = id
        }
        workQueue.async {
            if self.core.track(name: name, data: stamped ?? data, nowMs: self.now(), eventId: eventId) {
                self.addTrailLine("track", name)
                self.stateChanged()
                if self.core.pendingEvents.count >= RavensightCore.maxBatchSize {
                    self.pump()
                }
            }
        }
        return active
    }

    /// An event over maxEventBytes: counted, warned about once, reported.
    private func dropTooLarge(_ name: String) {
        core.countDropped(1)
        warnOnce(
            "event_too_large",
            "dropped event \"\(name)\": its data is larger than \(RavensightCore.maxEventBytes) bytes as JSON (later drops are counted, not logged)."
        )
        let outcome = RavensightFlushOutcome(sent: 0, status: 0, error: "event_too_large", pending: core.pendingCount)
        if let handler = onFlush {
            DispatchQueue.main.async { handler(outcome) }
        }
        stateChanged()
    }

    /// Forces an immediate flush attempt of any queued events, bypassing the
    /// backoff window once (and making one more attempt after a key refused
    /// on a batch; a key refused by the settings check or the session open
    /// has ended the run). The optional completion fires (on the main queue) when this
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
    ///
    /// With consent = .optIn, true is the player's yes: it is saved under
    /// ravensight_optin, the device id is created (if there is none yet) and
    /// the SDK starts; events tracked right after it are queued while the
    /// settings check runs. false withdraws it and keeps the device id
    /// (resetDeviceId forgets it). While inert the choice is saved and
    /// nothing else happens.
    public func setTrackingEnabled(_ enabled: Bool) {
        if isPlaytest {
            print("Ravensight: setTrackingEnabled is ignored during a playtest run")
            return
        }
        RavensightClient.saveTrackingEnabled(enabled, defaults: defaults, consent: consent)
        // The first yes in opt-in mode is the first moment an id may exist.
        var minted: String?
        snapshotLock.lock()
        snapshot.optedOut = !enabled
        pendingChoices += 1
        if enabled && !isInert && snapshot.deviceId.isEmpty {
            let id = RavensightClient.loadOrCreateDeviceId(defaults)
            snapshot.deviceId = id
            minted = id
        }
        snapshotLock.unlock()
        if let id = minted { eventIds.setDeviceId(id) }
        workQueue.async {
            if let id = minted { self.core.replaceDeviceId(id) }
            self.core.setOptedOut(!enabled)
            self.choiceApplied()
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
        pendingChoices += 1
        snapshotLock.unlock()
        workQueue.async {
            self.core.setEnabled(enabled)
            self.choiceApplied()
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
    ///
    /// While inert, or with consent = .optIn before the player's yes, the
    /// saved id (if any) is forgotten and none is made: it returns "".
    @discardableResult
    public func resetDeviceId() -> String {
        if !isPlaytest && (isInert || (consent == .optIn && readSnapshot().optedOut)) {
            defaults.removeObject(forKey: RavensightClient.deviceIdKey)
            defaults.removeObject(forKey: RavensightClient.markerKey)
            defaults.removeObject(forKey: RavensightClient.attributionKey)
            snapshotLock.lock()
            snapshot.deviceId = ""
            snapshotLock.unlock()
            eventIds.setDeviceId("")
            if !isInert {
                workQueue.async {
                    self.core.replaceDeviceId("")
                    self.deleteQueueFile()
                    self.forgetPendingCrashes()
                    self.stateChanged()
                }
            }
            return ""
        }
        let fresh = RavensightClient.mintDeviceId()
        defaults.set(fresh, forKey: RavensightClient.deviceIdKey)
        defaults.removeObject(forKey: RavensightClient.markerKey)
        defaults.removeObject(forKey: RavensightClient.attributionKey)
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
            self.forgetPendingCrashes()
            self.resetErrorSession()
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

    /// The game's runtime switch (configuration.enabled, setEnabled). Always
    /// false while inert (no ingest key).
    public var isEnabled: Bool { return !isInert && readSnapshot().enabled }

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

    /// Why the client is not sending, or nil when it is ready: "no_key"
    /// (inert, no ingest key), "disabled", "invalid_key", "tracking_disabled", "offline", "rate_limited",
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

    /// True while automatic error capture is installed: a key, the player's
    /// consent, captureErrors on and the game's switch not off.
    public var isCapturingErrors: Bool { return readSnapshot().capturingErrors }

    /// Adds a line to the trail sent with the next captured error (only
    /// when the game's trail switch is on; kept in memory, never sent on
    /// its own). An .error line is also captured as an error event with
    /// rs_source "log" and severity "warning". The SDK cannot read your
    /// app's other logs, so this and your track calls are the whole trail.
    public func log(_ message: String, level: RavensightLogLevel) {
        if isInert { return }
        // With the trail off, an info or warning line is dropped here,
        // before it is copied onto the work queue.
        if level != .error && !readSnapshot().trailing { return }
        workQueue.async {
            self.addTrailLine(level.rawValue, message)
            if level == .error,
               self.capture(RavensightCapture(source: "log", severity: "warning", message: message)) {
                self.stateChanged()
            }
        }
    }

    // MARK: Error capture (work queue)

    /// Installs or removes the crash sources to match the state, and sends
    /// or discards the captures held before the first answer.
    private func syncErrorCapture() {
        let want = configuration.captureErrors && started && core.isActive && core.errorCaptureEnabled
        if want && !errorHooked {
            errorHooked = true
            crashFileChecked = true
            installCrashSources()
            loadCrashFile()
            log("error capture installed")
        } else if !want && errorHooked {
            errorHooked = false
            trail.clear()
            bootErrors.removeAll()
            removeCrashSources()
            RavensightCrashFile.delete(crashFileURL)
            log("error capture removed")
        } else if !want && started && !crashFileChecked {
            // Off from the start (captureErrors false, opted out, stopped):
            // a crash an earlier launch saved is not kept.
            crashFileChecked = true
            RavensightCrashFile.delete(crashFileURL)
        }
        if !core.errorTrailEnabled && !trail.lines.isEmpty { trail.clear() }
        if errorHooked && core.errorCaptureAnswered && !bootErrors.isEmpty {
            let held = bootErrors
            bootErrors = []
            for capture in held { _ = self.capture(capture) }
        }
    }

    private func installCrashSources() {
        guard installsCrashSources, !isPlaytest else { return }
        #if canImport(ObjectiveC)
        if let url = crashFileURL { RavensightExceptionHook.activate(fileURL: url) }
        #endif
        #if canImport(MetricKit) && (os(iOS) || os(macOS))
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.metricSubscriber == nil else { return }
            let subscriber = RavensightMetricKitSubscriber { [weak self] diagnostics in
                self?.workQueue.async { self?.receiveCrashDiagnostics(diagnostics) }
            }
            subscriber.start()
            self.metricSubscriber = subscriber
        }
        #endif
    }

    private func removeCrashSources() {
        guard installsCrashSources, !isPlaytest else { return }
        #if canImport(ObjectiveC)
        RavensightExceptionHook.deactivate(fileURL: crashFileURL)
        #endif
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let subscriber = self.metricSubscriber else { return }
            self.metricSubscriber = nil
            RavensightClient.stopSubscriber(subscriber)
        }
    }

    private static func stopSubscriber(_ subscriber: AnyObject) {
        #if canImport(MetricKit) && (os(iOS) || os(macOS))
        (subscriber as? RavensightMetricKitSubscriber)?.stop()
        #endif
    }

    /// The Objective-C exception the last launch died of, if any: read,
    /// deleted, and captured (held until the first answer).
    private func loadCrashFile() {
        guard let url = crashFileURL else { return }
        let reports = RavensightCrashFile.load(url, nowSec: now() / 1000)
        RavensightCrashFile.delete(url)
        guard !reports.isEmpty else { return }
        var times = defaults.array(forKey: RavensightClient.exceptionTimesKey) as? [Int64] ?? []
        times.append(contentsOf: reports.compactMap { $0.atSec })
        defaults.set(Array(times.suffix(RavensightCrashFile.maxReports)), forKey: RavensightClient.exceptionTimesKey)
        for report in reports { _ = capture(report) }
    }

    /// Crash diagnostics from the system: each sent once. A SIGABRT within a
    /// minute of an exception this SDK already saved is that same crash.
    func receiveCrashDiagnostics(_ diagnostics: [RavensightCrashDiagnostic]) {
        guard errorHooked else { return }
        var seen = defaults.stringArray(forKey: RavensightClient.crashSeenKey) ?? []
        let exceptionTimes = defaults.array(forKey: RavensightClient.exceptionTimesKey) as? [Int64] ?? []
        var queued = false
        for diagnostic in diagnostics {
            let identity = diagnostic.identity
            guard !seen.contains(identity) else { continue }
            seen.append(identity)
            let sameAsException = diagnostic.signal == 6 && exceptionTimes.contains {
                $0 >= diagnostic.beginSec - 60 && $0 <= diagnostic.endSec + 60
            }
            if sameAsException { continue }
            if capture(diagnostic.capture) { queued = true }
        }
        defaults.set(Array(seen.suffix(50)), forKey: RavensightClient.crashSeenKey)
        if queued || !bootErrors.isEmpty { stateChanged() }
    }

    /// Queues one automatic capture after the boot hold, the device caps
    /// and the scrub. True when it was queued; over a cap it is dropped
    /// silently.
    @discardableResult
    func capture(_ capture: RavensightCapture) -> Bool {
        guard errorHooked, core.isActive else { return false }
        if !core.errorCaptureAnswered {
            // A full hold makes room for a crash by dropping the oldest
            // warning (a log line), so warnings never push a crash out.
            if bootErrors.count >= RavensightClient.maxBootErrors {
                errorsCapped += 1
                guard capture.severity != "warning",
                      let at = bootErrors.firstIndex(where: { $0.severity == "warning" }) else { return false }
                bootErrors.remove(at: at)
            }
            bootErrors.append(capture)
            return false
        }
        let nowMs = now()
        // The session cap and the bucket before any scrub or dedupe key.
        guard errorCaps.hasRoom(nowMs: nowMs) else {
            errorsCapped += 1
            return false
        }
        let built = RavensightErrorText.eventData(capture, trail: nil)
        guard errorCaps.admit(key: built.key, nowMs: nowMs) else {
            errorsCapped += 1
            return false
        }
        var data = built.data
        if core.errorTrailEnabled && !trail.lines.isEmpty && errorCaps.takeTrail() {
            data["rs_trail"] = trail.text
        }
        guard core.track(name: "error", data: data, nowMs: nowMs, atSec: capture.atSec) else { return false }
        errorsCaptured += 1
        return true
    }

    /// One trail line, when capture is installed and the trail is on.
    private func addTrailLine(_ level: String, _ text: String) {
        guard errorHooked, core.errorTrailEnabled else { return }
        trail.add(level: level, text: text, elapsedMs: now() - trailStartMs)
    }

    /// A new identity: no crash saved or held under the old one is sent.
    private func forgetPendingCrashes() {
        RavensightCrashFile.delete(crashFileURL)
        bootErrors.removeAll()
    }

    /// A new session (or a new identity) gets fresh caps and an empty trail.
    private func resetErrorSession() {
        let nowMs = now()
        errorCaps = RavensightErrorCaps(nowMs: nowMs)
        trail.clear()
        trailStartMs = nowMs
    }

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
            if case .batch(let count) = purpose { core.noteInFlight(count) }
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
        case .batch(let count):
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
                warnOnce("invalid_key", "ingest key refused (invalid_key), sending stopped for this run. Check your gt_live_ or gt_pub_ key.")
            case .stopped(let reason):
                if reason == RavensightCore.Reason.playtestJobClosed {
                    warnOnce(reason, "playtest job closed (playtest_job_closed), sending stopped for this run.")
                } else {
                    warnOnce("playtest_refused", "playtest token refused (session_failed), sending stopped for this run.")
                }
            case .sessionReady:
                log("session ready")
                fetchConfigOnQueue(nil)
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

    /// Called on the main queue after each config fetch, including offline fallback.
    public var onConfigReady: ((RavensightConfigResult) -> Void)? {
        get { snapshotLock.lock(); defer { snapshotLock.unlock() }; return configHandler }
        set { snapshotLock.lock(); configHandler = newValue; snapshotLock.unlock() }
    }

    /// Strict typed fallback. Supported defaults: Bool, Int, Double, String and JSON containers.
    ///
    /// Experiment exposure: the first typed read in a run (any key) marks
    /// every experiment the last fetch assigned as exposed. One rs_exposure
    /// event is queued then, and every event queued after it carries
    /// rs_exp_<key> = <variant>. Events queued before carry no tag; an
    /// experiment missing from a later fetch is no longer tagged; a
    /// well-formed rs_exp_ value the game sets itself is kept.
    public func getConfig<T>(_ key: String, default fallback: T) -> T {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        guard snapshot.enabled, !snapshot.optedOut, snapshot.trackingEnabled, (isPlaytest || snapshot.deviceId == configSnapshotDevice), !["invalid_key", "no_key"].contains(snapshot.reason ?? "") else { return fallback }
        workQueue.async {
            if self.core.expose(nowMs: self.now()) { self.stateChanged() }
        }
        return RavensightConfigDocument.get(configSnapshot[key], fallback: fallback)
    }

    // MARK: Ads and attribution

    /// One ad lifecycle step as an rs_ad event (the contract's fixed name). Refused
    /// locally, returning false with nothing queued, when the ad breaks the
    /// contract: no network, an unknown format or result, a revenue that is
    /// not a digit string, revenue without a three letter currency, or
    /// revenue on a result other than shown.
    @discardableResult
    public func trackAd(_ ad: RavensightAd) -> Bool {
        guard let data = ad.eventData() else {
            warnOnce("ad_refused", "ad event refused locally: check network, format, result, and that revenue comes with a currency on a shown result.")
            return false
        }
        return track("rs_ad", data: data)
    }

    /// trackAd with result shown and revenue in micros of currency.
    @discardableResult
    public func trackAdRevenue(network: String, format: String, placement: String?,
                               revenueMicros: String, currency: String) -> Bool {
        return trackAd(RavensightAd(network: network, format: format, result: "shown", placement: placement,
                                    revenueMicros: revenueMicros, currency: currency))
    }

    /// Records where this install came from, once per install: the first
    /// call queues one rs_attribution event and saves a flag beside the
    /// device id; later calls, in this run or any later one, return false.
    /// resetDeviceId forgets the flag.
    @discardableResult
    public func setAttribution(_ attribution: RavensightAttribution) -> Bool {
        guard let data = attribution.eventData() else {
            warnOnce("attribution_refused", "attribution refused locally: source must be 1 to 64 characters and fields within their limits.")
            return false
        }
        guard !defaults.bool(forKey: RavensightClient.attributionKey) else { return false }
        guard track("rs_attribution", data: data) else { return false }
        defaults.set(true, forKey: RavensightClient.attributionKey)
        return true
    }

    static let attributionKey = "ravensight_attribution_sent"

    /// The model (utsname machine, such as iPhone15,2) and the OS version
    /// without its name. No permission prompt, no hardware identifier.
    static func deviceFields() -> [String: String] {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var fields: [String: String] = [:]
        let model = clean(machine)
        if !model.isEmpty { fields["model"] = model }
        fields["osVersion"] = clean("\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
        return fields
    }

    /// Printable, trimmed, at most 128 characters.
    static func clean(_ value: String) -> String {
        let printable = String(value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }.map(Character.init))
        return RavensightWire.cut(printable.trimmingCharacters(in: .whitespacesAndNewlines), 128)
    }

    public func fetchConfig(completion: ((RavensightConfigResult) -> Void)? = nil) {
        workQueue.async { self.fetchConfigOnQueue(completion) }
    }

    private func refreshConfigCache() {
        let scope = RavensightConfigDocument.scope(core.config)
        if !core.isActive || core.config.deviceId.isEmpty {
            configDocument = nil; configScope = ""
        } else if scope != configScope {
            configScope = scope; configDocument = nil
            if !isPlaytest, defaults.string(forKey: "ravensight_config_scope") == scope,
               let data = defaults.data(forKey: "ravensight_config_data") { configDocument = RavensightConfigDocument.parse(data) }
        }
        core.configExperiments = configDocument?.experiments ?? [:]
        core.configExperimentDevice = core.config.deviceId
        snapshotLock.lock(); configSnapshot = configDocument?.values ?? [:]; configSnapshotDevice = core.config.deviceId; snapshotLock.unlock()
    }

    private func fetchConfigOnQueue(_ completion: ((RavensightConfigResult) -> Void)?) {
        refreshConfigCache()
        guard core.isActive, !core.config.deviceId.isEmpty else {
            if let completion = completion { DispatchQueue.main.async { completion(RavensightConfigResult(source: "default", values: [:])) } }
            return
        }
        if let completion = completion { configCallbacks.append(completion) }
        guard configRequest == nil else { return }
        let request = UUID(); configRequest = request
        let scope = configScope
        let stamp = core.stamp
        var url = URLComponents(string: core.config.apiUrl + "/ingest/config")!
        url.queryItems = [URLQueryItem(name: "deviceId", value: core.config.deviceId), URLQueryItem(name: "platform", value: core.config.platform), URLQueryItem(name: "gameVersion", value: core.config.gameVersion)]
        var headers = ["X-API-Key": core.config.ingestKey]
        if let token = core.config.playtestToken { headers["X-Ravensight-Playtest"] = token }
        if let etag = configDocument?.etag { headers["If-None-Match"] = etag }
        let finish: (RavensightResponse) -> Void = { [weak self] response in
            guard let self = self, self.configRequest == request else { return }
            self.configRequest = nil
            let callbacks = self.configCallbacks; self.configCallbacks = []
            let valid = self.core.isActive && self.configScope == scope && !self.core.isStale(.batch(count: 0), since: stamp) && !self.core.isStale(.session, since: stamp)
            var source = self.configDocument == nil ? "default" : "cache"
            if valid, response.status == 200, let data = response.body, let fresh = RavensightConfigDocument.parse(data) {
                self.configDocument = fresh; source = "network"
                if !self.isPlaytest {
                    self.defaults.set(fresh.data, forKey: "ravensight_config_data")
                    self.defaults.set(scope, forKey: "ravensight_config_scope")
                }
                self.refreshConfigCache()
            }
            let result = RavensightConfigResult(source: valid ? source : "default", values: valid ? self.configDocument?.values ?? [:] : [:])
            let handler = valid ? self.onConfigReady : nil
            DispatchQueue.main.async { for callback in callbacks { callback(result) }; handler?(result) }
        }
        transport.send(RavensightRequest(method: "GET", url: url.string!, headers: headers)) { [weak self] response in
            self?.workQueue.async { finish(response) }
        }
        workQueue.asyncAfter(deadline: .now() + 5) { finish(.networkFailure("config timeout")) }
    }

    // MARK: Snapshot

    /// Call after every state change on the work queue: refreshes the
    /// snapshot, the timer and the status notification.
    func stateChanged() {
        syncErrorCapture()
        refreshConfigCache()
        updateSampling()
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
        // A choice the caller made that the core has not applied yet wins.
        let callerChoicePending = pendingChoices > 0
        snapshot = Snapshot(
            enabled: callerChoicePending ? snapshot.enabled : core.enabled,
            optedOut: callerChoicePending ? snapshot.optedOut : core.optedOut,
            trackingEnabled: core.trackingEnabled && core.stopReason == nil,
            sessionReady: valid,
            sessionToken: valid ? core.sessionToken : nil,
            queuedEventCount: core.pendingCount,
            reason: core.statusReason,
            deviceId: snapshot.deviceId,
            stats: stats,
            capturingErrors: errorHooked,
            trailing: errorHooked && core.errorTrailEnabled
        )
        snapshotLock.unlock()
    }

    /// Work queue only: one setTrackingEnabled or setEnabled has reached the
    /// core, so the core is the truth again once none is pending.
    private func choiceApplied() {
        snapshotLock.lock()
        pendingChoices -= 1
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

    /// Saves the player's choice without needing a client. The opt-out key
    /// is always written, as before 0.4.0. In opt-in mode the yes is also
    /// written (or removed) under ravensight_optin; consent nil (before
    /// start(), when the mode is not known yet) writes it on a yes and
    /// removes it on a no, so either mode reads the same choice.
    static func saveTrackingEnabled(_ enabled: Bool, defaults: UserDefaults, consent: RavensightConsent?) {
        defaults.set(!enabled, forKey: optOutKey)
        if consent == .optIn || consent == nil {
            if enabled {
                defaults.set(true, forKey: optInKey)
            } else {
                defaults.removeObject(forKey: optInKey)
            }
        }
    }

    /// The player's saved choice in a consent mode: true when tracking may
    /// run. opt-out: on unless an opt-out was saved. opt-in: off until a yes
    /// was saved.
    static func savedChoice(_ defaults: UserDefaults, consent: RavensightConsent) -> Bool {
        switch consent {
        case .optOut: return !defaults.bool(forKey: optOutKey)
        case .optIn: return defaults.bool(forKey: optInKey)
        }
    }

    /// An existing saved id is kept exactly as it is; only a missing one is
    /// minted.
    static func loadOrCreateDeviceId(_ defaults: UserDefaults) -> String {
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
