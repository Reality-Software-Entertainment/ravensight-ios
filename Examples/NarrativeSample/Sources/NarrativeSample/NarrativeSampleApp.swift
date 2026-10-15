import SwiftUI
import Ravensight
import NarrativeKit

/// Sends NarrativeKit events through Ravensight.track. track() returns
/// queue acceptance; delivery is in Ravensight.stats and onFlush.
final class RavensightTelemetry: NarrativeTelemetry {
    func send(_ event: NarrativeEvent) {
        Ravensight.track(event.name, data: event.data.mapValues { $0.base })
    }
}

@main
struct NarrativeSampleApp: App {
    @StateObject private var model = GameModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            GameView(model: model)
                .onChange(of: scenePhase) { phase in
                    model.scenePhaseChanged(phase)
                }
        }
    }
}

@MainActor
final class GameModel: ObservableObject {
    private let telemetry = RavensightTelemetry()
    let session: NarrativeSession
    @Published var log: [String] = []

    init() {
        // Set RAVENSIGHT_INGEST_KEY in the scheme's environment to send
        // events; without a key the SDK is built disabled and sends nothing.
        let key = ProcessInfo.processInfo.environment["RAVENSIGHT_INGEST_KEY"] ?? ""
        var configuration = RavensightConfiguration(ingestKey: key)
        configuration.enabled = key.hasPrefix("gt_live_")
        configuration.persistQueue = true
        Ravensight.start(configuration)

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let store = FileRunStore(url: support.appendingPathComponent("NarrativeSample/run.json"))
        session = NarrativeSession(store: store, telemetry: telemetry)
        session.enterForeground()
        note("run \(session.state.runId)")
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active: session.enterForeground()
        case .background: session.enterBackground()
        default: break
        }
    }

    func note(_ line: String) {
        let totals = session.totals
        log.insert(String(format: "%@  (foreground %.0fs, idle estimate %.0fs)", line, totals.foregroundSeconds, totals.idleSecondsEstimate), at: 0)
    }

    func begin() { session.beginEncounter(key: "ferry_crossing"); note("encounter \(session.state.encounterId ?? "")") }
    func pay() { session.choose(choiceKey: "ferryman_toll", optionKey: "pay", goldDelta: -3); note("paid the ferryman") }
    func refuse() { session.choose(choiceKey: "ferryman_toll", optionKey: "refuse"); note("refused the ferryman") }
    func reroll() { session.reroll(); note("reroll, attempt \(session.state.attempt)") }
    func complete() { session.unlock("ferry_crossed"); session.completeEncounter(); note("encounter complete") }
    func save() { session.save(); note("saved") }
}

struct GameView: View {
    @ObservedObject var model: GameModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Narrative sample").font(.title2)
            HStack {
                Button("Begin encounter", action: model.begin)
                Button("Pay toll", action: model.pay)
                Button("Refuse", action: model.refuse)
            }
            HStack {
                Button("Reroll", action: model.reroll)
                Button("Complete", action: model.complete)
                Button("Save", action: model.save)
            }
            List(Array(model.log.enumerated()), id: \.offset) { Text($0.element).font(.caption.monospaced()) }
        }
        .padding()
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { model.session.recordInput() })
    }
}
