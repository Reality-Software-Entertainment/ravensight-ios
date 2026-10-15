import Foundation

/// One analytics event as the game would send it.
public struct NarrativeEvent: Equatable {
    public let name: String
    public let data: [String: AnyHashable]

    public init(name: String, data: [String: AnyHashable]) {
        self.name = name
        self.data = data
    }
}

/// Where events go. The SwiftUI sample sends them to Ravensight.track; the
/// tests record them.
public protocol NarrativeTelemetry: AnyObject {
    func send(_ event: NarrativeEvent)
}

/// The story state a reroll rolls back.
public struct StoryState: Codable, Equatable {
    /// Flags set by choices, by stable key.
    public var flags: [String: String] = [:]
    public var gold: Int = 10

    public init() {}
}

/// Everything saved for a run. The ids are persisted, so a resumed run
/// keeps reporting under the same run id and encounter id.
public struct RunState: Codable, Equatable {
    public var runId: String
    public var encounterSequence: Int = 0
    public var encounterId: String?
    public var encounterKey: String?
    /// 1 for the first attempt at the current encounter, then 2, 3 after
    /// each reroll.
    public var attempt: Int = 1
    public var story = StoryState()
    /// The story as it was when the current encounter began. A reroll
    /// restores it.
    public var encounterStart: StoryState?
    public var clock: ForegroundClock
    public var unlocks: Set<String> = []

    public init(runId: String, idleThreshold: Double = 60) {
        self.runId = runId
        self.clock = ForegroundClock(idleThreshold: idleThreshold)
    }
}

/// Saves and loads a run. FileRunStore is the real one; tests use memory.
public protocol RunStore: AnyObject {
    func load() -> RunState?
    func save(_ state: RunState)
    func clear()
}

public final class InMemoryRunStore: RunStore {
    public private(set) var saved: RunState?
    public init(_ saved: RunState? = nil) { self.saved = saved }
    public func load() -> RunState? { return saved }
    public func save(_ state: RunState) { saved = state }
    public func clear() { saved = nil }
}

public final class FileRunStore: RunStore {
    let url: URL
    public init(url: URL) { self.url = url }
    public func load() -> RunState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RunState.self, from: data)
    }
    public func save(_ state: RunState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
    public func clear() { try? FileManager.default.removeItem(at: url) }
}

/// The instrumented game loop. Every event carries run_id, and the
/// encounter events carry encounter_id, encounter_key and attempt, plus the
/// running foreground totals (cumulative, so a query takes MAX per run).
public final class NarrativeSession {
    public private(set) var state: RunState
    public private(set) var progression = ProgressionTracker()
    private let store: RunStore
    private let clock: MonotonicSource
    private weak var telemetry: NarrativeTelemetry?
    private let makeId: () -> String

    /// Resumes the saved run if there is one (same run id, same totals),
    /// otherwise starts a new run. Either way the progression baseline is
    /// taken from the save, and one snapshot event is sent for it.
    public init(
        store: RunStore,
        telemetry: NarrativeTelemetry?,
        clock: MonotonicSource = SystemMonotonicSource(),
        idleThreshold: Double = 60,
        makeId: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.store = store
        self.clock = clock
        self.telemetry = telemetry
        self.makeId = makeId
        if let saved = store.load() {
            state = saved
            send("run_resumed", [:])
        } else {
            state = RunState(runId: makeId(), idleThreshold: idleThreshold)
            send("run_started", [:])
        }
        let snapshot = progression.load(saved: state.unlocks)
        send(snapshot.name, snapshot.data)
    }

    // MARK: App lifecycle and input

    public func enterForeground() { state.clock.enterForeground(at: clock.seconds) }

    /// Leaving the foreground saves the run, so a force quit loses nothing
    /// but the time since.
    public func enterBackground() {
        state.clock.enterBackground(at: clock.seconds)
        save()
    }

    public func recordInput() { state.clock.recordInput(at: clock.seconds) }

    public var totals: ForegroundClock.Totals { return state.clock.totals(at: clock.seconds) }

    // MARK: Encounters

    /// Starts an encounter under a stable key (the content's own id, the
    /// same in every build), with a new encounter id persisted in the run.
    public func beginEncounter(key: String) {
        state.encounterSequence += 1
        state.encounterId = "\(state.runId)-e\(state.encounterSequence)"
        state.encounterKey = key
        state.attempt = 1
        state.encounterStart = state.story
        recordInput()
        send("encounter_started", encounterFields())
    }

    /// A choice, by stable keys: choice_key names the decision point,
    /// option_key the option. Display text never goes in an event.
    public func choose(choiceKey: String, optionKey: String, goldDelta: Int = 0) {
        guard state.encounterId != nil else { return }
        state.story.flags[choiceKey] = optionKey
        state.story.gold += goldDelta
        recordInput()
        var data = encounterFields()
        data["choice_key"] = choiceKey
        data["option_key"] = optionKey
        send("choice_made", data)
    }

    /// Rerolls the current encounter: the story rolls back to how it was
    /// when the encounter began and a new attempt starts. The encounter id
    /// stays; attempt goes up. Choices made in the abandoned attempt remain
    /// in the data under their old attempt number, which is how a query
    /// tells a final choice from a rerolled one.
    public func reroll() {
        guard state.encounterId != nil, let start = state.encounterStart else { return }
        let previous = state.attempt
        state.story = start
        state.attempt += 1
        recordInput()
        var data = encounterFields()
        data["previous_attempt"] = previous
        data["rolled_back"] = true
        send("encounter_rerolled", data)
    }

    public func completeEncounter() {
        guard state.encounterId != nil else { return }
        recordInput()
        send("encounter_completed", encounterFields())
        state.encounterStart = nil
        state.encounterId = nil
        state.encounterKey = nil
        state.attempt = 1
        save()
    }

    // MARK: Progression

    /// Unlocks are profile progress: a reroll does not take one back. Only
    /// a new earning sends unlock_earned.
    public func unlock(_ id: String) {
        guard let event = progression.unlock(id) else { return }
        state.unlocks.insert(id)
        send(event.name, event.data)
    }

    // MARK: Saving

    /// Saves the run, ids and totals included, and sends run_saved.
    public func save() {
        store.save(state)
        send("run_saved", [:])
    }

    /// Ends the run for good: the next launch starts a new run id.
    public func endRun(outcome: String) {
        send("run_ended", ["outcome": outcome])
        store.clear()
        state = RunState(runId: makeId(), idleThreshold: state.clock.idleThreshold)
        progression = ProgressionTracker()
        let snapshot = progression.load(saved: [])
        send("run_started", [:])
        send(snapshot.name, snapshot.data)
    }

    // MARK: Events

    private func encounterFields() -> [String: AnyHashable] {
        return [
            "encounter_id": state.encounterId ?? "",
            "encounter_key": state.encounterKey ?? "",
            "attempt": state.attempt,
        ]
    }

    private func send(_ name: String, _ extra: [String: AnyHashable]) {
        let totals = state.clock.totals(at: clock.seconds)
        var data = extra
        data["run_id"] = state.runId
        // Cumulative for the run: MAX per run in a query, never SUM.
        data["foreground_seconds_total"] = (totals.foregroundSeconds * 10).rounded() / 10
        data["idle_seconds_estimate_total"] = (totals.idleSecondsEstimate * 10).rounded() / 10
        telemetry?.send(NarrativeEvent(name: name, data: data))
    }
}
