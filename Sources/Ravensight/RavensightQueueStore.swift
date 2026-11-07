import Foundation

/// The persisted queue (RavensightConfiguration.persistQueue, on by default):
/// one small JSON file under Application Support, rewritten atomically
/// whenever the queue changes and read once when the client is created.
///
/// Format version 2 (docs/sdk/DELIVERY_CONTRACT.md section 2): each group of
/// events carries the origin of the session it was tracked under, exactly as
/// the /session answer gave it, so events a crash, a kill or a lost network
/// left behind are filed under their own session, build and platform when
/// the next launch sends them. Version 1 files are read as groups without an
/// origin. Session tokens, signing secrets and an error's rs_trail are
/// never written.
///
/// Only touched on the client's work queue (and in the initializer, before
/// the client is shared), so it needs no lock of its own.
final class RavensightQueueStore {
    /// The most events ever written, whatever maxQueueSize says.
    static let maxEvents = 500
    /// Events older than this are not restored: the server ignores events
    /// older than 90 days.
    static let maxAgeSeconds: Int64 = 89 * 86_400
    static let formatVersion = 2

    struct Group {
        /// The session's origin as received, nil when it had none.
        var origin: [String: Any]?
        var events: [RavensightEvent]
    }

    /// Consecutive events with the same origin, in queue order.
    static func groups(_ events: [RavensightEvent]) -> [Group] {
        var out: [Group] = []
        for event in events {
            let session = event.origin?["session"] as? String
            if let last = out.last, (last.origin?["session"] as? String) == session {
                out[out.count - 1].events.append(event)
            } else {
                out.append(Group(origin: event.origin, events: [event]))
            }
        }
        return out
    }

    let fileURL: URL

    /// The one temporary file an atomic write goes through, beside fileURL.
    var tempURL: URL { return fileURL.appendingPathExtension("tmp") }

    /// Told (with no file contents) when the backup exclusion could not be
    /// set even after one retry. The client logs it once.
    var onExclusionFailure: ((String) -> Void)?
    private var warnedExclusion = false

