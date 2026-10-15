import Foundation

/// A monotonic time source in seconds. Never the wall clock: a player who
/// changes the device time, or a time zone change, must not add or remove
/// play time.
public protocol MonotonicSource {
    var seconds: Double { get }
}

/// ProcessInfo.systemUptime: monotonic, and it does not advance while the
/// device sleeps. Raw values mean nothing across launches, so only the
/// accumulated totals are ever saved.
public struct SystemMonotonicSource: MonotonicSource {
    public init() {}
    public var seconds: Double { return ProcessInfo.processInfo.systemUptime }
}

/// Foreground play time for one run, with an explicit idle estimate.
///
/// Semantics, stated once so the queries can rely on them:
///
/// * `foregroundSeconds` is time the app was in the foreground during this
///   run, summed across every launch that resumed the run. Background time
///   is never counted. It only ever grows, so every event can carry the
///   running total and a query takes the MAX per run.
/// * `idleSecondsEstimate` is an estimate, not a measurement. Inside a
///   foreground stretch, any gap between two inputs longer than
///   `idleThreshold` contributes the part beyond the threshold (a 100 second
///   gap with a 60 second threshold adds 40). The trailing gap before going
///   to the background counts the same way. A player reading a long passage
///   without touching the screen looks idle to this rule; that is why it is
///   called an estimate and reported beside, never subtracted from, the
///   foreground total.
/// * `engagedSecondsEstimate` is foreground minus the idle estimate.
public struct ForegroundClock: Codable, Equatable {
    public var idleThreshold: Double

    /// Totals from finished foreground stretches, saved with the run.
    public private(set) var foregroundSeconds: Double = 0
    public private(set) var idleSecondsEstimate: Double = 0

    /// Monotonic readings for the current stretch. Not saved: a monotonic
    /// value from an earlier launch is meaningless.
    private var foregroundSince: Double?
    private var lastInputAt: Double?

    private enum CodingKeys: String, CodingKey {
        case idleThreshold, foregroundSeconds, idleSecondsEstimate
    }

    public init(idleThreshold: Double = 60) {
        self.idleThreshold = idleThreshold
    }

    public var isInForeground: Bool { return foregroundSince != nil }

    /// The app became active. Entering the foreground counts as input.
    public mutating func enterForeground(at now: Double) {
        guard foregroundSince == nil else { return }
        foregroundSince = now
        lastInputAt = now
    }

    /// The app left the foreground: the stretch is added to the totals.
    public mutating func enterBackground(at now: Double) {
        guard let since = foregroundSince else { return }
        foregroundSeconds += max(0, now - since)
        idleSecondsEstimate += trailingIdle(at: now)
        foregroundSince = nil
        lastInputAt = nil
    }

    /// A tap, a key, a choice: anything that shows the player is there.
    public mutating func recordInput(at now: Double) {
        guard foregroundSince != nil else { return }
        idleSecondsEstimate += trailingIdle(at: now)
        lastInputAt = now
    }

    /// The running totals at this moment, the open stretch included.
    public func totals(at now: Double) -> Totals {
        var foreground = foregroundSeconds
        var idle = idleSecondsEstimate
        if let since = foregroundSince {
            foreground += max(0, now - since)
            idle += trailingIdle(at: now)
        }
        return Totals(foregroundSeconds: foreground, idleSecondsEstimate: min(idle, foreground))
    }

    private func trailingIdle(at now: Double) -> Double {
        guard let last = lastInputAt else { return 0 }
        return max(0, (now - last) - idleThreshold)
    }

    public struct Totals: Equatable {
        public let foregroundSeconds: Double
        public let idleSecondsEstimate: Double
        public var engagedSecondsEstimate: Double { return max(0, foregroundSeconds - idleSecondsEstimate) }
    }
}
