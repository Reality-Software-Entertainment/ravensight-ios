import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Wires the app lifecycle notifications to the client's handlers. The
/// handlers themselves live on RavensightClient (handleDidEnterBackground,
/// handleWillEnterForeground and so on) so tests call them directly, with no
/// UIKit or AppKit notification involved.
///
/// iOS: resign active flushes; entering the background flushes under a
/// UIApplication background task and saves the session marker; returning
/// after sessionTimeout ends the old session with game_exited (stamped when
/// the player left) and opens a new one; termination sends game_exited and
/// holds the quit for at most 1.5 seconds. A launch into the background
/// starts the SDK at the first didBecomeActive.
///
/// macOS: focus changes are not exits and send nothing (game_paused and
/// game_resumed only with trackPauseEvents); termination sends game_exited
/// and holds the quit for at most 1.5 seconds.
final class RavensightLifecycle {
    private weak var client: RavensightClient?
    private var observers: [NSObjectProtocol] = []

    init(client: RavensightClient) {
        self.client = client
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
        observe(UIApplication.didBecomeActiveNotification) { [weak self] in
            self?.client?.handleDidBecomeActive()
        }
        observe(UIApplication.willResignActiveNotification) { [weak self] in
            self?.client?.handleWillResignActive()
        }
        observe(UIApplication.didEnterBackgroundNotification) { [weak self] in
            self?.enterBackgroundWithAssertion()
        }
        observe(UIApplication.willEnterForegroundNotification) { [weak self] in
            self?.client?.handleWillEnterForeground()
        }
        observe(UIApplication.willTerminateNotification) { [weak self] in
            self?.client?.handleWillTerminate()
        }
        #elseif canImport(AppKit)
        observe(NSApplication.didResignActiveNotification) { [weak self] in
            self?.client?.handleFocusLost()
        }
        observe(NSApplication.didBecomeActiveNotification) { [weak self] in
            self?.client?.handleFocusGained()
        }
        observe(NSApplication.willTerminateNotification) { [weak self] in
            self?.client?.handleWillTerminate()
        }
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    /// Runs the background handler's flush under a background task assertion
    /// so iOS grants the app a short window to finish the request after the
    /// player leaves.
    private func enterBackgroundWithAssertion() {
        guard let client = client else { return }
        let application = UIApplication.shared
        let lock = NSLock()
        var taskId = UIBackgroundTaskIdentifier.invalid
        let end = {
            lock.lock()
            let id = taskId
            taskId = .invalid
            lock.unlock()
            if id != .invalid {
                DispatchQueue.main.async { application.endBackgroundTask(id) }
            }
        }
        let begun = application.beginBackgroundTask(withName: "io.ravensight.flush") {
            end()
        }
        lock.lock()
        taskId = begun
        lock.unlock()
        client.handleDidEnterBackground(completion: end)
    }
    #endif
}
