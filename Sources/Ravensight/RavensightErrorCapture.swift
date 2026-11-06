import Foundation

// Automatic error capture: the pure pieces (scrub, caps, trail, the event
// shape) and the two crash sources (an Objective-C exception persisted by a
// chained uncaught exception handler, and MetricKit crash diagnostics), both
// sent on the next launch. Nothing here performs network I/O.

/// One automatic capture, before the scrub and the caps.
struct RavensightCapture: Equatable {
    var source: String
    var severity: String
    var message: String
    var stack: String?
    var type: String?
    /// Unix seconds the error happened, when earlier than now (a crash from
    /// the last launch). Nil means now.
    var atSec: Int64?
}

/// The level of a line sent with Ravensight.log.
public enum RavensightLogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}

/// The contract's on-device text rules.
enum RavensightErrorText {
    static let maxMessage = 200
    static let maxStack = 2000
    static let maxType = 100
    static let maxTrail = 1500
    static let maxTrailLine = 120
    static let trailLines = 20

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // The patterns are constants; a bad one is a programming error.
        return try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// The server's rules (src/services/errorScrub.js), in its order: a URL
    /// loses its query, fragment and any user:password@; bearer tokens,
    /// JWT-shaped strings and gt_ keys become [token]; emails become
    /// [email]; home directories become ~; IPv4, and IPv6 with a digit in
    /// it, become [ip]; a run of 32 or more [A-Za-z0-9+/=_-] characters
    /// with a digit becomes [token] unless it is a path (it has a '/' and
    /// every piece is empty or a path word under 32 characters). The binding
    /// cases are docs/errors/scrub-vectors.json, copied into the tests.
    private static let rules: [(NSRegularExpression, String)] = [
        (regex("\\b([a-z][a-z0-9+.-]*://)(?:[^\\s/?#@'\"<>]*@)?([^\\s?#'\"<>]*)(?:[?#][^\\s'\"<>]*)?", .caseInsensitive), "$1$2"),
        (regex("\\bBearer\\s+[A-Za-z0-9\\-._~+/]+=*", .caseInsensitive), "[token]"),
        (regex("\\beyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]*"), "[token]"),
        (regex("\\bgt_[A-Za-z0-9_]+"), "[token]"),
        (regex("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"), "[email]"),
        (regex("\\b[A-Za-z]:[\\\\/]Users[\\\\/][^\\\\/\\s'\"]+", .caseInsensitive), "~"),
        (regex("/(?:Users|home)/[^/\\s'\"]+"), "~"),
        (regex("\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b"), "[ip]"),
        (regex("\\b(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}\\b", .caseInsensitive), "[ip]"),
    ]
    private static let ipv6Short = regex(
        "(?:\\b[0-9a-f]{1,4}(?::[0-9a-f]{1,4}){0,6})?::(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4}){0,6}\\b)?", .caseInsensitive)
    private static let longRun = regex("[A-Za-z0-9+/=_-]{32,}")
    /// A path word is one or more parts joined by "_" or "-", each part
    /// lowercase, CamelCase, or an acronym of 1 to 6 capitals or digits.
    private static let pathParts = [
        regex("^[a-z0-9]+$"),
        regex("^[A-Z][a-z0-9]*(?:[A-Z][a-z0-9]+)*$"), regex("^[A-Z0-9]{1,6}$"),
    ]
    private static let maxPathWord = 32

