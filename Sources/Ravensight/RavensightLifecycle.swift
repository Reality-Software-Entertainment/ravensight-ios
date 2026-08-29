import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Hooks the app lifecycle so queued events are flushed when the player
/// leaves: on resign active, on entering the background and on termination.
/// On iOS the background flush runs under a UIApplication background task
/// assertion; on macOS the terminate flush runs under a ProcessInfo activity
/// that disables sudden termination. Both are best effort: a process that
/// exits immediately can still lose the last batch, since the queue lives in
/// memory only.
final class RavensightLifecycle {
    private weak var client: RavensightClient?
    private let trackEvents: Bool
    private var observers: [NSObjectProtocol] = []

    init(client: RavensightClient, trackEvents: Bool) {
        self.client = client
        self.trackEvents = trackEvents
        installObservers()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func observe(_ name: Notification.Name, _ handler: @escaping () -> Void) {
        let observer = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { _ in handler() }
        observers.append(observer)
    }

    private func installObservers() {
        #if canImport(UIKit) && !os(watchOS)
        observe(UIApplication.willResignActiveNotification) { [weak self] in
            self?.client?.flush()
        }
        observe(UIApplication.didEnterBackgroundNotification) { [weak self] in
            guard let self = self else { return }
            if self.trackEvents { self.client?.track("game_paused") }
            self.flushWithBackgroundAssertion()
        }
        observe(UIApplication.willEnterForegroundNotification) { [weak self] in
            guard let self = self else { return }
            if self.trackEvents { self.client?.track("game_resumed") }
        }
        observe(UIApplication.willTerminateNotification) { [weak self] in
            guard let self = self else { return }
            if self.trackEvents { self.client?.track("game_exited") }
            self.flushWithBackgroundAssertion()
        }
        #elseif canImport(AppKit)
        observe(NSApplication.didResignActiveNotification) { [weak self] in
            guard let self = self else { return }
            if self.trackEvents { self.client?.track("game_paused") }
            self.client?.flush()
        }
        observe(NSApplication.didBecomeActiveNotification) { [weak self] in
            guard let self = self else { return }
            if self.trackEvents { self.client?.track("game_resumed") }
        }
        observe(NSApplication.willTerminateNotification) { [weak self] in
            guard let self = self else { return }
            if self.trackEvents { self.client?.track("game_exited") }
            self.flushWithProcessActivity()
        }
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    /// Runs a flush under a background task assertion so iOS grants the app a
    /// short window to finish the request after the player leaves.
    private func flushWithBackgroundAssertion() {
        let application = UIApplication.shared
        var taskId = UIBackgroundTaskIdentifier.invalid
        let end = {
            if taskId != .invalid {
                application.endBackgroundTask(taskId)
                taskId = .invalid
            }
        }
        taskId = application.beginBackgroundTask(withName: "io.ravensight.flush") {
            end()
        }
        client?.flush {
            end()
        }
    }
    #elseif canImport(AppKit)
    /// Runs a flush under a ProcessInfo activity so sudden termination is
    /// deferred while the last batch leaves.
    private func flushWithProcessActivity() {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.suddenTerminationDisabled, .idleSystemSleepDisabled],
            reason: "Ravensight final flush"
        )
        client?.flush {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }
    #endif
}
