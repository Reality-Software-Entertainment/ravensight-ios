import Foundation
#if canImport(MetricKit) && (os(iOS) || os(macOS))
import MetricKit

/// Receives the system's crash diagnostics. Swift traps, bad memory access
/// and other signals never reach the exception handler; the system records
/// them and, from iOS 15, delivers the diagnostic to a subscriber on the next
/// launch. The SDK installs no signal handler of its own.
final class RavensightMetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
    private let deliver: ([RavensightCrashDiagnostic]) -> Void

    init(deliver: @escaping ([RavensightCrashDiagnostic]) -> Void) {
        self.deliver = deliver
    }

    func start() {
        MXMetricManager.shared.add(self)
    }

    func stop() {
        MXMetricManager.shared.remove(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var found: [RavensightCrashDiagnostic] = []
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                found.append(RavensightMetricKitSubscriber.diagnostic(crash, payload: payload))
            }
        }
        if !found.isEmpty { deliver(found) }
    }

    static func diagnostic(_ crash: MXCrashDiagnostic, payload: MXDiagnosticPayload) -> RavensightCrashDiagnostic {
        var diagnostic = RavensightCrashDiagnostic(
            signal: crash.signal?.intValue,
            exceptionType: crash.exceptionType?.intValue,
            exceptionCode: crash.exceptionCode?.intValue,
            terminationReason: crash.terminationReason,
            frames: RavensightCrashDiagnostic.frames(fromCallStackTree: crash.callStackTree.jsonRepresentation()),
            beginSec: Int64(payload.timeStampBegin.timeIntervalSince1970),
            endSec: Int64(payload.timeStampEnd.timeIntervalSince1970)
        )
        if #available(iOS 17.0, macOS 14.0, *), let reason = crash.exceptionReason {
            diagnostic.objcExceptionName = reason.exceptionName
            diagnostic.objcMessage = reason.composedMessage
        }
        return diagnostic
    }
}
#endif