    private static func hasDigit(_ text: String) -> Bool {
        return text.unicodeScalars.contains { $0.value >= 48 && $0.value <= 57 }
    }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        return pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// A run that is a file path, not a secret.
    static func isPath(_ run: String) -> Bool {
        guard run.contains("/") else { return false }
        return run.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { piece in
            if piece.isEmpty { return true }
            guard piece.count < maxPathWord else { return false }
            return piece.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "_" || $0 == "-" }).allSatisfy { part in
                let word = String(part)
                return !word.isEmpty && pathParts.contains { matches($0, word) }
            }
        }
    }

    /// Replaces each match with what transform returns for it.
    private static func replace(_ pattern: NSRegularExpression, in text: String, _ transform: (String) -> String) -> String {
        let ns = text as NSString
        let result = NSMutableString(string: ns)
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            result.replaceCharacters(in: match.range, with: transform(ns.substring(with: match.range)))
        }
        return result as String
    }

    static func scrub(_ value: String) -> String {
        guard !value.isEmpty else { return value }
        var text = value
        for (pattern, template) in rules {
            let range = NSRange(text.startIndex..., in: text)
            text = pattern.stringByReplacingMatches(in: text, range: range, withTemplate: template)
        }
        text = replace(ipv6Short, in: text) { hasDigit($0) ? "[ip]" : $0 }
        return replace(longRun, in: text) { hasDigit($0) && !isPath($0) ? "[token]" : $0 }
    }

    /// Cut to four times max, scrub, then cut to max. The first cut keeps
    /// the scrub's cost bounded on a huge input (some rules are quadratic).
    static func clean(_ value: String, _ max: Int) -> String {
        return RavensightTypedEvents.cut(scrub(RavensightTypedEvents.cut(value, max * 4)), max)
    }

    private static let templateRules: [(NSRegularExpression, String)] = [
        (regex("[a-z][a-z0-9+.-]*://\\S+", .caseInsensitive), "<url>"),
        (regex("([\"'`])[^\"'`]{0,200}\\1"), "<str>"),
        (regex("\\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\b", .caseInsensitive), "<uuid>"),
        (regex("\\b(?:0x)?[0-9a-f]{8,}\\b", .caseInsensitive), "<hex>"),
        (regex("\\d+"), "<n>"),
    ]

    /// The local dedupe template: URLs, quoted text, UUIDs, hex runs and
    /// numbers become placeholders.
    static func template(_ message: String) -> String {
        var text = message
        for (pattern, replacement) in templateRules {
            text = pattern.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
        }
        return text
    }

    /// The first stack line, templated so addresses and offsets do not
    /// split one error into many keys.
    static func firstFrame(_ stack: String?) -> String {
        guard let stack = stack else { return "" }
        for line in stack.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return template(trimmed) }
        }
        return ""
    }

    /// The local dedupe key: type plus message template plus first frame.
    static func dedupeKey(type: String, message: String, stack: String?) -> String {
        return type + "\u{0}" + template(message) + "\u{0}" + firstFrame(stack)
    }
}

/// The per-session device caps. These bound spend; the server adds no cap.
struct RavensightErrorCaps {
    static let total = 30
    static let perKey = 3
    static let trails = 10
    static let perMinute = 6

    private(set) var count = 0
    private(set) var trailCount = 0
    private var perKeyCounts: [String: Int] = [:]
    private var tokens = Double(RavensightErrorCaps.perMinute)
    private var refilledAtMs: Int64

    init(nowMs: Int64) {
        refilledAtMs = nowMs
    }

    /// True when one more capture with this key may be sent now; consumes
    /// its share of every cap. False drops it silently.
    mutating func admit(key: String, nowMs: Int64) -> Bool {
        let perMs = Double(RavensightErrorCaps.perMinute) / 60_000
        tokens = min(Double(RavensightErrorCaps.perMinute), tokens + Double(max(0, nowMs - refilledAtMs)) * perMs)
        refilledAtMs = nowMs
        guard count < RavensightErrorCaps.total, tokens >= 1,
              perKeyCounts[key, default: 0] < RavensightErrorCaps.perKey else { return false }
        count += 1
        tokens -= 1
        perKeyCounts[key, default: 0] += 1
        return true
    }

    /// True when this capture may carry the trail (at most 10 a session).
    mutating func takeTrail() -> Bool {
        guard trailCount < RavensightErrorCaps.trails else { return false }
        trailCount += 1
        return true
    }
}

/// The in-memory ring of the last 20 lines, never persisted, sent only
/// with an error.
struct RavensightTrail {
    private(set) var lines: [String] = []

    mutating func add(level: String, text: String, elapsedMs: Int64) {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let line = "+\(max(0, elapsedMs)) \(level) \(flat)"
        lines.append(RavensightErrorText.clean(line, RavensightErrorText.maxTrailLine))
        if lines.count > RavensightErrorText.trailLines { lines.removeFirst() }
    }

    mutating func clear() {
        lines.removeAll()
    }

    /// Oldest first, joined by newlines, oldest lines dropped to fit 1,500.
    var text: String {
        var kept = lines
        var joined = kept.joined(separator: "\n")
        while joined.count > RavensightErrorText.maxTrail && kept.count > 1 {
            kept.removeFirst()
            joined = kept.joined(separator: "\n")
        }
        return RavensightTypedEvents.cut(joined, RavensightErrorText.maxTrail)
    }
}

extension RavensightErrorText {
    /// The event data for a capture: scrubbed, cut, top level only, never
    /// rs_fp. Returns the data and the dedupe key.
    static func eventData(_ capture: RavensightCapture, trail: String?) -> (data: [String: Any], key: String) {
        var message = clean(capture.message, maxMessage)
        if message.isEmpty { message = "(no message)" }
        let stack = capture.stack.map { clean($0, maxStack) } ?? ""
        let type = capture.type.map { clean($0, maxType) } ?? ""
        var data: [String: Any] = [
            "rs_kind": "error",
            "rs_severity": capture.severity,
            "rs_message": message,
            "rs_source": capture.source,
        ]
        if !type.isEmpty { data["rs_error_type"] = type }
        if !stack.isEmpty { data["rs_stack"] = stack }
        if let trail = trail, !trail.isEmpty { data["rs_trail"] = trail }
        return (data, dedupeKey(type: type, message: message, stack: stack.isEmpty ? nil : stack))
    }
}

