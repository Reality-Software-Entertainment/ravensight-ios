import Foundation
#if canImport(Security)
import Security
#endif

/// Mints the rs_event_id every event carries inside its data, so the server
/// can recognise a resend of an event it already has.
///
/// Shape: `<prefix>-<start>-<nonce>-<counter>`, where prefix is the first 16
/// characters of the device id (only letters, digits, `_` and `-` are kept),
/// start is the client's start time in unix seconds as hex, nonce is 8 hex
/// characters from the system's secure random source, minted once per
/// launch, and counter counts up from 1. Always matches
/// `^[A-Za-z0-9_-]{1,64}$`.
///
/// The id is written into the event's data when the event is queued, so it
/// travels with the event through a retry and through the persisted queue.
/// Thread safe: the client stamps ids on the caller's thread and the core on
/// the work queue, from one shared counter.
final class RavensightEventIds: @unchecked Sendable {
    /// The pattern the server accepts.
    static let pattern = "^[A-Za-z0-9_-]{1,64}$"
    static let maxLength = 64
    static let prefixLength = 16

    private let lock = NSLock()
    private var prefix: String
    private let start: String
    /// 8 hex characters, minted once per launch.
    let nonce: String
    private var counter: Int64 = 0

    init(deviceId: String, startSec: Int64, nonce: String = RavensightEventIds.secureNonce()) {
        self.prefix = RavensightEventIds.prefix(for: deviceId)
        self.start = String(max(0, startSec), radix: 16)
        self.nonce = nonce
    }

    /// The device id changed (resetDeviceId, or the first yes in opt-in
    /// mode): later ids carry the new prefix. Ids already stamped keep theirs.
    func setDeviceId(_ deviceId: String) {
        let next = RavensightEventIds.prefix(for: deviceId)
        lock.lock()
        prefix = next
        lock.unlock()
    }

    /// The next id.
    func next() -> String {
        lock.lock()
        counter += 1
        let value = "\(prefix)-\(start)-\(nonce)-\(counter)"
        lock.unlock()
        return String(value.prefix(RavensightEventIds.maxLength))
    }

    /// The first 16 characters of the device id, keeping only the characters
    /// the id shape allows.
    static func prefix(for deviceId: String) -> String {
        let allowed = deviceId.unicodeScalars.filter { scalar in
            (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9") || scalar == "_" || scalar == "-"
        }
        return String(String.UnicodeScalarView(allowed).prefix(prefixLength))
    }

    /// 4 bytes from SecRandomCopyBytes as 8 hex characters. Falls back to the
    /// system generator (also a CSPRNG on Apple platforms) if the call fails.
    static func secureNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        #if canImport(Security)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<4).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        #else
        var generator = SystemRandomNumberGenerator()
        bytes = (0..<4).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        #endif
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// True when the id matches the shape the server accepts.
    static func isValid(_ id: String) -> Bool {
        return id.range(of: pattern, options: .regularExpression) != nil
    }
}
