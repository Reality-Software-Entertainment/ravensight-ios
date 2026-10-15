import Foundation

/// The opt-in persisted queue (RavensightConfiguration.persistQueue): one
/// small JSON file under Application Support, rewritten atomically whenever
/// the queue changes and read once when the client is created.
///
/// Each group of events remembers the session it was queued under, so events
/// a force quit left behind can go out under that same session on the next
/// launch while it is still valid.
///
/// Only touched on the client's work queue (and in the initializer, before
/// the client is shared), so it needs no lock of its own.
final class RavensightQueueStore {
    /// The most events ever written, whatever maxQueueSize says.
    static let maxEvents = 500
    /// Events older than this are not restored: the server ignores events
    /// older than 90 days.
    static let maxAgeSeconds: Int64 = 89 * 86_400
    static let formatVersion = 1

    struct Group {
        var sessionToken: String?
        /// Unix milliseconds, 0 when there is no session.
        var expiresAtMs: Int64
        var events: [RavensightEvent]
    }

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Application Support/Ravensight/queue-<key hash>.json. The key hash
    /// keeps two clients with different ingest keys apart.
    static func defaultFileURL(ingestKey: String, directory: URL? = nil) -> URL? {
        let base: URL
        if let directory = directory {
            base = directory
        } else {
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
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
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["version"] as? NSNumber)?.intValue == RavensightQueueStore.formatVersion,
              let groups = object["groups"] as? [[String: Any]] else { return ([], 0) }
        var dropped = 0
        let oldest = nowMs / 1000 - RavensightQueueStore.maxAgeSeconds
        var total = 0
        var result: [Group] = []
        for raw in groups {
            let token = raw["sessionToken"] as? String
            let expiresAt = (raw["expiresAtMs"] as? NSNumber)?.int64Value ?? 0
            let rawEvents = raw["events"] as? [[String: Any]] ?? []
            var events: [RavensightEvent] = []
            for entry in rawEvents {
                guard let name = entry["event"] as? String, !name.isEmpty,
                      let timestamp = (entry["timestamp"] as? NSNumber)?.int64Value,
                      timestamp >= oldest else {
                    dropped += 1
                    continue
                }
                let payload = entry["data"] as? [String: Any] ?? [:]
                events.append(RavensightEvent(name: name, data: payload, timestamp: timestamp))
            }
            total += events.count
            if !events.isEmpty {
                result.append(Group(sessionToken: token, expiresAtMs: expiresAt, events: events))
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
                    "expiresAtMs": group.expiresAtMs,
                    "events": group.events.map { $0.payload() },
                ]
                if let token = group.sessionToken { entry["sessionToken"] = token }
                return entry
            },
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            // A transient queue has no business in a device backup.
            var url = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            return true
        } catch {
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
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
            base = support.appendingPathComponent("Ravensight", isDirectory: true)
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("queue-") && file.pathExtension == "json" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    var exists: Bool {
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
}