// MARK: Crash file

/// The file an Objective-C exception is written to as the app dies, read
/// and deleted on the next launch. At most 5 reports, already scrubbed.
enum RavensightCrashFile {
    static let maxReports = 5

    static func defaultURL(ingestKey: String, directory: URL? = nil) -> URL? {
        guard let queue = RavensightQueueStore.defaultFileURL(ingestKey: ingestKey, directory: directory) else { return nil }
        return queue.deletingLastPathComponent()
            .appendingPathComponent("crash-\(RavensightQueueStore.shortHash(ingestKey)).json")
    }

    /// Appends one report. Called from the dying thread: no locks taken
    /// beyond the file system's, every failure ignored.
    static func append(_ capture: RavensightCapture, to url: URL) {
        var reports = load(url)
        guard reports.count < maxReports else { return }
        reports.append(capture)
        let encoded: [[String: Any]] = reports.map { report in
            var object: [String: Any] = [
                "source": report.source, "severity": report.severity, "message": report.message,
            ]
            if let stack = report.stack { object["stack"] = stack }
            if let type = report.type { object["type"] = type }
            if let at = report.atSec { object["atSec"] = at }
            return object
        }
        guard let data = try? JSONSerialization.data(withJSONObject: encoded) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }

    static func load(_ url: URL) -> [RavensightCapture] {
        guard let data = try? Data(contentsOf: url),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return array.prefix(maxReports).compactMap { object in
            guard let message = object["message"] as? String else { return nil }
            return RavensightCapture(
                source: object["source"] as? String ?? "crash",
                severity: object["severity"] as? String ?? "critical",
                message: message,
                stack: object["stack"] as? String,
                type: object["type"] as? String,
                atSec: RavensightCore.numberValue(object["atSec"]).map { Int64($0) }
            )
        }
    }

    static func delete(_ url: URL?) {
        guard let url = url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: Objective-C exceptions

#if canImport(ObjectiveC)
/// The process-wide uncaught exception hook. Installed once, chained to the
/// handler that was there before (always called after ours), and made inert
/// rather than removed when another handler was installed after it.
enum RavensightExceptionHook {
    typealias ExceptionHandler = @convention(c) (NSException) -> Void
    private static let lock = NSLock()
    #if compiler(>=5.10)
    nonisolated(unsafe) private static var installed = false
    nonisolated(unsafe) private static var previous: ExceptionHandler?
    nonisolated(unsafe) private static var target: URL?
    #else
    private static var installed = false
    private static var previous: ExceptionHandler?
    private static var target: URL?
    #endif

    fileprivate static func chained() -> ExceptionHandler? {
        lock.lock()
        defer { lock.unlock() }
        return previous
    }

    /// Points the hook at a crash file, installing it the first time.
    static func activate(fileURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        target = fileURL
        guard !installed else { return }
        previous = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(ravensightUncaughtException)
        installed = true
    }

    /// Makes the hook inert for this file. If ours is still the installed
    /// handler, the previous one is put back.
    static func deactivate(fileURL: URL?) {
        lock.lock()
        defer { lock.unlock() }
        guard fileURL == nil || target == fileURL else { return }
        target = nil
        let ours: ExceptionHandler = ravensightUncaughtException
        guard installed, let current = NSGetUncaughtExceptionHandler(),
              unsafeBitCast(current, to: UnsafeRawPointer.self) == unsafeBitCast(ours, to: UnsafeRawPointer.self)
        else { return }
        NSSetUncaughtExceptionHandler(previous)
        previous = nil
        installed = false
    }

    /// Forgets the hook's state. Tests only, with the process handler
    /// restored by the test itself.
    static func resetForTesting() {
        lock.lock()
        installed = false
        previous = nil
        target = nil
        lock.unlock()
    }

    static var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return target != nil
    }

    /// The capture for an exception: scrubbed here, before it touches disk.
    static func capture(for exception: NSException, atSec: Int64) -> RavensightCapture {
        let name = exception.name.rawValue
        let reason = exception.reason ?? ""
        let stack = exception.callStackSymbols.joined(separator: "\n")
        return RavensightCapture(
            source: "crash",
            severity: "critical",
            message: RavensightErrorText.clean(reason.isEmpty ? name : reason, RavensightErrorText.maxMessage),
            stack: stack.isEmpty ? nil : RavensightErrorText.clean(stack, RavensightErrorText.maxStack),
            type: RavensightErrorText.clean(name, RavensightErrorText.maxType),
            atSec: atSec
        )
    }

    fileprivate static func record(_ exception: NSException) {
        lock.lock()
        let url = target
        lock.unlock()
        guard let url = url else { return }
        RavensightCrashFile.append(
            capture(for: exception, atSec: Int64(Date().timeIntervalSince1970)), to: url)
    }
}

/// The handler itself: saves the exception, then always calls the handler
/// that was installed before, so the game's behaviour does not change.
private func ravensightUncaughtException(_ exception: NSException) {
    RavensightExceptionHook.record(exception)
    RavensightExceptionHook.chained()?(exception)
}
#endif

// MARK: Crash diagnostics (MetricKit, or a test)

/// The parts of a crash diagnostic the SDK reads, free of MetricKit types.
struct RavensightCrashDiagnostic: Equatable {
    var signal: Int?
    var exceptionType: Int?
    var exceptionCode: Int?
    var terminationReason: String?
    /// iOS 17 and newer: the Objective-C exception behind the crash.
    var objcExceptionName: String?
    var objcMessage: String?
    /// The crashed thread's frames, "binary +offset", at most 12.
    var frames: [String] = []
    /// The payload's window, unix seconds.
    var beginSec: Int64
    var endSec: Int64

