import Foundation
import CoreFoundation
import CryptoKit

public struct RavensightConfigResult {
    /// network, cache or default. Config failures never stop the game.
    public let source: String
    public let values: [String: Any]
}

struct RavensightConfigDocument {
    let values: [String: Any]
    let experiments: [String: String]
    let etag: String
    let data: Data

    static func parse(_ data: Data) -> Self? {
        guard data.count <= 430_000,
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = doc["values"] as? [String: Any], values.count <= 50,
              let rows = doc["experiments"] as? [[String: Any]], rows.count <= 10,
              let etag = doc["etag"] as? String, matches(etag, "^\"[a-f0-9]{64}\"$") else { return nil }
        for (key, value) in values {
            guard matches(key, "^[a-z][a-z0-9_]{0,63}$"), safe(value),
                  let encoded = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed), encoded.count <= 8192 else { return nil }
        }
        var experiments: [String: String] = [:]
        for row in rows {
            guard let key = row["key"] as? String, let variant = row["variant"] as? String,
                  matches(key, "^[a-z][a-z0-9_]{0,63}$"), matches(variant, "^[a-z][a-z0-9_-]{0,39}$"), experiments[key] == nil else { return nil }
            experiments[key] = variant
        }
        return Self(values: values, experiments: experiments, etag: etag, data: data)
    }
    static func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
    static func safe(_ value: Any, depth: Int = 0) -> Bool {
        guard depth <= 20 else { return false }
        if let dict = value as? [String: Any] {
            return dict.allSatisfy { !["__proto__", "prototype", "constructor"].contains($0.key) && safe($0.value, depth: depth + 1) }
        }
        if let array = value as? [Any] { return array.allSatisfy { safe($0, depth: depth + 1) } }
        if let number = value as? NSNumber { return number.doubleValue.isFinite }
        return value is String || value is NSNull
    }
    static func scope(_ config: RavensightCoreConfig) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [config.apiUrl, config.ingestKey, config.deviceId, config.platform, config.gameVersion, config.playtestToken == nil ? "normal" : "playtest"])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func get<T>(_ value: Any?, fallback: T) -> T {
        guard let value = value else { return fallback }
        if let number = value as? NSNumber {
            let boolean = CFGetTypeID(number) == CFBooleanGetTypeID()
            if T.self == Bool.self { return boolean ? (number.boolValue as! T) : fallback }
            guard !boolean else { return fallback }
            if T.self == Double.self { return number.doubleValue as! T }
            if T.self == Int.self {
                let d = number.doubleValue
                guard d.rounded() == d, abs(d) <= 9_007_199_254_740_991 else { return fallback }
                return Int(d) as! T
            }
            return fallback
        }
        // Deserializing again ensures callers cannot mutate Foundation containers.
        if value is [String: Any] || value is [Any], let data = try? JSONSerialization.data(withJSONObject: value),
           let copy = try? JSONSerialization.jsonObject(with: data) { return copy as? T ?? fallback }
        return value as? T ?? fallback
    }
}