    /// Sets the backup exclusion on a URL. A test seam; the default asks
    /// the file system.
    var setExcluded: (URL) throws -> Void = { url in
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Marks url excluded from device backups, checks it took, and retries
    /// once. The queue holds scrubbed error captures and origin stamps.
    @discardableResult
    func excludeFromBackup(_ url: URL) -> Bool {
        for _ in 0..<2 {
            if (try? setExcluded(url)) != nil,
               (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true {
                return true
            }
        }
        if !warnedExclusion {
            warnedExclusion = true
            onExclusionFailure?("could not exclude the queue file from device backups (\(url.lastPathComponent))")
        }
        return false
    }

    /// Where the queue folder lives: Application Support, except on tvOS,
    /// where an app may keep files only in Caches (which the system can
    /// purge under storage pressure; the queue is then simply empty).
    #if os(tvOS)
    static let defaultSearchPath: FileManager.SearchPathDirectory = .cachesDirectory
    #else
    static let defaultSearchPath: FileManager.SearchPathDirectory = .applicationSupportDirectory
    #endif

    /// Application Support/Ravensight/queue-<key hash>.json (Caches on
    /// tvOS). The key hash keeps two clients with different ingest keys apart.
    static func defaultFileURL(ingestKey: String, directory: URL? = nil) -> URL? {
        let base: URL
        if let directory = directory {
            base = directory
        } else {
            guard let support = FileManager.default.urls(for: defaultSearchPath, in: .userDomainMask).first else {
                return nil
            }
            base = support.appendingPathComponent("Ravensight", isDirectory: true)
        }
        return base.appendingPathComponent("queue-\(shortHash(ingestKey)).json")
    }

    /// FNV-1a, 64 bit, as hex. Only names a file; not a security boundary.
    static func shortHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    /// Reads the file. A missing, unreadable or malformed file is an empty
    /// queue. Events older than maxAgeSeconds are left out.
    func load(nowMs: Int64) -> (groups: [Group], dropped: Int) {
        // A write a crash cut short leaves its temporary file behind.
        try? FileManager.default.removeItem(at: tempURL)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            // A file an earlier release wrote may not carry the exclusion.
            excludeFromBackup(fileURL)
        }
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = (object["version"] as? NSNumber)?.intValue, version == 1 || version == 2,
              let groups = object["groups"] as? [[String: Any]] else { return ([], 0) }
        var dropped = 0
        // Version 1 stored unix seconds; version 2 stores milliseconds.
        let scale: Int64 = version == 1 ? 1000 : 1
        let oldest = nowMs - RavensightQueueStore.maxAgeSeconds * 1000
        var total = 0
        var result: [Group] = []
        for raw in groups {
            let origin = version == 2 ? raw["origin"] as? [String: Any] : nil
            let rawEvents = raw["events"] as? [[String: Any]] ?? []
            var events: [RavensightEvent] = []
            for entry in rawEvents {
                guard let name = entry["event"] as? String, !name.isEmpty,
                      let stored = (entry["timestamp"] as? NSNumber)?.int64Value,
                      stored * scale >= oldest else {
                    dropped += 1
                    continue
                }
                let payload = entry["data"] as? [String: Any] ?? [:]
                events.append(RavensightEvent(name: name, data: payload, timestamp: stored * scale, origin: origin, restored: true))
            }
            total += events.count
            if !events.isEmpty {
                result.append(Group(origin: origin, events: events))
            }
        }
        // Keep the newest maxEvents across all groups.
        var excess = total - RavensightQueueStore.maxEvents
        var index = 0
        while excess > 0 && index < result.count {
            let cut = min(excess, result[index].events.count)
            result[index].events.removeFirst(cut)
            excess -= cut
            dropped += cut
            index += 1
        }
        return (result.filter { !$0.events.isEmpty }, dropped)
    }

    /// Writes the groups atomically (a temporary file renamed over the old
    /// one), keeping only the newest maxEvents. An empty queue deletes the
    /// file. Returns false when the write failed; the queue in memory is
    /// unaffected either way.
    @discardableResult
    func save(_ groups: [Group]) -> Bool {
        var trimmed = groups.filter { !$0.events.isEmpty }
        var excess = trimmed.reduce(0) { $0 + $1.events.count } - RavensightQueueStore.maxEvents
        var index = 0
        while excess > 0 && index < trimmed.count {
            let cut = min(excess, trimmed[index].events.count)
            trimmed[index].events.removeFirst(cut)
            excess -= cut
            index += 1
        }
        trimmed = trimmed.filter { !$0.events.isEmpty }
        if trimmed.isEmpty {
            delete()
            return true
        }
        let object: [String: Any] = [
            "version": RavensightQueueStore.formatVersion,
            "groups": trimmed.map { group -> [String: Any] in
                var entry: [String: Any] = [
                    // A trail never reaches the queue file (queue rule 3): the
                    // event keeps it in memory; one restored goes without it.
                    "events": group.events.map { event -> [String: Any] in
                        var data = event.data
                        data.removeValue(forKey: "rs_trail")
                        return ["event": event.name, "data": data, "timestamp": event.timestamp]
                    },
                ]
                if let origin = group.origin { entry["origin"] = origin }
                return entry
            },
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // Written to a temporary file that is excluded from backups
            // before it takes the queue file's place, so no copy of the queue
            // is ever eligible for a backup.
            try data.write(to: tempURL)
            excludeFromBackup(tempURL)
            if rename(tempURL.path, fileURL.path) != 0 {
                try? FileManager.default.removeItem(at: tempURL)
                return false
            }
            // A rename keeps the attribute; checked again on the final file.
            excludeFromBackup(fileURL)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
    }

    /// Deletes every queue file in the directory (Application Support/
    /// Ravensight by default). Used by Ravensight.resetDeviceId before
    /// start(), when the ingest key is not known yet.
    static func deleteAll(directory: URL? = nil) {
        let base: URL
        if let directory = directory {
            base = directory
        } else {
            guard let support = FileManager.default.urls(for: defaultSearchPath, in: .userDomainMask).first else { return }
            base = support.appendingPathComponent("Ravensight", isDirectory: true)
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("queue-") &&
            (file.pathExtension == "json" || file.lastPathComponent.hasSuffix(".json.tmp")) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Deletes the queue file and any temporary file beside it.
    func delete() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: tempURL)
    }

    var exists: Bool {
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
}