    static let maxFrames = 12

    static func signalName(_ signal: Int) -> String {
        switch signal {
        case 4: return "SIGILL"
        case 5: return "SIGTRAP"
        case 6: return "SIGABRT"
        case 8: return "SIGFPE"
        case 9: return "SIGKILL"
        case 10: return "SIGBUS"
        case 11: return "SIGSEGV"
        case 13: return "SIGPIPE"
        default: return "SIG\(signal)"
        }
    }

    static func machExceptionName(_ type: Int) -> String {
        switch type {
        case 1: return "EXC_BAD_ACCESS"
        case 2: return "EXC_BAD_INSTRUCTION"
        case 3: return "EXC_ARITHMETIC"
        case 6: return "EXC_BREAKPOINT"
        case 10: return "EXC_CRASH"
        case 11: return "EXC_RESOURCE"
        case 12: return "EXC_GUARD"
        default: return "EXC_\(type)"
        }
    }

    /// Identifies one diagnostic across deliveries, so it is sent once.
    var identity: String {
        return "\(beginSec)|\(endSec)|\(signal ?? -1)|\(exceptionType ?? -1)|\(exceptionCode ?? -1)|\(frames.first ?? "")"
    }

    /// A short description: no full call stack tree, only the crashed
    /// thread's top frames.
    var capture: RavensightCapture {
        let type: String
        var parts: [String] = []
        if let name = objcExceptionName, !name.isEmpty {
            type = name
            parts.append(objcMessage ?? name)
        } else if let signal = signal {
            type = RavensightCrashDiagnostic.signalName(signal)
            parts.append("Crashed with " + type)
            if let exception = exceptionType {
                parts.append("(" + RavensightCrashDiagnostic.machExceptionName(exception) + ")")
            }
        } else if let exception = exceptionType {
            type = RavensightCrashDiagnostic.machExceptionName(exception)
            parts.append("Crashed with " + type)
        } else {
            type = "Crash"
            parts.append("Crashed")
        }
        if let reason = terminationReason, !reason.isEmpty { parts.append(reason) }
        let frames = Array(self.frames.prefix(RavensightCrashDiagnostic.maxFrames))
        return RavensightCapture(
            source: "crash",
            severity: "critical",
            message: parts.joined(separator: " "),
            stack: frames.isEmpty ? nil : frames.joined(separator: "\n"),
            type: type,
            atSec: endSec
        )
    }

    /// The crashed thread's frames from a call stack tree's JSON, walked
    /// from the first root frame down its first sub frames.
    static func frames(fromCallStackTree data: Data) -> [String] {
        guard let tree = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stacks = tree["callStacks"] as? [[String: Any]], !stacks.isEmpty else { return [] }
        let stack = stacks.first(where: { ($0["threadAttributed"] as? Bool) == true }) ?? stacks[0]
        var frame = (stack["callStackRootFrames"] as? [[String: Any]])?.first
        var out: [String] = []
        while let current = frame, out.count < maxFrames {
            let binary = current["binaryName"] as? String ?? "?"
            let offset = RavensightCore.numberValue(current["offsetIntoBinaryTextSegment"]).map { Int64($0) }
            out.append(offset.map { "\(binary) +\($0)" } ?? binary)
            frame = (current["subFrames"] as? [[String: Any]])?.first
        }
        return out
    }
}
