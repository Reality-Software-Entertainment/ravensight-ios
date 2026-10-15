import XCTest
@testable import NarrativeKit

final class ManualClock: MonotonicSource {
    var seconds: Double = 1000
    func advance(_ by: Double) { seconds += by }
}

final class Recorder: NarrativeTelemetry {
    var events: [NarrativeEvent] = []
    func send(_ event: NarrativeEvent) { events.append(event) }
    func names() -> [String] { events.map { $0.name } }
    func last(_ name: String) -> NarrativeEvent? { events.last { $0.name == name } }
}

final class ForegroundClockTests: XCTestCase {
    func testCountsForegroundOnly() {
        var clock = ForegroundClock(idleThreshold: 60)
        clock.enterForeground(at: 0)
        clock.recordInput(at: 30)
        clock.enterBackground(at: 50)
        // Ten minutes in the background count for nothing.
        clock.enterForeground(at: 650)
        XCTAssertEqual(clock.totals(at: 660).foregroundSeconds, 60)
        XCTAssertEqual(clock.totals(at: 660).idleSecondsEstimate, 0)
    }

    func testIdleIsTheGapBeyondTheThreshold() {
        var clock = ForegroundClock(idleThreshold: 60)
        clock.enterForeground(at: 0)
        clock.recordInput(at: 100) // a 100 second gap adds 40
        clock.recordInput(at: 130) // under the threshold adds nothing
        XCTAssertEqual(clock.totals(at: 130).idleSecondsEstimate, 40)
        // The open trailing gap counts in a running total, and at background.
        XCTAssertEqual(clock.totals(at: 230).idleSecondsEstimate, 80)
        clock.enterBackground(at: 230)
        XCTAssertEqual(clock.idleSecondsEstimate, 80)
        XCTAssertEqual(clock.foregroundSeconds, 230)
        XCTAssertEqual(clock.totals(at: 230).engagedSecondsEstimate, 150)
    }

    func testTotalsNeverDecreaseAndInputInTheBackgroundIsIgnored() {
        var clock = ForegroundClock(idleThreshold: 10)
        clock.enterForeground(at: 0)
        var previous = 0.0
        for t in stride(from: 0.0, through: 200, by: 7) {
            if Int(t) % 3 == 0 { clock.recordInput(at: t) }
            let total = clock.totals(at: t).foregroundSeconds
            XCTAssertGreaterThanOrEqual(total, previous)
            previous = total
        }
        clock.enterBackground(at: 200)
        clock.recordInput(at: 300)
        XCTAssertEqual(clock.totals(at: 400).foregroundSeconds, 200)
    }

    func testOnlyTotalsAreSavedNeverMonotonicReadings() throws {
        var clock = ForegroundClock(idleThreshold: 60)
        clock.enterForeground(at: 5_000)
        clock.enterBackground(at: 5_120)
        clock.enterForeground(at: 9_000)
        let data = try JSONEncoder().encode(clock)
        var restored = try JSONDecoder().decode(ForegroundClock.self, from: data)
        XCTAssertFalse(restored.isInForeground, "a reading from another launch is meaningless")
        XCTAssertEqual(restored.foregroundSeconds, 120)
        // A new launch has a fresh monotonic base (uptime may even be lower).
        restored.enterForeground(at: 3)
        XCTAssertEqual(restored.totals(at: 13).foregroundSeconds, 130)
    }
}

final class NarrativeSessionTests: XCTestCase {
    private var ids = 0
    private func makeId() -> String { ids += 1; return "run_\(ids)" }

    func testSaveAndResumeKeepTheRunIdAndTotals() {
        let store = InMemoryRunStore()
        let clock = ManualClock()
        let first = Recorder()
        let session = NarrativeSession(store: store, telemetry: first, clock: clock, makeId: makeId)
        session.enterForeground()
        session.beginEncounter(key: "ferry_crossing")
        clock.advance(90)
        session.enterBackground() // saves

        let second = Recorder()
        let resumed = NarrativeSession(store: store, telemetry: second, clock: clock, makeId: makeId)
        XCTAssertEqual(resumed.state.runId, "run_1")
        XCTAssertEqual(resumed.state.encounterId, "run_1-e1", "the encounter id is persisted too")
        XCTAssertEqual(second.names().first, "run_resumed")
        XCTAssertEqual(second.events.first?.data["run_id"], "run_1")
        XCTAssertEqual(second.events.first?.data["foreground_seconds_total"], 90.0)
        resumed.enterForeground()
        clock.advance(10)
        resumed.choose(choiceKey: "ferryman_toll", optionKey: "pay")
        XCTAssertEqual(second.last("choice_made")?.data["foreground_seconds_total"], 100.0, "cumulative across launches")
    }

