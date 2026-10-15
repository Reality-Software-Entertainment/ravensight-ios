import Foundation

/// Earned versus loaded progression.
///
/// Loading a save restores unlocks the player earned in an earlier session.
/// Sending an unlock event for each of them would count the same unlock
/// again on every launch. So a load records one baseline snapshot event,
/// and an unlock event is sent only for something earned now that is not
/// in the baseline.
public struct ProgressionTracker: Equatable {
    /// What the save already had when it was loaded.
    public private(set) var baseline: Set<String> = []
    /// What was earned since the load.
    public private(set) var earned: Set<String> = []

    public init() {}

    public var all: Set<String> { return baseline.union(earned) }

    /// Takes the baseline from a save. Returns the snapshot event to send
    /// (progression_loaded), never one unlock event per item.
    public mutating func load(saved: Set<String>) -> NarrativeEvent {
        baseline = saved
        earned = []
        return NarrativeEvent(name: "progression_loaded", data: [
            "unlocked_count": saved.count,
        ])
    }

    /// Records an unlock. Returns the unlock_earned event only when it is a
    /// new earning: nil for anything in the baseline or already earned.
    public mutating func unlock(_ id: String) -> NarrativeEvent? {
        guard !baseline.contains(id), !earned.contains(id) else { return nil }
        earned.insert(id)
        return NarrativeEvent(name: "unlock_earned", data: [
            "unlock_id": id,
            "unlocked_count": all.count,
        ])
    }
}