    func testRerollIsANewAttemptThatRollsTheStoryBack() {
        let recorder = Recorder()
        let session = NarrativeSession(store: InMemoryRunStore(), telemetry: recorder, clock: ManualClock(), makeId: makeId)
        session.enterForeground()
        session.choose(choiceKey: "ignored", optionKey: "x") // no encounter yet: nothing happens
        XCTAssertNil(recorder.last("choice_made"))

        session.beginEncounter(key: "ferry_crossing")
        let goldBefore = session.state.story.gold
        session.choose(choiceKey: "ferryman_toll", optionKey: "pay", goldDelta: -3)
        XCTAssertEqual(session.state.story.gold, goldBefore - 3)
        XCTAssertEqual(recorder.last("choice_made")?.data["attempt"], 1)

        session.reroll()
        XCTAssertEqual(session.state.story.gold, goldBefore, "rolled back")
        XCTAssertNil(session.state.story.flags["ferryman_toll"])
        XCTAssertEqual(session.state.attempt, 2)
        let rerolled = recorder.last("encounter_rerolled")
        XCTAssertEqual(rerolled?.data["attempt"], 2)
        XCTAssertEqual(rerolled?.data["previous_attempt"], 1)
        XCTAssertEqual(rerolled?.data["rolled_back"], true)
        XCTAssertEqual(rerolled?.data["encounter_id"], "run_1-e1", "same encounter, new attempt")

        session.choose(choiceKey: "ferryman_toll", optionKey: "refuse")
        XCTAssertEqual(recorder.last("choice_made")?.data["attempt"], 2)
        XCTAssertEqual(recorder.last("choice_made")?.data["option_key"], "refuse")
        session.completeEncounter()
        XCTAssertEqual(recorder.last("encounter_completed")?.data["attempt"], 2, "the final attempt is on the completion")

        session.reroll() // nothing to reroll after completion
        XCTAssertEqual(recorder.events.filter { $0.name == "encounter_rerolled" }.count, 1)
    }

    func testLoadedProgressionSendsASnapshotAndOnlyNewEarningsSendUnlocks() {
        var saved = RunState(runId: "run_saved")
        saved.unlocks = ["ferry_crossed", "met_the_witch"]
        let recorder = Recorder()
        let session = NarrativeSession(store: InMemoryRunStore(saved), telemetry: recorder, clock: ManualClock(), makeId: makeId)

        XCTAssertEqual(recorder.names(), ["run_resumed", "progression_loaded"])
        XCTAssertEqual(recorder.last("progression_loaded")?.data["unlocked_count"], 2)
        XCTAssertTrue(recorder.events.filter { $0.name == "unlock_earned" }.isEmpty, "loaded unlocks are not earnings")

        session.unlock("ferry_crossed") // already had it
        XCTAssertNil(recorder.last("unlock_earned"))
        session.unlock("found_the_map") // new
        session.unlock("found_the_map") // twice in a session is one earning
        let unlocks = recorder.events.filter { $0.name == "unlock_earned" }
        XCTAssertEqual(unlocks.count, 1)
        XCTAssertEqual(unlocks.first?.data["unlock_id"], "found_the_map")
        XCTAssertEqual(unlocks.first?.data["unlocked_count"], 3)
    }

    func testEndingARunStartsANewRunId() {
        let store = InMemoryRunStore()
        let recorder = Recorder()
        let session = NarrativeSession(store: store, telemetry: recorder, clock: ManualClock(), makeId: makeId)
        session.save()
        session.endRun(outcome: "died")
        XCTAssertEqual(session.state.runId, "run_2")
        XCTAssertNil(store.saved)
        XCTAssertEqual(recorder.last("run_ended")?.data["run_id"], "run_1")
        XCTAssertEqual(recorder.last("run_started")?.data["run_id"], "run_2")
    }
}
